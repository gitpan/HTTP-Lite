
#
# HTTP::Lite.pm
#
# $Id: Lite.pm,v 1.10 2002/06/13 04:55:52 rhooper Exp rhooper $
#

package HTTP::Lite;

use vars qw($VERSION);
use strict qw(vars);

$VERSION = "2.1.0";
my $BLOCKSIZE = 65536;
my $CRLF = "\r\n";

# Required modules for Network I/O
use Socket 1.3;
use Fcntl;
use Errno qw(EAGAIN);

# Forward declarations
sub prepare_post;
sub http_writeline;
sub http_readline;
sub http_read;
sub http_readbytes;

sub new 
{
  my $self = {};
  bless $self;
  $self->initialize();
  return $self;
}

sub initialize
{
  my $self = shift;
  $self->reset;
  $self->{timeout} = 120;
  $self->{HTTP11} = 0;
  $self->{DEBUG} = 0;
}

sub DEBUG
{
  my $self = shift;
  if ($self->{DEBUG}) {
    print STDERR join(" ", @_),"\n";
  }
}

sub reset
{
  my $self = shift;
  foreach my $var ("body", "request", "content", "status", "proxy",
    "proxyport", "resp-protocol", "error-message",  
    "resp-headers", "CBARGS")
  {
    $self->{$var} = undef;
  }
  $self->{HTTPReadBuffer} = "";
  $self->{method} = "GET";
  $self->{headers} = { 'User-Agent' => "HTTP::Lite/$VERSION" };
}


# URL-encode data
sub escape {
  my $toencode = shift;
  $toencode=~s/([^a-zA-Z0-9_.-])/uc sprintf("%%%02x",ord($1))/eg;
  return $toencode;
}

