
#
# HTTP::Lite.pm
#
# $Id: Lite.pm,v 1.1 2000/08/28 02:43:57 rhooper Exp rhooper $
#
# $Log: Lite.pm,v $
# Revision 1.1  2000/08/28 02:43:57  rhooper
# Initial revision
#


package HTTP::Lite;

use vars qw($VERSION);
use strict qw(vars);

$VERSION = "0.02";

# Required modules for Network I/O
use Socket 1.3;
use Fcntl;
use Errno qw(EAGAIN);

# Forward declarations
sub prepare_post;
sub http_writeline;
sub http_readline;

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
  $self->{method} = "GET";
  $self->{timeout} = 120;
  $self->{headers} = { 'User-Agent' => "HTTP::Lite/$VERSION" };
  $self->{HTTPReadBuffer} = "";
  $self->{body} = undef;
  $self->{request} = undef;
  $self->{content} = undef;
  $self->{headers} = undef;
  $self->{status} = undef;
  $self->{'resp-protocol'} = undef;
  $self->{'error-message'} = undef;
  $self->{'response'} = undef;
  $self->{'resp-headers'} = undef;
  
}

sub reset
{
	my $self = shift;
	$self->initialize;
}


# URL-encode data
# URL-encode data
sub escape {
  shift() if ref($_[0]) || (defined $_[1] && $_[0] eq $CGI::DefaultClass);
  my $toencode = shift;
  return undef unless defined($toencode);
  $toencode=~s/([^a-zA-Z0-9_.-])/uc sprintf("%%%02x",ord($1))/eg;
  return $toencode;
}

sub request
{
  my $self = shift;
  my ($url) = @_;
  
  my $method = $self->{method};

  # Parse URL 
  my ($protocol,$host,$junk,$port,$object) = 
    $url =~ m{^(\S+)://([^/:]*)(:(\d+))?(/.*)$};

  # Only HTTP is supported here
  if ($protocol ne "http")
  {
    warn "Only http is supported by HTTP::Lite";
    return undef;
  }
  
  # Setup the connection
  my $proto = getprotobyname('tcp');
  my $fhname = $url . localtime;
  my $fh = *$fhname;
  socket($fh, PF_INET, SOCK_STREAM, $proto);
  $port = 80 if !$port;
  my $addr = inet_aton($host) || return undef;
  my $sin = sockaddr_in($port,$addr);
  connect($fh, $sin) || return undef;
  # Set nonblocking IO on the handle to allow timeouts
  fcntl($fh, F_SETFL, O_NONBLOCK);

  # Start the request
  http_writeline($fh, "$method $object HTTP/1.0\n");
  
  # Output headers
  my $headerref = $self->{headers};
  foreach my $header (keys %$headerref)
  {
  	http_writeline($fh, $header.": ".$$headerref{$header}."\n");
  }
  
  # Handle Content-type and Content-Length seperately
  if (defined($self->{content}))
  {
    http_writeline($fh, "Content-Length: ".length($self->{content})."\n");
  }
  http_writeline($fh, "\n");
  
  # Output content, if any
  if (defined($self->{content}))
  {
    http_writeline($fh, $self->{content});
  }
  
  my (@headers,@body);
  my $headmode=1;
  my $line = 0;
  while ($_ = $self->http_readline($fh))
  {
    $line++;
    if ($line == 1)
    {
      my ($proto,$status,$message) = split(' ', $_, 3);
      $self->{status}=$status;
      $self->{'resp-protocol'}=$proto;
      $self->{'error-message'}=$message;
      next;
    } 
    $self->{response} .= $_;
    if ($_ =~ /^[\r\n]*$/)
    {
      $headmode = 0;
      next;
    }
    if ($headmode)
    {
      my ($var,$data) = $_ =~ /^([^:]*):\s*(.*)$/;
      if (defined($var))
      {
      	$data =~s/[\r\n]$//g;
        push @{ ${$self->{'resp-headers'}}{$var} }, $data;
      }
    } else {
      $self->{body}.=$_;
    }
  }
  return $self->{status};
}

sub add_req_header
{
  my $self = shift;
  my ($header, $value) = @_;
  
  ${$self->{headers}}{$header} = $value;
}

sub get_req_header
{
  my $self = shift;
  my ($header) = @_;
  
  return ${$self->{headers}}{$header};
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
  return $self->{body};
}

sub response
{
  my $self = shift;
  return $self->{response};
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
  
  return @{${$self->{'resp-headers'}}{$header}};
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
  $self->{headers}{'Content-Type'} = "application/x-www-urlencoded";
  $self->{method} = "POST";
}

sub http_writeline
{
  my ($fh,$line) = @_;
  syswrite($fh, $line);
}


sub http_readline
{
  my $self = shift;
  my ($fh, $timeout) = @_;
  
  # is there a line in the buffer yet?
  while ($self->{HTTPReadBuffer} !~ /\n/)
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
      $chars = sysread($fh, $inbuf, 256);
    }
    # End of stream?
    if ($chars == 0 && !$!{EAGAIN})
    {
      return undef;
    }
    # tag data onto end of buffer
    $self->{HTTPReadBuffer}.=$inbuf;
  }
  # get a single line from the buffer
  my ($newline,$oldline) = split("\n", $self->{HTTPReadBuffer}, 2);
  # and update the buffer
  $self->{HTTPReadBuffer}=$oldline;
  # Put the linefeed back on the line and return it
  return $newline."\n";
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

    HTTP::Lite is a stand-alone lightweight HTTP/1.0 implementation for
    perl.  It is not intended to replace LWP, but rather is intended for use
    in situations where LWP is an overkill or CPU cycles are precious.

    HTTP::Lite is ideal for CGI programs or for bundling for redistribution
    with larger packages where only HTTP GET and POST functionality is
    necessary.  

    HTTP::Lite supports basic POST and GET operations only.

    If you require more functionality, such as FTP or HTTPS, please see
    libwwwperl (LWP).  LWP is a significantly better and more comprehensive
    package than HTTP::Lite, and should be used instead of HTTP::Lite
    whenever possible.

