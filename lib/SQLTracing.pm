package SQLTracing;
use strict;
use warnings;
use Data::Dumper;
use POSIX qw(strftime);
use Time::Local;
use Expect;
use IO::Pipe;
use Module::Pluggable require => 1;
use Parallel::ForkManager;
use General::Iscan qw(write_pid check_locked);
use Storable qw(store);

use vars qw($VERSION @ISA @EXPORT);

$Expect::Multiline_Matching = 0;

require Exporter;

@ISA = qw(Exporter);

our $VERSION = '1.00';

use Module::Pluggable require => 1;

$| = 1;

sub new {
    my ( $class, $log, $cfg ) = @_;

    my $self = bless {}, $class;

    $self->_set_onconfig_value();

    $self->_remove_stop( $cfg->{LOGDIR} );

    return $self;
}

sub init {
    my ( $self, $cfg, $log, $opts, $log_info, $log_to_stderr ) = @_;
    my (
        $init,  $name,    $line,      $file, $max_procs,
        @lines, @plugins, $servernum, $pm,   $pid,
        $sleep, %running, %part_info, $special_sql
    );

   $special_sql  = do( $cfg->{SPECIAL_SQL} );


    if ( check_state( $self, $log_info, $cfg ) ) {
        $log_to_stderr->info(
            "Instance is not in the requried state to run sqltracer");
        $log_info->info(
            "Instance is not in the requried state to run sqltracer");
        return;
    }

    #
    # get partnumbers for use by other processes
    #

    load_partnums( $cfg, $log_info, \%part_info, $opts, );
    set_temps($self,$opts);

    @plugins = $self->plugins;

    $servernum = $self->get_servernum();
    $max_procs = scalar(@plugins);
    $pm        = Parallel::ForkManager->new( $max_procs, $cfg->{LOGDIR} );

  NAMES: foreach my $plugin (@plugins) {
        $init = $plugin . "::init";
        $name = "$plugin";
        $name = ( split( '::', $name ) )[-1];

        if ( defined $cfg->{ uc($name) . "_SLEEP" } ) {
            $sleep = $cfg->{ uc($name) . "_SLEEP" };
        }
        else {
            $sleep = 5;
        }
              $pid = $pm->start()
          and $running{$init}{PID} = $pid
          and $log_info->info("started $name with $pid")
          and next NAMES;

        $0 = "$0: $name " . scalar( localtime() );
        $self->$init( $name, $cfg, $servernum, $log_info, $sleep, $log_info,$special_sql )
          if defined &$init;

        $pm->finish();    # pass an exit code to finish
    }

    #
    # while the stop file doesnt exist continue
    #

    $SIG{INT} = sub {
        touch_stop( $cfg->{LOGDIR} );
    };
    $SIG{TERM} = sub {
        touch_stop( $cfg->{LOGDIR} );
    };

    my $count = 1;

    #
    # main management loop
    #

    while (get_stop( $cfg->{LOCKDIR}, $log_info ) != 1
        && check_locked( $cfg, $log_info ) != 1 )
    {

        #
        # check processes are still running, if not clean up and restart them
        #
        $count++;
        if ( $count % 5 == 0 ) {

            check_state( $self, $log_info, $cfg );
            check_running( $self, $log_info, \%running, $pm, $cfg, $servernum,
                $log_info );
            if ( $count == 100 ) {
                load_partnums( $cfg, $log_info, \%part_info, $opts, );
                $count = 0;
            }
        }

        #
        # check informix is running
        #

        sleep(5);

    }

    #
    # force stop if configured
    #

    my @running_pids = $pm->running_procs;
    my @kill_pids;
    my $exists;
    if ( defined $cfg->{FORCE_STOP} && $cfg->{FORCE_STOP} == 1 ) {
        foreach my $close_pid (@running_pids) {
            $exists = kill 0, $close_pid;
            if ($exists) {
                push( @kill_pids, $close_pid );
                if ( open( FILE, "ps  -eo  pid,ppid,comm|grep $close_pid|" ) ) {
                    while ( my $line = <FILE> ) {

                        chomp $line;
                        $line =~ s/^\s+//g;
                        $line =~ s/\s+$//g;
                        my ( $pid, $ppid, $command ) = split( /\s+/, $line );
                        if ( $command eq 'onstat' ) {
                            push( @kill_pids, $pid );
                        }
                    }
                    close(FILE);
                }

            }
        }
        $log_info->info( "stopping", @kill_pids );

        #
        # kill decendant processes
        #

        kill 'SIGKILL', @kill_pids;

        $log_info->info("stopped");

    }
    else {

        #
        # give the forked processes time to exit
        #

        sleep 2;
        $pm->reap_finished_children();
        $pm->wait_all_children;
    }
}

