# Before `make install' is performed this script should be runnable with
# `make test'. After `make install' it should work as `perl test.pl'

######################### We start with some black magic to print on failure.

# Change 1..1 below to 1..last_test_to_print .
# (It may become useful if the test is moved to ./t subdirectory.)

BEGIN { $| = 1; print "1..6\n"; }
END {print "not ok 1\n" unless $loaded;}
use HTTP::Lite;
$loaded = 1;
print "ok 1\n";

######################### End of black magic.

# Insert your test code below (better if it prints "ok 13"
# (correspondingly "not ok 13") depending on the success of chunk 13
# of the test code):

$http = new HTTP::Lite;
$res = $http->request("http://www.cpan.org/");
print "not " if !defined($res);
print "ok 2\n";
$http->reset;

$res = $http->request("http://notknown.cpan.org/");
print "not " if defined($res);
print "ok 3\n";
$http->reset;

$res = $http->request("http://localhost:99999/");
print "not " if defined($res);
print "ok 4\n";
$http->reset;

%vars = (
         "QRY" => "perl",
         "ST" => "MS",
         "svcclass" => "dncurrent",
         "DBS" => "2"
        );
$http->prepare_post(\%vars);
$res = $http->request("http://www.deja.com/dnquery.xp");
print "not " if !defined($res);
print "ok 5\n";

$http->reset;

$res = $http->request("http://www.cpan.org/");
print "ok 6\n" if $res;
$http->reset;
