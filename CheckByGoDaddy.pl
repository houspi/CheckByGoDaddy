#!/usr/bin/perl -w
#
# CheckByGoDaddy.pl
# SCRAPPING SCRIPT FOR THE WEBSITE                         
# https://www.godaddy.com/
# Domain availability check
#
# By houspi@gmail.com
#
# command line options [-f file] [-s SleepTimeout] [ -t Threads] [-h]
#  -h     display this help and exit.
#  -f     keywords file. keywords.txt by default.
#  -s     set the Sleep Timeout between requests. 10 seconds by default.
#  -t     Threads count. 8 by default. 16 threads maximum.
#
#  Auxiliry files
#       cookies               - cookies to setup US as a market and USD as a currency
#       domains_processed.txt - processed domains
# Out
#       domains_status.txt    - domains status and prices
#
# On restart domains from the domains_processed.txt file are skipped
# Delete it to start from scratch

use strict;
use threads;
use threads::shared;
use Getopt::Std;
use WWW::Mechanize;
use HTTP::Cookies;
use HTML::TreeBuilder;
use utf8;
use HTML::FormatText;
use Data::Dumper;
use FileHandle;
use Time::HiRes qw(gettimeofday);
use JSON;

my $DEBUG     = 1;
my $MaxRetry  = 5;
my $MaxSleep  = 10;
my $ThreadsMax   = 16;
my $ThreadsCount = 4;
my $KeyworfsFile = "keywords.txt";
my $StatusFile   = "domains_status.txt";
my $DomainsDoneFile = "domains_processed.txt";
my $listSize = 10;

my @UserAgents = (
    ["Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/66.0.3359.181 Safari/537.36", "192.168.0.101"],
    ["Mozilla/5.0 (Windows NT 6.1) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/41.0.2228.0 Safari/537.36", "192.168.0.122"],
    ["Mozilla/5.0 (Windows NT 5.1; rv:11.0) Gecko/20100101 Firefox/11.0", "192.168.0.131"],
    ["Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:60.0) Gecko/20100101 Firefox/60.0", "192.168.0.115"],
    ["Mozilla/5.0 (Windows NT 6.1; WOW64; rv:52.0) Gecko/20100101 Firefox/52.0", "192.168.0.119"],
    ["Mozilla/5.0 (X11; Linux i686) AppleWebKit/534.30 (KHTML, like Gecko) Chrome/12.0.742.100 Safari/534.30", "192.168.0.142"],
    ["Mozilla/5.0 (Windows NT 6.0) AppleWebKit/533.04.41 (KHTML, like Gecko) Chrome/57.4.9211.4949 Safari/533.33", "192.168.0.141"],
    ["Mozilla/5.0 (Macintosh; Intel Mac OS X 10_10; rv:33.0) Gecko/20100101 Firefox/33.0", "192.168.0.154"],
    ["Mozilla/5.0 (Macintosh; Intel Mac OS X 10_13_0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/61.0.3163.100 Safari/537.36", "192.168.0.157"],
    ["Mozilla/5.0 (Macintosh; Intel Mac OS X 10_11_1) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/51.0.2704.103 Safari/537.36", "192.168.0.152"],
    ["Mozilla/5.0 (Macintosh; Intel Mac OS X 10_10; rv:33.0) Gecko/20100101 Firefox/33.0", "192.168.0.105"],
    ["Mozilla/5.0 (Macintosh; Intel Mac OS X 10.9; rv:35.0) Gecko/20100101 Firefox/35.0", "192.168.0.103"],
    ["Mozilla/5.0 (Windows NT 6.1; Win64; x64; rv:25.0) Gecko/20100101 Firefox/29.0", "192.168.0.129"],
    ["Mozilla/5.0 (Windows NT 5.1; rv:44.0) Gecko/20100101 Firefox/44.0", "192.168.0.140"],
);
my $UAsize = scalar(@UserAgents);


my @full_tld = qw( com net org );
my @short_tld = qw( com );

# Parsing command line options
my %opts;
getopts('hf:s:n', \%opts);
if ($opts{'h'}) {
    Usage($0);
        exit(0);
}

if ($opts{'f'}) {
    $KeyworfsFile = $opts{'f'};
}

