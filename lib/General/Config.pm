package General::Config;
require Exporter;
use strict;
use Data::Dumper;
use vars qw(@ISA @EXPORT);
@ISA    = qw ( Exporter );
@EXPORT = qw (
  load_config
  check_usage
  usage
  check_for_other_versions_running
);

sub load_config {

    my ( $config_file, $cfg, $log ) = @_;
    my ( $line, $key, $value );

    open( FILE, $config_file )
      || ( $log->error("Unable to load $config_file\n") );

    while ( $line = <FILE> ) {

        #
        # Skip Blank lines and comments
        #
        next if ( $line =~ /^#/ );
        next if ( $line =~ /^\s+$/ );
        ( $key, $value ) = split( ':', $line, 2 );
        $key   =~ s/\s+//;
        $value =~ s/^\s+//;
        $value =~ s/\s+$//;
        $cfg->{$key} = $value;
    }

    close(FILE);

    validate_config( $log, $cfg );

    return;
}

sub validate_config {

    my ( $log, $cfg ) = @_;
    my ( $ret, $count );

    if ( ( !defined $cfg->{INFOLOG} ) ) {
        $log->error("INFOLOG not specified in config file\n");
        $ret++;
    }
    if ( ( !defined $cfg->{LOGFILE} ) ) {
        $log->error("LOGFILE not specified in config file\n");
        $ret++;
    }
    if ( ( !defined $cfg->{LOGLEVEL} ) ) {
        $log->error("LOGLEVEL not specified in config file\n");
        $ret++;
    }
    else {
        $count = 0;
        for my $level (
            qw/DEBUG INFO NOTICE NOTE WARNING WARN ERROR ERR CRITICAL CRIT ALERT EMERGENCY EMERG/
          )
        {
            if ( uc( $cfg->{LOGLEVEL} ) =~ /$level/ ) {
                $count++;
            }
        }
        if ( $count == 0 ) {
            $log->error(
"LOGLEVEL is not one of (DEBUG INFO NOTICE NOTE WARNING WARN ERROR ERR CRITICAL CRIT ALERT EMERGENCY EMERG)\n"
            );
            $ret++;
        }

    }

    if ( ( !defined $cfg->{DTD} || !-e $cfg->{DTD} ) ) {
        $log->error("DTD not specified in config file\n");
        $ret++;
    }
    if ( ( !defined $cfg->{LOCKDIR} ) || ( !-d $cfg->{LOCKDIR} ) ) {
        $log->error("LOCKDIR not specified in config file or doesnt exist\n");
        $ret++;
    }
    if ( !defined $cfg->{LOCKFILE} ) {
        $log->error("LOCKFILE not specified in config file or doesnt exist\n");
        $ret++;
    }
    if ( !defined $cfg->{PARTNSTORE} ) {
        $log->error(
            "PARTNSTORE not specified in config file or doesnt exist\n");
        $ret++;
    }

    if ( ( !defined $cfg->{MAILFROM} ) ) {
        $log->error("MAILFROM not specified in config file\n");
        $ret++;
    }

    if ( ( !defined $cfg->{MAILRECP} ) ) {
        $log->error("MAILRECP not specified in config file\n");
        $ret++;
    }
    if ( ( !defined $cfg->{INDIR} ) ) {
        $log->error("INDIR not specified in config file\n");
        $ret++;
    }
    if ( ( !defined $cfg->{OUTDIR} ) ) {
        $log->error("OUTDIR not specified in config file\n");
        $ret++;
    }
    if ( ( !defined $cfg->{ERRDIR} ) ) {
        $log->error("ERRDIR not specified in config file\n");
        $ret++;
    }
    if ( ( !defined $cfg->{DATABASE} ) ) {
        $log->error(
"DATABASE not specified in config file skipping out this functionality\n"
        );
    }

    if ( defined $ret && $ret > 0 ) {
        $log->error("Not Starting Program: problems with the config file\n");
        exit;
    }

    return;
}

sub check_usage {
    my ( $opts, $log ) = @_;
    my $ret = 0;

    if ( !defined $opts->{'f'} ) {
        $log->error("-f config file must be specified\n");
        $ret++;
    }
    if ( defined $opts->{'r'} && $opts->{'r'} !~ /restart|stop|status/i ) {
        $log->error("-r must be one of stop,status or restart\n");
        $ret++;
    }

    if ( $ret > 0 ) {
        $log->error("Not Starting Program: problems with input parameters\n");
        usage($log);
        exit;
    }
}

sub usage {
    print
"USAGE $0\n\t[-s informixserver]\n\t[-D run in foreground]\n\t-f config file\n\t[-r stop status or restart]\n";
    exit;
}

sub check_for_other_versions_running {
    my ($log) = @_;
    my ( $ps_ef, $user, $self_pid, $date, $cmd, $self_cmd, %cmd_info,
        $cmd_info_str );

    $ps_ef = `ps -ef | grep $0 | grep -v grep`;

    foreach my $line ( split "\n", $ps_ef ) {
        if ( $line =~
            /^\s*(\S+)\s+(\S+)\s+\S+\s+\S+\s+(\S+)\s+\S+\s+\S+\s+(.*)$/ )
        {
            $user     = $1;
            $self_pid = $2;
            $date     = $3;
            $cmd      = $4;

            if ( $self_pid == $$ ) {

                # Our process
                $self_cmd = $cmd;
            }
            else {

                # Store info for the other matching commands
                push @{ $cmd_info{$cmd} }, "$self_pid ($user, $date)";
            }
        }
    }

# Note that this check is sensitive to the arguments etc passed to the script ie precise command match
    if ( defined $cmd_info{$self_cmd} ) {
        $log->error("Not Starting Program: Another version running\n");
        exit;
    }
}

1;

