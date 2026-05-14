#!/usr/bin/perl -w
# Copyright, Designs and Patents Act 1988 or under the terms of a
# Licence entered into with the copyright owner.
#
# Warning: the doing of an unauthorised act in relation to a copyright
# work may result in both a civil claim for damages and a criminal
# prosecution.
#

use strict;
use Getopt::Std;
use FindBin;
use Net::SMTP;
use Data::Dumper;
use Fcntl ':flock';    # import LOCK_* constants
use lib "$FindBin::Bin/../lib";
use General::Iscan qw(write_pid);

#
# set time ENV so we are using the same format
#

$ENV{LC_TIME}         = 'POSIX';
$ENV{INFORMIXCONTIME} = 20;

#
# user defined modules
#

use SQLTracing;
use Log::Writer;
use General::Config;

use vars qw(
  %opts %databases $ref $select
  $emails $logerr %cfg
);

my $logerr = Log::Writer->new(
    filename   => \*STDERR,
    maxlevel   => 'info',
    timeformat => '%Y-%m-%d %H:%M:%S',
    newline    => 1,
);

&getopts( 'f:sDr:', \%opts );

#
# check opts
#

check_usage( \%opts, $logerr );

#
# load config file
#

load_config( $opts{'f'}, \%cfg, $logerr );

#
# create logging
#

my $log = Log::Writer->new(
    filename     => "$cfg{LOGFILE}",
    mode         => 'append',
    timeformat   => '%Y-%m-%d %H:%M:%S',
    maxlevel     => $cfg{LOGLEVEL},
    emailsender  => $cfg{MAILFROM},
    emailreciept => $cfg{MAILRECP},
    emailerrors  => 0,
    newline      => 1,
    prefix       => '',
);

my $log_info = Log::Writer->new(
    filename     => "$cfg{INFOLOG}",
    mode         => 'append',
    timeformat   => '%Y-%m-%d %H:%M:%S',
    maxlevel     => $cfg{LOGLEVEL},
    emailsender  => $cfg{MAILFROM},
    emailreciept => $cfg{MAILRECP},
    emailerrors  => 0,
    newline      => 1,
    prefix       => '',
);

#
# write pid
#

write_pid( $$, \%opts, \%cfg, $logerr );

if ( !defined $opts{s} ) {
    $opts{s}             = $ENV{INFORMIXSERVER};
    $cfg{INFORMIXSERVER} = $ENV{INFORMIXSERVER};
}
else {
    $ENV{INFORMIXSERVER} = $opts{'s'};
    $cfg{INFORMIXSERVER} = $opts{'s'};
}

my $check = SQLTracing->new( $log, \%cfg );
my $msgpath;

if ( defined $cfg{MSG_LOG} ) {
    $msgpath = $cfg{MSG_LOG};
}
else {
    $msgpath = $check->get_msg_path();
}

#
# trigger the main process
#

$check->init( \%cfg, $log, \%opts, $log_info, $log_info );