=head1 CONSTRUCTOR

=over 4

=item new

This is the constructor for HTTP::Lite.  It presently takes no arguments.  A
future version of HTTP::Lite might accept parameters.

=back

=head1 METHODS

=over 4

=item request ( URL )

Initiates a request to the specified URL.

Returns undef if an I/O error is encountered, otherwise the HTTP status code
will be returned.  200 series status codes represent success, 300 represent
temporary errors, 400 represent permanent errors, and 500 represent server
errors.

See F<http://www.w3.org/Protocols/HTTP/HTRESP.html> for detailled
information about HTTP status codes.

=item prepare_post

=item add_req_header ( $header, $value )
=item get_req_header ( $header )
=item delete_req_header ( $header )

Add, Delete, or a HTTP header for the request.  These functions allow you to
override any header.  Only User-Agent and Content-Type are pre-defined by
the HTTP::Lite module.

B<NOTE>: The present implementation restricts you to one of each header. 

=item body

Returns the body of the document retured by the remote server.

=item headers_array

Returns an array of the HTTP headers returned by the remote server.

=item headers_string

Returns a string representation of the HTTP header block returned by the
remote server.

=item get_header ( $header )

Returns an array of values for the requested header.  

B<NOTE>: HTTP requests are not limited to a single instance of each header. 
As a resule, there may be more than one entry for every header.

=item protocol

Returns the HTTP protocol identifier, as reported by the remote server. 
This will generally be either HTTP/1.0 or HTTP/1.1.

=item status

Returns the HTTP status code returned by the server.  This is also reported
as the return value of I<request()>.

=item status_message

Returns the textual description of the status code as returned by the
server.  The status string is not required to adhere to any particular
format, although most HTTP servers use a standard set of descriptions.

=item response

Returns the entire unparsed HTTP response as returned by the server.

=item reset

Resets internal state for next request.

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
    	print "$header\n";
    }
    print "\n";
    print "$body\n";

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

    FTP, HTTPS, and any other non-HTTP/1.0 features are not implemented.
    multipart/form-data POSTs are not supported (necessary for File
    uploads).   
    
=head1 BUGS

    Many bugs likely exist.  This is a beta version.

=head1 AUTHOR

Roy Hooper <rhooper@thetoybox.org>

=head1 SEE ALSO

L<LWP>
RFC 2068
http://www.w3.org/

=head1 COPYRIGHT

Copyright (c) 2000 Roy Hooper.  All rights reserved.
This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut
