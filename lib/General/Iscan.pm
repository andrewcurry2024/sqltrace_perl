package General::Iscan;
require Exporter;
use vars qw(@ISA @EXPORT);
@ISA = qw ( Exporter );
use strict;
use POSIX qw(strftime mktime setsid);

use File::Basename;
use File::Copy;
use Net::SMTP;
use Time::HiRes qw( usleep);

@EXPORT = qw(
  check_locked check_stopped
  remove_lock
  write_pid
);

sub check_locked {

    my ( $cfg, $log ) = @_;

    my ( $msg, $pid );

    if ( -e "$cfg->{LOCKDIR}/$cfg->{LOCKFILE}" ) {

        #
        # If lock file exists then the pid contained must be same
        # as the pid of current process or exit
        #

        open( FILE, "$cfg->{LOCKDIR}/$cfg->{LOCKFILE}" ) || do {
            $msg = "Unable to open Lock file";
            $log->info($msg);
            return 1;
        };
        $pid = <FILE>;
        chomp($pid);
        close(FILE);

        if ( $pid != $$ ) {
            $msg = "Another version of program now running.";
            $msg .= "Program with pid of $$ exiting";
            $log->info($msg);

            kill 'INT', $$;

            return 1;
        }
        else {
            return 0;
        }
    }
    else {

        #
        # We shouldnt be running without a lock file so exit
        #

        $msg = "Unable to open Lock file";
        $log->info($msg);
        return 1;
    }

}

#
# removes the lockfile
#

sub remove_lock {
    my ( $cfg, $log ) = @_;
    my ($msg);

    if ( -e "$cfg->{LOCKDIR}/$cfg->{LOCKFILE}" ) {
        unlink("$cfg->{LOCKDIR}/$cfg->{LOCKFILE}");
    }
}

#
# checks for a .lock_fix_pause
#

sub check_stopped {

    my ( $cfg, $log ) = @_;
    if ( -e "$cfg->{LOCKDIR}/$cfg->{LOCKFILE}_stop" ) {
        return 1;
    }
    else {
        return 0;
    }
}

#
# writes the pid to a lockfile
#

sub write_pid {

    my ( $pid, $opts, $cfg, $log ) = @_;
    my ($msg);
    my ( $tm, $rpid );

    if (   -e "$cfg->{LOCKDIR}/$cfg->{LOCKFILE}"
        && -s "$cfg->{LOCKDIR}/$cfg->{LOCKFILE}" )
    {

        $tm  = ( stat("$cfg->{LOCKDIR}/$cfg->{LOCKFILE}") )[9];
        $msg = "Lock File detected last modified at:";
        $msg .= strftime "%d/%m/%Y %T", localtime($tm);

        open( FILE, "$cfg->{LOCKDIR}/$cfg->{LOCKFILE}" ) || do {
            $msg =
              "Unable to open Lock file $cfg->{LOCKDIR}/$cfg->{LOCKFILE} at ";
            $log->info($msg);

            if ( !defined $opts->{r} || $opts->{r} ne 'restart' ) {
                exit;
            }
        };

        $rpid = <FILE>;
        chomp($rpid);
        close(FILE);
        $msg .= " with a PID of $rpid";

        $log->info($msg);

        if ( $opts->{r} && $opts->{r} eq "restart" ) {

            #
            # send SIGINT to pid
            #

            $msg = "Stopping the previous version";
            $log->info($msg);

            kill 'INT', $rpid;

            while ( kill 0, $rpid ) {
                usleep 100;
            }

            $msg = "A new instance is now running";
            $log->info($msg);

            if ( !defined $opts->{'D'} ) {
                make_daemon( $opts, $cfg, $log );
            }
            else {

                open( FILE, ">$cfg->{LOCKDIR}/$cfg->{LOCKFILE}" ) || do {
                    $msg =
"Unable to open Lock file $cfg->{LOCKDIR}/$cfg->{LOCKFILE} at ";
                    $log->info($msg);
                    exit;
                };

                print FILE $$;
                close(FILE);
            }
        }
        elsif ( $opts->{r} && $opts->{r} eq "stop" ) {
            kill 'INT', $rpid;

            while ( kill 0, $rpid ) {
                usleep 10;
            }
            remove_lock( $cfg, $log );

            $log->info("processes with a parent id $rpid stopped");
            exit;

        }
        elsif ( $opts->{r} && $opts->{r} eq "status" ) {

            if ( kill 0, $rpid ) {
                $log->info("PID $rpid detected and running");
                exit 1;
            }
            else {
                $log->info("PID $rpid detected and is not running");
                exit 0;
            }
        }

        else {
            exit;
        }
    }
    elsif ( $opts->{r} && $opts->{r} eq "status" ) {
        $log->info("$0 Is not running");
        exit;
    }
    elsif ( $opts->{r} && $opts->{r} eq "stop" ) {
        $log->info("$0 Is not running");
        remove_lock( $cfg, $log );
        exit;
    }
    else {
        if ( !defined $opts->{'D'} ) {
            make_daemon( $opts, $cfg, $log );
        }
        else {

            open( FILE, ">$cfg->{LOCKDIR}/$cfg->{LOCKFILE}" ) || do {
                $msg =
"Unable to open Lock file $cfg->{LOCKDIR}/$cfg->{LOCKFILE} at ";
                $log->info($msg);
                exit;
            };

            print FILE $$;
            close(FILE);
        }

    }

}

sub write_daemon_pid {

    my ( $pid, $log, $cfg ) = @_;
    my ($msg);

    open( FILE, ">$cfg->{LOCKDIR}/$cfg->{LOCKFILE}" ) || do {
        $msg = "No Lockfile Detected $cfg->{LOCKDIR}/$cfg->{LOCKFILE}";
        $log->info($msg);
        exit;
    };

    print FILE $pid;
    close(FILE);

}

sub make_daemon {
    my ( $opts, $cfg, $log ) = @_;
    my ( $msg, $keep, $pid );

    if ( !defined $opts->{D} ) {
        chdir '/var/tmp' or die "Can't chdir to /: $!";
        open STDIN,  '/dev/null'   or die "Can't read /dev/null: $!";
        open STDOUT, '>>/dev/null' or die "Can't write to /dev/null: $!";
        open STDERR, '>>/dev/null' or die "Can't write to /dev/null: $!";
        $pid = fork() and write_daemon_pid( $pid, $log, $cfg ) and exit;

        #setsid or die "Can't start a new session: $!";
        #umask 0;
    }
}

