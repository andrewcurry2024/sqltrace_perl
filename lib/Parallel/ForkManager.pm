package Parallel::ForkManager;
our $AUTHORITY = 'cpan:DLUX';

# ABSTRACT:  A simple parallel processing fork manager
$Parallel::ForkManager::VERSION = '1.17';
use POSIX ":sys_wait_h";
use Storable qw(store retrieve);
use File::Spec;
use File::Temp ();
use File::Path ();
use Carp;

use strict;

sub new {
    my ( $c, $processes, $tempdir ) = @_;

    my $h = {
        max_proc               => $processes,
        processes              => {},
        in_child               => 0,
        parent_pid             => $$,
        auto_cleanup           => ( $tempdir ? 0 : 1 ),
        waitpid_blocking_sleep => 1,
    };

    # determine temporary directory for storing data structures
    # add it to Parallel::ForkManager object so children can use it
    # We don't let it clean up so it won't do it in the child process
    # but we have our own DESTROY to do that.
    if ( not defined($tempdir) or not length($tempdir) ) {
        $tempdir = File::Temp::tempdir( CLEANUP => 0 );
    }
    die qq|Temporary directory "$tempdir" doesn't exist or is not a directory.|
      unless ( -e $tempdir && -d _ )
      ;    # ensure temp dir exists and is indeed a directory
    $h->{tempdir} = $tempdir;

    return bless( $h, ref($c) || $c );
}

sub start {
    my ( $s, $identification ) = @_;

    die "Cannot start another process while you are in the child process"
      if $s->{in_child};
    while ( $s->{max_proc} && ( keys %{ $s->{processes} } ) >= $s->{max_proc} )
    {
        $s->on_wait;
        $s->wait_one_child( defined $s->{on_wait_period} ? &WNOHANG : undef );
    }
    $s->wait_children;
    if ( $s->{max_proc} ) {
        my $pid = fork();
        die "Cannot fork: $!" if !defined $pid;
        if ($pid) {
            $s->{processes}->{$pid} = $identification;
            $s->on_start( $pid, $identification );
        }
        else {
            $s->{in_child} = 1 if !$pid;
        }
        return $pid;
    }
    else {
        $s->{processes}->{$$} = $identification;
        $s->on_start( $$, $identification );
        return 0;    # Simulating the child which returns 0
    }
}

sub finish {
    my ( $s, $x, $r ) = @_;

    if ( $s->{in_child} ) {
        if ( defined($r) ) {    # store the child's data structure
            my $storable_tempfile = File::Spec->catfile( $s->{tempdir},
                    'Parallel-ForkManager-'
                  . $s->{parent_pid} . '-'
                  . $$
                  . '.txt' );
            my $stored = eval { return &store( $r, $storable_tempfile ); };

# handle Storables errors, IE logcarp or carp returning undef, or die (via logcroak or croak)
            if ( not $stored or $@ ) {
                warn(
qq|The storable module was unable to store the child's data structure to the temp file "$storable_tempfile":  |
                      . join( ', ', $@ ) );
            }
        }
        CORE::exit( $x || 0 );
    }
    if ( $s->{max_proc} == 0 ) {    # max_proc == 0
        $s->on_finish( $$, $x, $s->{processes}->{$$}, 0, 0, $r );
        delete $s->{processes}->{$$};
    }
    return 0;
}

sub wait_children {
    my ($s) = @_;

    return if !keys %{ $s->{processes} };
    my $kid;
    do {
        $kid = $s->wait_one_child(&WNOHANG);
      } while defined $kid
          and ( $kid > 0 or $kid < -1 );    # AS 5.6/Win32 returns negative PIDs
}

*wait_childs            = *wait_children;    # compatibility
*reap_finished_children = *wait_children;    # behavioral synonym for clarity

sub wait_one_child {
    my ( $s, $par ) = @_;

    my $kid;
    while (1) {
        $kid = $s->_waitpid( -1, $par ||= 0 );

        last unless defined $kid;

        last if $kid == 0 || $kid == -1;    # AS 5.6/Win32 returns negative PIDs
        redo if !exists $s->{processes}->{$kid};
        my $id = delete $s->{processes}->{$kid};

        # retrieve child data structure, if any
        my $retrieved = undef;
        my $storable_tempfile =
          File::Spec->catfile( $s->{tempdir},
            'Parallel-ForkManager-' . $$ . '-' . $kid . '.txt' );
        if ( -e $storable_tempfile )
        { # child has option of not storing anything, so we need to see if it did or not
            $retrieved = eval { return &retrieve($storable_tempfile); };

            # handle Storables errors
            if ( not $retrieved or $@ ) {
                warn(
qq|The storable module was unable to retrieve the child's data structure from the temporary file "$storable_tempfile":  |
                      . join( ', ', $@ ) );
            }

            # clean up after ourselves
            unlink $storable_tempfile;
        }

        $s->on_finish( $kid, $? >> 8, $id, $? & 0x7f, $? & 0x80 ? 1 : 0,
            $retrieved );
        last;
    }
    $kid;
}

sub wait_all_children {
    my ($s) = @_;

    while ( keys %{ $s->{processes} } ) {
        $s->on_wait;
        $s->wait_one_child( defined $s->{on_wait_period} ? &WNOHANG : undef );
    }
}

*wait_all_childs = *wait_all_children;    # compatibility;

sub max_procs { $_[0]->{max_proc}; }

sub is_child { $_[0]->{in_child} }

sub is_parent { !$_[0]->{in_child} }

sub running_procs {
    my $self = shift;

    my @pids = keys %{ $self->{processes} };
    return @pids;
}

sub wait_for_available_procs {
    my ( $self, $nbr ) = @_;
    $nbr ||= 1;

    croak
"nbr processes '$nbr' higher than the max nbr of processes (@{[ $self->max_procs ]})"
      if $nbr > $self->max_procs;

    $self->wait_one_child until $self->max_procs - $self->running_procs >= $nbr;
}

sub run_on_finish {
    my ( $s, $code, $pid ) = @_;

    $s->{on_finish}->{ $pid || 0 } = $code;
}

sub on_finish {
    my ( $s, $pid, @par ) = @_;

    my $code = $s->{on_finish}->{$pid} || $s->{on_finish}->{0} or return 0;
    $code->( $pid, @par );
}

sub run_on_wait {
    my ( $s, $code, $period ) = @_;

    $s->{on_wait}        = $code;
    $s->{on_wait_period} = $period;
}

sub on_wait {
    my ($s) = @_;

    if ( ref( $s->{on_wait} ) eq 'CODE' ) {
        $s->{on_wait}->();
        if ( defined $s->{on_wait_period} ) {
            local $SIG{CHLD} = sub { }
              if !defined $SIG{CHLD};
            select undef, undef, undef, $s->{on_wait_period};
        }
    }
}

sub run_on_start {
    my ( $s, $code ) = @_;

    $s->{on_start} = $code;
}

sub on_start {
    my ( $s, @par ) = @_;

    $s->{on_start}->(@par) if ref( $s->{on_start} ) eq 'CODE';
}

sub set_max_procs {
    my ( $s, $mp ) = @_;

    $s->{max_proc} = $mp;
}

sub set_waitpid_blocking_sleep {
    my ( $self, $period ) = @_;
    $self->{waitpid_blocking_sleep} = $period;
}

sub waitpid_blocking_sleep {
    $_[0]->{waitpid_blocking_sleep};
}

sub _waitpid {    # Call waitpid() in the standard Unix fashion.
    my ( $self, undef, $flag ) = @_;

    return $flag ? $self->_waitpid_non_blocking : $self->_waitpid_blocking;
}

sub _waitpid_non_blocking {
    my $self = shift;

    for my $pid ( $self->running_procs ) {
        my $p = waitpid $pid, &WNOHANG or next;

        return $pid if $p != -1;

        warn
"child process '$pid' disappeared. A call to `waitpid` outside of Parallel::ForkManager might have reaped it.\n";

        # it's gone. let's clean the process entry
        delete $self->{processes}{$pid};
    }

    return;
}

sub _waitpid_blocking {
    my $self = shift;

    # pseudo-blocking
    if ( my $sleep_period = $self->{waitpid_blocking_sleep} ) {
        while () {
            my $pid = $self->_waitpid_non_blocking;

            return $pid if defined $pid;

            return unless $self->running_procs;

            select undef, undef, undef, $sleep_period;
        }
    }

    return waitpid -1, 0;
}

sub DESTROY {
    my ($self) = @_;

    if (   $self->{auto_cleanup}
        && $self->{parent_pid} == $$
        && -d $self->{tempdir} )
    {
        File::Path::remove_tree( $self->{tempdir} );
    }
}

1;