if ($opts{'s'}) {
    $MaxSleep = $opts{'s'};
    $MaxSleep =~ s/\D//g;
    $MaxSleep = 0 if (!$MaxSleep);
}

if ($opts{'t'}) {
    $ThreadsCount = $opts{'t'};
    $ThreadsCount =~ s/\D//g;
    $ThreadsCount = $ThreadsMax if ( ($ThreadsCount > $ThreadsMax) || ( ! $ThreadsCount)  );
}

# Read processed domains
my %DomainsDone:shared = ();
if (open(DD, $DomainsDoneFile)) {
    while(<DD>) {
        chomp;
        $DomainsDone{$_} = 1;
    }
    close(DD);
}

open KW,"<$KeyworfsFile" or die "Can't open $KeyworfsFile $!";

my %check_list = ();
while(<KW>) {
    chomp;
    my ($keywords, $volume) = split(/\t/, $_, 2);
    $volume =~ s/\D//g;
    my $domain = $keywords;
    $domain =~ s/ //g;
    $check_list{$domain} = [$volume, $keywords];
    my @words = split(/ /, $keywords);
    if ( $#words == 1 ) {
        $domain = $keywords;
        $domain =~ s/ /\-/g;
        $check_list{$domain} = [$volume, $keywords];
    }
}
my $domains_count = scalar(keys %check_list);
print "Total $domains_count domains to check\n";

#https://find.godaddy.com/domainsapi/v1/search/exact?q=abc.com&key=dpp_search&pc=&ptl=
my $BaseUrl     = 'https://www.godaddy.com';
my $SearchPath  = 'https://find.godaddy.com/domainsapi/v1/search/exact?key=dpp_search&pc=&ptl=&q=';

my $i = 1;
my $doneCount = 0;
my @list;
print "will check $listSize domains per thread\n";
print "will use $ThreadsCount threads\n";
my $threads_count = 0;
foreach (sort keys %check_list) {
    if ( $i < $listSize ) {
        push(@list, $_);
        $i++;
    } else {
        push(@list, $_);
        while ( $threads_count >= $ThreadsCount ) {
            foreach ( threads->list() ) {
                if ( $_->is_joinable() ) {
                    $_->join();
                    $threads_count--;
                }
            }
        }
        $doneCount += $i;
        print "$doneCount/$domains_count...";
        my $thr = threads->create('ParseDomainsPortion', \@list);
        $threads_count++;
        print "\n";
        @list = ();
        $i = 1;
    }
}
if( scalar(@list)>0) {
    print "$domains_count/$domains_count...";
    ParseDomainsPortion(\@list);
}
foreach ( threads->list() ) {
    $_->join();
}

=head1 ParseDomainsPortion
    @domain - DomainsList for testing
=cut
sub ParseDomainsPortion {
    my $domain = shift;
    my $mech;
    {
        local $^W = 0;
        $mech = WWW::Mechanize->new( autocheck => 1, ssl_opts => {verify_hostname => 0,SSL_verify_mode => 0} );
    }
    $mech->timeout(30);
    my ($agent, $ip) = @{$UserAgents[ int(rand($UAsize)) ]};
    $mech->default_header('User-Agent' => $agent);
    $mech->default_header('X-Forwarded-For' => $ip);
    $mech->default_header('Accept'=>'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8');
    $mech->default_header('Accept-Language'=>'en-us,en;q=0.5');
    $mech->default_header('Accept-Encoding'=>'gzip, deflate');
    $mech->default_header('Connection'=>'keep-alive');
    $mech->default_header('Pragma'=>'no-cache');
    $mech->default_header('Cache-Control'=>'no-cache');

    # set currency USD
    # set market US
    my $cookie_jar=HTTP::Cookies->new();
    $mech->cookie_jar->load('cookies');
    my ($RetCode, $Errm) = &ReTry($BaseUrl, $mech, $MaxRetry, $MaxSleep);
    my $output = "";
    my $domains_done = "";

    foreach (@{$domain}) {
        next if ( exists($DomainsDone{$_}));
        # skip if contains special chars
        # - : check only .com
        # check .com .net .org for other
        next if ( /[^\w\-]/ );
        $domains_done .= $_ . "\n";
        $DomainsDone{$_} = 1;
        my $tld_ref;
        if ( /-/  ) {
            $tld_ref = \@short_tld;
        } else {
            $tld_ref = \@full_tld;
        }
        foreach my $tld ( @{$tld_ref} ) {
            my $test_domain = $_ . "." . $tld;
            my $Url = $SearchPath . $test_domain;
            my ($RetCode, $Errm) = ReTry($Url, $mech, $MaxRetry, $MaxSleep);
            if($RetCode) {
                my $json;
                eval { $json = decode_json($mech->content(decoded_by_headers => 1)); };
                if ($@) {
                    print_debug(3, "BAD JSON", $@, "\n");
                    next;
                }
                #print Dumper($json);
                # ExactMatchDomain -> 
                #   AvailabilityLabel
                #   IsAvailable
                #   Price
                #   Valuation
                #       Prices
                #           List
                # I will need the available and buy now domains
                # buy now = auction + AuctionTypeId=11
                if( $json->{"ExactMatchDomain"}->{"IsAvailable"} ) {
                    $output .=  "$test_domain\tAvailable\t" . $json->{"Products"}->[0]->{"PriceInfo"}->{"CurrentPrice"} . "\t" . @{$check_list{$_}}[0] . "\t" . @{$check_list{$_}}[1] . "\n";
                } elsif ( ( $json->{"ExactMatchDomain"}->{"AvailabilityLabel"} eq "auction" ) && ( $json->{"ExactMatchDomain"}->{"AuctionTypeId"} eq "11" ) ) {
                    $output .= "$test_domain\tBuy Now\t" . $json->{"ExactMatchDomain"}->{"Price"} . "\t" . @{$check_list{$_}}[0] . "\t" . @{$check_list{$_}}[1] . "\n";
                } else {
                }
            }
        }
    }
    open OUT, ">>", $StatusFile;
    OUT->autoflush(1);
    print OUT $output;
    close(OUT);
    open OUT, ">>", $DomainsDoneFile;
    print OUT $domains_done;
    close(OUT);
}


=head1 ReTry
Trying to get URL
Url
mech
RetryLimit
MaxSleep
=cut
sub ReTry {
    my $Url        = shift;
    my $mech       = shift;
    my $RetryLimit = shift;
    my $MaxSleep   = shift;
    $RetryLimit = 5 if(!$RetryLimit);
    $MaxSleep   = 1 if(!$MaxSleep);
    # Set a new timeout, and save the old one
    my $OldTimeOut = $mech->timeout(30);
    my $ErrMAdd;
    my $TryCount = 0;
    
    while ($TryCount <= $RetryLimit) {
        $TryCount++;
        sleep int(rand($MaxSleep));
        # Catch the error
        # Return if no error
        print_debug(3, "ReTry", $Url, "\n");
        eval { $mech->get($Url); };
        if ( $mech->response()->code ne "200") {
            return (1,$mech->response()->message);
        }
        if ($@) {
            print_debug(3, "Attempt $TryCount/$RetryLimit...\t$Url", $@, "\n");
            $ErrMAdd = $@;
        }
        else {
            print_debug(3, "ReTry Success\n");
            $mech->timeout($OldTimeOut); 
#            if ($mech->response()->code)
            return (1, "");
        }
    }
    # Restore old timeout
    $mech->timeout($OldTimeOut);    
    # Return failure if the program has reached here
    return (0,"Can't connect to $Url after $RetryLimit attempts ($ErrMAdd)....");
}

=head1 trim
trim leading and trailing spases 
str
=cut
sub trim {
    my $str = $_[0];
    $str = (defined($str)) ? $str : "";
    $str =~ s/^\s+|\s+$//g;
    return($str);
}

=head1 print_debug
print debug info
=cut
sub print_debug {
    my $level = shift;
    if ($level <= $DEBUG) {
        print STDERR join(" ", @_);
    }
}

=head Usage
print help screen
=cut
sub Usage {
    my $ProgName = shift;
    print <<EOF
Usage $ProgName [-f file] [-s SleepTimeout] [ -t Threads] [-h]
  -h     display this help and exit.
  -f     keywords file. $KeyworfsFile by default.
  -s     set the Sleep Timeout between requests. $MaxSleep seconds by default.
  -t     Threads count. $ThreadsCount by default. $ThreadsMax threads maximum.

Script for scrapping website www.godaddy.com

EOF
}