sub check_running {

    my ( $self, $log, $running, $pm, $cfg, $servernum, $log_info ) = @_;
    my ( $sleep, $exists, $pid, $name );

    $pm->reap_finished_children();

  RESPAWN: foreach my $plugin ( keys %{$running} ) {
        $exists = kill 0, $running->{$plugin}{PID};

        if ( !$exists ) {

            $name = "$plugin";
            $name = ( split( '::', $name ) )[-2];
            if ( defined $cfg->{ uc($name) . "_SLEEP" } ) {
                $sleep = $cfg->{ uc($name) . "_SLEEP" };
            }
            else {
                $sleep = 30;
            }

            $log->info("Restarting $name");

            $pid = $pm->start()
              and $running->{$plugin}{PID} = $pid
              and next RESPAWN;

            $0 = "$0: $name RESTARTED " . scalar( localtime() );

            $self->$plugin( $name, $cfg, $servernum, $log, $sleep, $log_info )
              if defined &$plugin;

            $pm->finish();
        }

        else {

            #
            # nothing to do currently
            #
        }

    }

}

sub get_stop {
    my $dir = shift;
    my $log = shift;

    if ( -e "$dir/stop" ) {
        return 1;
    }

    return 0

}

sub _remove_stop {
    my $self = shift;
    my $dir  = shift;
    if ( -e "$dir/stop" ) {
        unlink("$dir/stop");
    }

}

sub touch_stop {
    my $dir = shift;
    open( FILE, "> $dir/stop" ) || die $!;
    close(FILE);

}

sub catch_zap {
    my $signame = shift;
    my $cfg     = shift;
}

sub _set_hostname {
    my ($self) = @_;
    $self->{HOSTNAME} = $ENV{INFORMIXSERVER};
}

sub get_hostname {
    my ($self) = @_;
    return $self->{HOSTNAME};
}

sub _check_distrib {
    my ($self) = @_;
    return $self->{SERVER};
}

sub get_logfile {
    my ($self) = @_;
    return $self->{LOGFILE};
}

sub _set_value {
    my ( $self, $key, $value ) = @_;
    $self->{$key} = $value;
}

sub get_onconfig_val {
    my ( $self, $key ) = @_;

    return $self->{ONCONFIG_DATA}{$key};

}
sub set_temps {
    my ($self,$opts) = @_;
    my ( $line, @temps, $key, $value, $size,$row,@rows );

`dbaccess sysmaster\@$opts->{s} - << !EOF 2> /dev/null
unload to ".temps.tmp$$"
select dbsnum from sysdbspaces
where is_temp=1;
!EOF`;
 open( FILE, ".temps.tmp$$" ) || die $!;
    while ( $row = <FILE> ) {
        push( @rows, $row );
    }
    close(FILE);
    unlink(".temps.tmp$$");
    foreach $row (@rows) {
        chomp $row;
        $row =~ s/\|$//g;
	push(@temps,$row);
    }

    $self->{TEMP_DBSPACES} = ( \@temps );
}

sub _set_onconfig_value {
    my ($self) = @_;
    my ( $line, %cfg, $key, $value, $size );

    if ( !defined $ENV{ONCONFIG} ) {

        #
        # locally turn off file seperator to read in whole file
        #

        local $/ = undef;
        open( FILE, "onstat -c|head|grep 'Configuration File'|" ) || die $!;
        $line = <FILE>;
        $line =~ s/\r//g;
        $line =~ s/\n//g;

        #
        # set for later use
        #

        $self->{ONCONFIGFILE} = ( split( '\s+', $line ) )[-1];

        $ENV{ONCONFIG} = ( split( '\/', $line ) )[-1];

        $line = ( split( '/', $line ) )[-1];
        close(FILE);

    }

    open( ONCONFIG, "onstat -c|" ) || die $!;

    while (<ONCONFIG>) {

        next if ( $_ =~ /^\s*#/ );
        next if ( $_ !~ /\S+/ );

        if ( $_ =~ /(\S+)\s*(.*)/ ) {
            ( $key, $value ) = ( $1, $2 );
            $value =~ s/\s*$//g;
            $key   =~ s/\s*$//g;
            chomp($value);
            if ( $key eq 'BUFFERPOOL' ) {
                next if ( $value =~ /default/ );
                $size = ( split( ',', $value ) )[0];
                $size = ( split( '=', $size ) )[1];

                $size = uc($size);
                $cfg{"${key}_${size}"} = $value;
            }
            else {
                $cfg{$key} = $value;
            }
        }

    }

    close(ONCONFIG);

    $self->{ONCONFIG_DATA} = ( \%cfg );

}

sub get_msg_path {
    my ($self) = @_;
    return $self->{ONCONFIG_DATA}{'MSGPATH'};
}

sub get_temps {
    my ($self) = @_;
    return $self->{TEMP_DBSPACES};
}

sub get_servernum {
    my ($self) = @_;
    return $self->{ONCONFIG_DATA}{'SERVERNUM'};

}

sub check_state {
    my ( $self, $log, $cfg ) = @_;
    my ($onstat);
    eval {
        local $SIG{ALRM} = sub {
            $log->info("Onstat command failed to complete after 300 seconds");
        };
        alarm 300;
        $onstat = system("onstat - >/dev/null 2>/dev/null");
        alarm 0;
    };
    if ($@) {
        $log->error("onstat errored with $@");
        touch_stop( $cfg->{LOGDIR} );
        return 1;
    }

    $onstat = $onstat >> 8;

    if ( $onstat == -1 || $onstat == 255 ) {
        $log->info("Informix instance $ENV{'INFORMIXSERVER'} is not running");
        touch_stop( $cfg->{LOGDIR} );
        return 1;
    }
    elsif ( $onstat == 0 ) {
        $log->info("Informix instance $ENV{'INFORMIXSERVER'} is initialising");
        touch_stop( $cfg->{LOGDIR} );
        return 1;
    }
    elsif ( $onstat == 1 ) {
        $log->("Informix instance $ENV{'INFORMIXSERVER'} is in quiescent mode");
        touch_stop( $cfg->{LOGDIR} );
        return 1;
    }
    elsif ( $onstat == 2 ) {
        return 0;

        #This is usually the return code on an RSS
    }
    elsif ( $onstat == 3 ) {
        $log->("Informix instance $ENV{'INFORMIXSERVER'} is in backup mode");
        touch_stop( $cfg->{LOGDIR} );
        return 1;
    }
    elsif ( $onstat == 4 ) {
        $log->("Informix instance $ENV{'INFORMIXSERVER'} is shutting down");
        touch_stop( $cfg->{LOGDIR} );
        return 1;
    }
    elsif ( $onstat == 5 ) {
        return 0;

        #Online
    }
    elsif ( $onstat == 6 ) {

        # Don't want to interrupt any shared memory dumping
        $log->("Informix instance $ENV{'INFORMIXSERVER'} is aborting");
        touch_stop( $cfg->{LOGDIR} );
        return 1;
    }
    elsif ( $onstat == 7 ) {
        $log->(
            "Informix instance $ENV{'INFORMIXSERVER'} is in single-user mode");
        return 0;
    }
    else {
        $log->(
"Informix instance $ENV{'INFORMIXSERVER'}: unknown return code $onstat reported by \'onstat -\'."
        );
        touch_stop( $cfg->{LOGDIR} );
        return 1;
    }
    return 0;
}

sub load_partnums {
    my ( $cfg, $log_info, $part_info, $opts, ) = @_;

    get_databases( $opts, $part_info );
    get_other_partitions( $opts, 'sysmaster', $part_info );
    store( $part_info, $cfg->{PARTNSTORE} );

}

sub get_databases {
    my ( $opts, $partitions ) = @_;
    my ( @rows, $row );

    `dbaccess sysmaster\@$opts->{s} - << !EOF 2> /dev/null
unload to ".tables.tmp$$"
select name from sysdatabases
!EOF
`;

    open( FILE, ".tables.tmp$$" ) || die $!;
    while ( $row = <FILE> ) {
        push( @rows, $row );
    }
    close(FILE);
    unlink(".tables.tmp$$");

    foreach $row (@rows) {
        chomp $row;
        $row =~ s/\|$//g;
        get_partitions( $opts, $row, $partitions )

    }

}

sub get_partitions {
    my ( $opts, $db, $partitions ) = @_;
    my ( $row, @rows );
    my ( $dec, $partnum, $tabname, $dbspace, $index, $partition );

    `dbaccess $db\@$opts->{s} - << !EOF 2> /dev/null
unload to ".tables.tmp$$"
select t.partnum,hex(t.partnum),TRIM(dbsname),TRIM(NVL(ta.tabname,t.tabname)),TRIM(NVL(dbspace,DBINFO("DBSPACE",t.partnum))),TRIM(i.idxname),TRIM(s.partition)
from
sysmaster:systabnames t, outer(sysfragments s),outer(sysindexes i, systables ta)
where t.partnum=s.partn
and i.idxname=t.tabname
and i.tabid=ta.tabid
and t.dbsname="$db"

!EOF
`;

    open( FILE, ".tables.tmp$$" ) || die $!;
    while ( $row = <FILE> ) {
        push( @rows, $row );
    }
    close(FILE);
    unlink(".tables.tmp$$");

    foreach $row (@rows) {
        chomp $row;
        $row =~ s/\|$//g;
        ( $dec, $partnum, $db, $tabname, $dbspace, $index, $partition ) =
          split( /\|/, $row );

        $partnum = lc($partnum);
        $partnum =~ s/0x//g;
        $partnum =~ s/^[0]+//g;

        if ( $index !~ /\S+/ ) {
            $index = undef;
        }
        if ( $partition !~ /\S+/ ) {
            $partition = undef;
        }

        if ( defined $index && defined $partition ) {
            if ( $partition eq $dbspace ) {
                $partitions->{HEX}{$partnum} =
                  "${db}:${tabname}#${index},${dbspace}";
                $partitions->{DEC}{$dec} =
                  "${db}:${tabname}#${index},${dbspace}";
            }
            else {
                $partitions->{HEX}{$partnum} =
                  "${db}:${tabname}#${index}:$partition,${dbspace}";
                $partitions->{DEC}{$dec} =
                  "${db}:${tabname}#${index}:$partition,${dbspace}";
            }
        }
        elsif ( defined $index && !defined $partition ) {
            $partitions->{HEX}{$partnum} = "${db}:${tabname}#${index},$dbspace";
            $partitions->{DEC}{$dec}     = "${db}:${tabname}#${index},$dbspace";
        }
        elsif ( !defined $index && !defined $partition ) {
            $partitions->{HEX}{$partnum} = "${db}:${tabname},$dbspace";
            $partitions->{DEC}{$dec}     = "${db}:${tabname},$dbspace";
        }
        elsif ( !defined $index && defined $partition ) {
            if ( $partition eq $dbspace ) {
                $partitions->{HEX}{$partnum} = "${db}:${tabname},$dbspace";
                $partitions->{DEC}{$dec}     = "${db}:${tabname},$dbspace";
            }
            else {
                $partitions->{HEX}{$partnum} =
                  "${db}:${tabname}:$partition,$dbspace";
                $partitions->{DEC}{$dec} =
                  "${db}:${tabname}:$partition,$dbspace";
            }
        }
        else {
            $partitions->{HEX}{$partnum} = "${db}:${tabname},$dbspace";
            $partitions->{DEC}{$dec}     = "${db}:${tabname},$dbspace";
        }
    }

}

sub get_other_partitions {
    my ( $opts, $db, $partitions ) = @_;
    my ( $row, @rows );
    my ( $dec, $partnum, $tabname, $dbspace, $index, $partition );

    `dbaccess $db\@$opts->{s} - << !EOF 2> /dev/null
unload to ".tables.tmp$$"
select t.partnum,hex(t.partnum),TRIM(dbsname),TRIM(NVL(ta.tabname,t.tabname)),TRIM(NVL(dbspace,DBINFO("DBSPACE",t.partnum))),TRIM(i.idxname),TRIM(s.partition)
from
sysmaster:systabnames t, outer(sysfragments s),outer(sysindexes i, systables ta)
where t.partnum=s.partn
and i.idxname=t.tabname
and i.tabid=ta.tabid
union
select t.partnum,hex(t.partnum),"$db",TRIM(t.tabname),'SMI',' ',' '
from systables t
where not exists (
select partnum from systabnames
where systabnames.partnum=t.partnum
)
and t.tabtype='T'
and t.partnum !=0

!EOF
`;

    open( FILE, ".tables.tmp$$" ) || die $!;
    while ( $row = <FILE> ) {
        push( @rows, $row );
    }
    close(FILE);
    unlink(".tables.tmp$$");

    foreach $row (@rows) {
        chomp $row;
        $row =~ s/\|$//g;
        ( $dec, $partnum, $db, $tabname, $dbspace, $index, $partition ) =
          split( /\|/, $row );
        $partnum = lc($partnum);
        $partnum =~ s/0x//g;
        $partnum =~ s/^[0]+//g;

        next if ( defined $partitions->{$partnum} );

        if ( $index !~ /\S+/ ) {
            $index = undef;
        }
        if ( $partition !~ /\S+/ ) {
            $partition = undef;
        }

        if ( defined $index && defined $partition ) {
            if ( $partition eq $dbspace ) {
                $partitions->{HEX}{$partnum} =
                  "${db}:${tabname}#${index},${dbspace}";
                $partitions->{DEC}{$dec} =
                  "${db}:${tabname}#${index},${dbspace}";
            }
            else {
                $partitions->{HEX}{$partnum} =
                  "${db}:${tabname}#${index}:$partition,${dbspace}";
                $partitions->{DEC}{$dec} =
                  "${db}:${tabname}#${index}:$partition,${dbspace}";
            }
        }
        elsif ( defined $index && !defined $partition ) {
            $partitions->{HEX}{$partnum} = "${db}:${tabname}#${index},$dbspace";
            $partitions->{DEC}{$dec}     = "${db}:${tabname}#${index},$dbspace";
        }
        elsif ( !defined $index && !defined $partition ) {
            $partitions->{HEX}{$partnum} = "${db}:${tabname},$dbspace";
            $partitions->{DEC}{$dec}     = "${db}:${tabname},$dbspace";
        }
        elsif ( !defined $index && defined $partition ) {
            if ( $partition eq $dbspace ) {
                $partitions->{HEX}{$partnum} = "${db}:${tabname},$dbspace";
                $partitions->{DEC}{$dec}     = "${db}:${tabname},$dbspace";
            }
            else {
                $partitions->{HEX}{$partnum} =
                  "${db}:${tabname}:$partition,$dbspace";
                $partitions->{DEC}{$dec} =
                  "${db}:${tabname}:$partition,$dbspace";
            }
        }
        else {
            $partitions->{HEX}{$partnum} = "${db}:${tabname},$dbspace";
            $partitions->{DEC}{$dec}     = "${db}:${tabname},$dbspace";
        }
    }

}

1;