sub request
{
  my ($self, $url, $data_callback, $cbargs) = @_;
  
  my $method = $self->{method};
  if (defined($cbargs)) {
    my $self->{CBARGS} = $cbargs;
  }

  # Parse URL 
  my ($protocol,$host,$junk,$port,$object) = 
    $url =~ m{^([^:/]+)://([^/:]*)(:(\d+))?(/.*)$};

  # Only HTTP is supported here
  if ($protocol ne "http")
  {
    warn "Only http is supported by HTTP::Lite";
    return undef;
  }
  
  # Setup the connection
  my $proto = getprotobyname('tcp');
  my $fhname = $url . time();
  my $fh = *$fhname;
  socket($fh, PF_INET, SOCK_STREAM, $proto);
  $port = 80 if !$port;

  my $connecthost = $self->{'proxy'} || $host;
  $connecthost = $connecthost ? $connecthost : $host;
  my $connectport = $self->{'proxyport'} || $port;
  $connectport = $connectport ? $connectport : $port;
  my $addr = inet_aton($connecthost);
  if (!$addr) {
    close($fh);
    return undef;
  }
  if ($connecthost ne $host)
  {
    # if proxy active, use full URL as object to request
    $object = "$url";
  }

  my $sin = sockaddr_in($connectport,$addr);
  connect($fh, $sin) || return undef;
  # Set nonblocking IO on the handle to allow timeouts
  if ( $^O ne "MSWin32" ) {
    fcntl($fh, F_SETFL, O_NONBLOCK);
  }

  # Start the request (HTTP/1.1 mode)
  if ($self->{HTTP11}) {
    http_writeline($fh, "$method $object HTTP/1.1$CRLF");
  } else {
    http_writeline($fh, "$method $object HTTP/1.0$CRLF");
  }

  # Add some required headers
  # we only support a single transaction per request in this version.
  $self->add_req_header("Connection", "close");    
  $self->add_req_header("Host", $host);
  $self->add_req_header("Accept", "*/*");
    
  # Output headers
  my $headerref = $self->{headers};
  foreach my $header (keys %$headerref)
  {
    http_writeline($fh, $header.": ".$$headerref{$header}."$CRLF");
  }
  
  # Handle Content-type and Content-Length seperately
  if (defined($self->{content}))
  {
    http_writeline($fh, "Content-Length: ".length($self->{content})."$CRLF");
  }
  http_writeline($fh, "$CRLF");
  
  # Output content, if any
  if (defined($self->{content}))
  {
    http_writeline($fh, $self->{content});
  }
  
  # Read response from server
  my $headmode=1;
  my $chunkmode=0;
  my $chunksize=0;
  my $chunklength=0;
  my $chunk;
  my $line = 0;
  my $data;
  while ($data = $self->http_read($fh,$headmode,$chunkmode,$chunksize))
  {
    $self->{DEBUG} && $self->DEBUG("reading: $chunkmode, $chunksize, $chunklength, $headmode, ".
        length($self->{'body'}));
    if ($self->{DEBUG}) {
      foreach my $var ("body", "request", "content", "status", "proxy",
        "proxyport", "resp-protocol", "error-message", 
        "resp-headers", "CBARGS", "HTTPReadBuffer") 
      {
        $self->DEBUG("state $var ".length($self->{$var}));
      }
    }
    $line++;
    if ($line == 1)
    {
      my ($proto,$status,$message) = split(' ', $$data, 3);
      $self->{DEBUG} && $self->DEBUG("header $$data");
      $self->{status}=$status;
      $self->{'resp-protocol'}=$proto;
      $self->{'error-message'}=$message;
      next;
    } 
    if (($headmode || $chunkmode eq "entity-header") && $$data =~ /^[\r\n]*$/)
    {
      if ($chunkmode)
      {
        $chunkmode = 0;
      }
      $headmode = 0;
      
      # Check for Transfer-Encoding
      my $te = $self->get_header("Transfer-Encoding");
      if (defined($te)) {
        my $header = join(' ',@{$te});
        if ($header =~ /chunked/i)
        {
          $chunkmode = "chunksize";
        }
      }
      next;
    }
    if ($headmode || $chunkmode eq "entity-header")
    {
      my ($var,$datastr) = $$data =~ /^([^:]*):\s*(.*)$/;
      if (defined($var))
      {
	$datastr =~s/[\r\n]$//g;
        $var = lc($var);
        $var =~ s/^(.)/&upper($1)/ge;
        $var =~ s/(-.)/&upper($1)/ge;
        my $hr = ${$self->{'resp-headers'}}{$var};
        if (!ref($hr))
        {
          $hr = [ $datastr ];
        }
        else 
        {
          push @{ $hr }, $datastr;
        }
        ${$self->{'resp-headers'}}{$var} = $hr;
      }
    } elsif ($chunkmode)
    {
      if ($chunkmode eq "chunksize")
      {
        $chunksize = $$data;
        $chunksize =~ s/^\s*|;.*$//g;
        $chunksize =~ s/\s*$//g;
        my $cshx = $chunksize;
        if (length($chunksize) > 0) {
          # read another line
          if ($chunksize !~ /^[a-f0-9]+$/i) {
            $self->{DEBUG} && $self->DEBUG("chunksize not a hex string");
          }
          $chunksize = hex($chunksize);
          $self->{DEBUG} && $self->DEBUG("chunksize was $chunksize (HEX was $cshx)");
          if ($chunksize == 0)
          {
            $chunkmode = "entity-header";
          } else {
            $chunkmode = "chunk";
            $chunklength = 0;
          }
        } else {
          $self->{DEBUG} && $self->DEBUG("chunksize empty string, checking next line!");
        }
      } elsif ($chunkmode eq "chunk")
      {
        $chunk .= $$data;
        $chunklength += length($$data);
        if ($chunklength >= $chunksize)
        {
          $chunkmode = "chunksize";
          if ($chunklength > $chunksize)
          {
            $chunk = substr($chunk,0,$chunksize);
          } 
          elsif ($chunklength == $chunksize && $chunk !~ /$CRLF$/) 
          {
            # chunk data is exactly chunksize -- need CRLF still
            $chunkmode = "ignorecrlf";
          }
          $self->add_to_body(\$chunk, $data_callback);
          $chunk="";
          $chunklength = 0;
          $chunksize = "";
        } 
      } elsif ($chunkmode eq "ignorecrlf")
      {
        $chunkmode = "chunksize";
      }
    } else {
      $self->add_to_body($data, $data_callback);
    }
  }
  close($fh);
  return $self->{status};
}

sub add_to_body
{
  my $self = shift;
  my ($dataref, $data_callback) = @_;
  
  if (!defined($data_callback)) {
    $self->{DEBUG} && $self->DEBUG("no callback");
    $self->{'body'}.=$$dataref;
  } else {
    my $newdata = &$data_callback($self, $dataref, $self->{CBARGS});
    if ($self->{DEBUG}) {
      $self->DEBUG("callback got back a ".ref($newdata));
      if (ref($newdata) eq "SCALAR") {
        $self->DEBUG("callback got back ".length($$newdata)." bytes");
      }
    }
    if (defined($newdata) && ref($newdata) eq "SCALAR") {
      $self->{'body'} .= $$newdata;
    }
  }
}

sub add_req_header
{
  my $self = shift;
  my ($header, $value) = @_;
  
  $self->{DEBUG} && $self->DEBUG("add_req_header $header $value");
  ${$self->{headers}}{$header} = $value;
}

sub get_req_header
{
  my $self = shift;
  my ($header) = @_;
  
  return $self->{headers}{$header};
}

sub delete_req_header
{
  my $self = shift;
  my ($header) = @_;
  
  my $exists;
  if ($exists=defined(${$self->{headers}}{$header}))
  {
    delete ${$self->{headers}}{$header};
  }
  return $exists;
}

sub body
{
  my $self = shift;
  return $self->{'body'};
}

sub status
{
  my $self = shift;
  return $self->{status};
}

sub protocol
{
  my $self = shift;
  return $self->{'resp-protocol'};
}

sub status_message
{
  my $self = shift;
  return $self->{'error-message'};
}

sub proxy
{
  my $self = shift;
  my ($value) = @_;
  
  # Parse URL 
  my ($protocol,$host,$junk,$port,$object) = 
    $value =~ m{^(\S+)://([^/:]*)(:(\d+))?(/.*)$};
  if (!$host)
  {
    ($host,$port) = $value =~ /^([^:]+):(.*)$/;
  }

  $self->{'proxy'} = $host || $value;
  $self->{'proxyport'} = $port || 80;
}

sub headers_array
{
  my $self = shift;
  
  my @array = ();
  
  foreach my $header (keys %{$self->{'resp-headers'}})
  {
    my $aref = ${$self->{'resp-headers'}}{$header};
    foreach my $value (@$aref)
    {
      push @array, "$header: $value";
    }
  }
  return @array;
}

sub headers_string
{
  my $self = shift;
  
  my $string = "";
  
  foreach my $header (keys %{$self->{'resp-headers'}})
  {
    my $aref = ${$self->{'resp-headers'}}{$header};
    foreach my $value (@$aref)
    {
      $string .= "$header: $value\n";
    }
  }
  return $string;
}

sub get_header
{
  my $self = shift;
  my $header = shift;

  return $self->{'resp-headers'}{$header};
}

sub http11_mode
{
  my $self = shift;
  my $mode = shift;

  $self->{HTTP11} = $mode;
}

sub prepare_post
{
  my $self = shift;
  my $varref = shift;
  
  my $body = "";
  while (my ($var,$value) = map { escape($_) } each %$varref)
  {
    if ($body)
    {
      $body .= "&$var=$value";
    } else {
      $body = "$var=$value";
    }
  }
  $self->{content} = $body;
  $self->{headers}{'Content-Type'} = "application/x-www-form-urlencoded"
    unless defined ($self->{headers}{'Content-Type'}) and 
    $self->{headers}{'Content-Type'};
  $self->{method} = "POST";
}

sub http_writeline
{
  my ($fh,$line) = @_;
  syswrite($fh, $line, length($line));
}


sub http_read
{
  my $self = shift;
  my ($fh,$headmode,$chunkmode,$chunksize) = @_;

  $self->{DEBUG} && $self->DEBUG("read handle=$fh, headm=$headmode, chunkm=$chunkmode, chunksize=$chunksize");

  my $res;
  if (($headmode == 0 && $chunkmode eq "0") || ($chunkmode eq "chunk")) {
    my $bytes_to_read = $chunkmode eq "chunk" ?
	($chunksize < $BLOCKSIZE ? $chunksize : $BLOCKSIZE) :
	$BLOCKSIZE;
    $res = $self->http_readbytes($fh,$self->{timeout},$bytes_to_read);
  } else { 
    $res = $self->http_readline($fh,$self->{timeout});  
  }
  if ($res) {
    if ($self->{DEBUG}) {
      $self->DEBUG("read got ".length($$res)." bytes");
      my $str = $$res;
      $str =~ s{([\x00-\x1F\x7F-\xFF])}{.}g;
      $self->DEBUG("read: ".$str);
    }
  }
  return $res;
}

sub http_readline
{
  my $self = shift;
  my ($fh, $timeout) = @_;
  my $EOL = "\n";

  $self->{DEBUG} && $self->DEBUG("readline handle=$fh, timeout=$timeout");
  
  # is there a line in the buffer yet?
  while ($self->{HTTPReadBuffer} !~ /$EOL/)
  {
    # nope -- wait for incoming data
    my ($inbuf,$bits,$chars) = ("","",0);
    vec($bits,fileno($fh),1)=1;
    my $nfound = select($bits, undef, $bits, $timeout);
    if ($nfound == 0)
    {
      # Timed out
      return undef;
    } else {
      # Get the data
      $chars = sysread($fh, $inbuf, $BLOCKSIZE);
      $self->{DEBUG} && $self->DEBUG("sysread $chars bytes");
    }
    # End of stream?
    if ($chars <= 0 && !$!{EAGAIN})
    {
      last;
    }
    # tag data onto end of buffer
    $self->{HTTPReadBuffer}.=$inbuf;
  }
  # get a single line from the buffer
  my $nlat = index($self->{HTTPReadBuffer}, $EOL);
  my $newline;
  my $oldline;
  if ($nlat > -1)
  {
    $newline = substr($self->{HTTPReadBuffer},0,$nlat+1);
    $oldline = substr($self->{HTTPReadBuffer},$nlat+1);
  } else {
    $newline = substr($self->{HTTPReadBuffer},0);
    $oldline = "";
  }
  # and update the buffer
  $self->{HTTPReadBuffer}=$oldline;
  return length($newline) ? \$newline : 0;
}

sub http_readbytes
{
  my $self = shift;
  my ($fh, $timeout, $bytes) = @_;
  my $EOL = "\n";

  $self->{DEBUG} && $self->DEBUG("readbytes handle=$fh, timeout=$timeout, bytes=$bytes");
  
  # is there enough data in the buffer yet?
  while (length($self->{HTTPReadBuffer}) < $bytes)
  {
    # nope -- wait for incoming data
    my ($inbuf,$bits,$chars) = ("","",0);
    vec($bits,fileno($fh),1)=1;
    my $nfound = select($bits, undef, $bits, $timeout);
    if ($nfound == 0)
    {
      # Timed out
      return undef;
    } else {
      # Get the data
      $chars = sysread($fh, $inbuf, $BLOCKSIZE);
      $self->{DEBUG} && $self->DEBUG("sysread $chars bytes");
    }
    # End of stream?
    if ($chars <= 0 && !$!{EAGAIN})
    {
      last;
    }
    # tag data onto end of buffer
    $self->{HTTPReadBuffer}.=$inbuf;
  }
  my $newline;
  my $buflen;
  if (($buflen=length($self->{HTTPReadBuffer})) >= $bytes)
  {
    $newline = substr($self->{HTTPReadBuffer},0,$bytes+1);
    if ($bytes+1 < $buflen) {
      $self->{HTTPReadBuffer} = substr($self->{HTTPReadBuffer},$bytes+1);
    } else {
      $self->{HTTPReadBuffer} = "";
    }
  } else {
    $newline = substr($self->{HTTPReadBuffer},0);
    $self->{HTTPReadBuffer} = "";
  }
  return length($newline) ? \$newline : 0;
}

sub upper
{
  my ($str) = @_;
  if (defined($str)) {
    return uc($str);
  } else {
    return undef;
  }
}

1;

__END__

=pod

=head1 NAME

HTTP::Lite - Lightweight HTTP implementation

=head1 SYNOPSIS

    use HTTP::Lite;
    $http = new HTTP::Lite;
    $req = $http->request("http://www.cpan.org/") 
        or die "Unable to get document: $!";
    print $http->body();

=head1 DESCRIPTION

    HTTP::Lite is a stand-alone lightweight HTTP/1.1
    implementation for perl.  It is not intended to replace LWP,
    but rather is intended for use in situations where it is
    desirable to install the minimal number of modules to
    achieve HTTP support, or where LWP is not a good candidate
    due to CPU overhead, such as slower processors.

    HTTP::Lite is ideal for CGI (or mod_perl) programs or for
    bundling for redistribution with larger packages where only
    HTTP GET and POST functionality are necessary.

    HTTP::Lite supports basic POST and GET operations only.  As
    of 0.2.1, HTTP::Lite supports HTTP/1.1 and is compliant with
    the Host header, necessary for name based virtual hosting. 
    Additionally, HTTP::Live now supports Proxies.

    If you require more functionality, such as FTP or HTTPS,
    please see libwwwperl (LWP).  LWP is a significantly better
    and more comprehensive package than HTTP::Lite, and should
    be used instead of HTTP::Lite whenever possible.

=head1 CONSTRUCTOR

=over 4

=item new

This is the constructor for HTTP::Lite.  It presently takes no
arguments.  A future version of HTTP::Lite might accept
parameters.

=back

=head1 METHODS

=over 4

=item http11_mode ( 0 | 1 )

Turns on or off HTTP/1.1 support.  This is off by default due to broken
HTTP/1.1 servers.  Use 1 to enable HTTP/1.1 support.

=item request ( URL, CALLBACK, CBARGS )

Initiates a request to the specified URL.

Returns undef if an I/O error is encountered, otherwise the HTTP
status code will be returned.  200 series status codes represent
success, 300 represent temporary errors, 400 represent permanent
errors, and 500 represent server errors.

See F<http://www.w3.org/Protocols/HTTP/HTRESP.html> for detailled 
information about HTTP status codes.

The CALLBACK parameter, if used, is a way to filter the data as it is
received or to handle very large transfers.  It must be a function
reference, and will be passed: a reference to the instance of the http
request making the callback, a reference to the current block of data about
to be added to the body, and the CBARGS parameter (which may be anything). 
It must return either a reference to the data to add to the body of the
document, or undef.

An example use to save a document to file is:

  # Write the data to the filehandle $cbargs
  sub savetofile {
    my ($self,$dataref,$cbargs) = @_;
    print $cbargs $$dataref;
    return undef;
  }

  $url = "$testpath/bigbinary.dat";
  open OUT, ">bigbinary.dat";
  $res = $http->request($url, \&callback2, OUT);
  close OUT;


=item prepare_post

=item add_req_header ( $header, $value )
=item get_req_header ( $header )
=item delete_req_header ( $header )

Add, Delete, or a HTTP header(s) for the request.  These
functions allow you to override any header.  Presently, Host,
User-Agent, Content-Type, Accept, and Connection are pre-defined
by the HTTP::Lite module.  You may not override Host,
Connection, or Accept.

To provide (proxy) authentication or authorization, you would use:

    use HTTP::Lite;
    use MIME::Base64;
    $http = new HTTP::Lite;
    $encoded = encode_base64('username:password');
    $http->add_req_header("Authorization", $encoded);

B<NOTE>: The present implementation limits you to one instance
of each header.

=item body

Returns the body of the document retured by the remote server.

=item headers_array

Returns an array of the HTTP headers returned by the remote
server.

=item headers_string

Returns a string representation of the HTTP headers returned by
the remote server.

=item get_header ( $header )

Returns an array of values for the requested header.  

B<NOTE>: HTTP requests are not limited to a single instance of
each header.  As a result, there may be more than one entry for
every header.

=item protocol

Returns the HTTP protocol identifier, as reported by the remote
server.  This will generally be either HTTP/1.0 or HTTP/1.1.

=item proxy ( $proxy_server )

The URL or hostname of the proxy to use for the next request.

=item status

Returns the HTTP status code returned by the server.  This is
also reported as the return value of I<request()>.

=item status_message

Returns the textual description of the status code as returned
by the server.  The status string is not required to adhere to
any particular format, although most HTTP servers use a standard
set of descriptions.

=item reset

You must call this prior to re-using an HTTP::Lite handle,
otherwise the results are undefined.

=head1 EXAMPLES

    # Get and print out the headers and body of the CPAN homepage
    use HTTP::Lite;
    $http = new HTTP::Lite;
    $req = $http->request("http://www.cpan.org/")
        or die "Unable to get document: $!";
    die "Request failed ($req): ".$http->status_message()
      if $req ne "200";
    @headers = $http->headers_array();
    $body = $http->body();
    foreach $header (@headers)
    {
      print "$header$CRLF";
    }
    print "$CRLF";
    print "$body$CRLF";

    # POST a query to the dejanews USENET search engine
    use HTTP::Lite;
    $http = new HTTP::Lite;
    %vars = (
             "QRY" => "perl",
             "ST" => "MS",
             "svcclass" => "dncurrent",
             "DBS" => "2"
            );
    $http->prepare_post(\%vars);
    $req = $http->request("http://www.deja.com/dnquery.xp")
      or die "Unable to get document: $!";
    print "req: $req\n";
    print $http->body();

=head1 UNIMPLEMENTED

    - FTP 
    - HTTPS (SSL)
    - Authenitcation/Authorizaton/Proxy-Authorization
      are not directly supported, and require MIME::Base64.
    - Redirects (Location) are not automatically followed
    - multipart/form-data POSTs are not supported (necessary for
      File uploads).
    
=head1 BUGS

    Large requests are stored in ram, potentially more than once
    due to HTTP/1.1 chunked transfer mode support.  A future
    version of this module may support writing requests to a
    filehandle to avoid excessive disk use.

    Some broken HTTP/1.1 servers send incorrect chunk sizes
    when transferring files.  HTTP/1.1 mode is now disabled by
    default.

=head1 ACKNOWLEDGEMENTS

	Marcus I. Ryan	shad@cce-7.cce.iastate.edu
	michael.kloss@de.adp.com

=head1 AUTHOR

Roy Hooper <rhooper@thetoybox.org>

=head1 SEE ALSO

L<LWP>
RFC 2068 - HTTP/1.1 -http://www.w3.org/

=head1 COPYRIGHT

Copyright (c) 2000 Roy Hooper.  All rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut
