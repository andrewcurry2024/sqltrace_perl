package Log::Writer;

use strict;
use warnings;
use Fcntl qw( :flock O_WRONLY O_APPEND O_TRUNC O_EXCL O_CREAT );
use POSIX qw(strftime);
use Params::Validate;
use Carp qw(croak);
use Devel::Backtrace;
use Net::SMTP;

use constant EMERGENCY => 0;
use constant EMERG     => 0;
use constant ALERT     => 1;
use constant CRITICAL  => 2;
use constant CRIT      => 2;
use constant ERROR     => 3;
use constant ERR       => 3;
use constant WARNING   => 4;
use constant WARN      => 4;
use constant NOTICE    => 5;
use constant NOTE      => 5;
use constant INFO      => 6;
use constant DEBUG     => 7;
use constant NOTHING   => 8;

BEGIN {
    for my $level (
        qw/DEBUG INFO NOTICE NOTE WARNING WARN ERROR ERR CRITICAL CRIT ALERT EMERGENCY EMERG/
      )
    {

        my $routine = lc($level);

        {    # start "no strict 'refs'" block
            no strict 'refs';

            *{"$routine"} = sub {
                my $self = shift;

   # we handoff the log level as upper case string as first argument to _print()
                return $self->_print( $level, @_ );
            };

            *{"is_$routine"} = sub {
                my $self = shift;
                return 1
                  if &{$level} >= $self->{minlevel}
                      && &{$level} <= $self->{maxlevel};
                return undef;
            };

            *{"would_log_$routine"} = sub {
                my $self = shift;
                return 1
                  if &{$level} >= $self->{minlevel}
                      && &{$level} <= $self->{maxlevel};
                return undef;
            };
        }    # end "no strict 'refs'" block
    }
}

sub new {
    my $class = shift;
    my %opts  = ();
    my $self  = bless \%opts, $class;
    my $bool  = qr/^[10]\z/;

    %opts = Params::Validate::validate(
        @_,
        {
            emailreciept => {
                type    => Params::Validate::SCALAR,
                regex   => qw/^(\w|\-|\_|\.)+\@((\w|\-|\_)+\.)+[a-zA-Z]+$/,
                default => 'andrew.curry@ardenta.com'
            },
            emailsender => {
                type    => Params::Validate::SCALAR,
                regex   => qw/^(\w|\-|\_|\.)+\@((\w|\-|\_)+\.)+[a-zA-Z]+$/,
                default => 'log.messenger@ardenta.com'
            },
            emailerrors => {
                type    => Params::Validate::SCALAR,
                regex   => $bool,
                default => 0,
            },
            filename =>
              { type => Params::Validate::SCALAR | Params::Validate::GLOBREF, },
            filelock => {
                type    => Params::Validate::SCALAR,
                regex   => $bool,
                default => 1,
            },
            fileopen => {
                type    => Params::Validate::SCALAR,
                regex   => $bool,
                default => 1,
            },
            reopen => {
                type    => Params::Validate::SCALAR,
                regex   => $bool,
                default => 1,
            },
            mode => {
                type    => Params::Validate::SCALAR,
                regex   => qr/^(append|excl|trunc)\z/,
                default => 'excl',
            },
            autoflush => {
                type    => Params::Validate::SCALAR,
                regex   => $bool,
                default => 1,
            },
            permissions => {
                type    => Params::Validate::SCALAR,
                regex   => qr/^[0-7]{3,4}\z/,
                default => '0644',
            },
            timeformat => {
                type    => Params::Validate::SCALAR,
                default => '%b %d %H:%M:%S',
            },
            newline => {
                type    => Params::Validate::SCALAR,
                regex   => $bool,
                default => 0,
            },
            prefix => {
                type    => Params::Validate::SCALAR,
                default => '[<--LEVEL-->] ',
            },
            minlevel => {
                type => Params::Validate::SCALAR,
                regex =>
qr/^([0-8]|nothing|debug|info|notice|note|warning|warn|error|err|critical|crit|alert|emergency|emerg)\z/,
                default => 0,
            },
            maxlevel => {
                type => Params::Validate::SCALAR,
                regex =>
qr/^([0-8]|nothing|debug|info|notice|note|warning|warn|error|err|critical|crit|alert|emergency|emerg)\z/,
                default => 4,
            },
            rewrite_to_stderr => {
                type    => Params::Validate::SCALAR,
                regex   => $bool,
                default => 0,
            },
            die_on_errors => {
                type    => Params::Validate::SCALAR,
                regex   => $bool,
                default => 1,
            },
            debug => {
                type    => Params::Validate::SCALAR,
                regex   => $bool,
                default => 0,
            },
            debug_mode => {
                type    => Params::Validate::SCALAR,
                regex   => qr/^[12]\z/,
                default => 1,
            },
            debug_skip => {
                type    => Params::Validate::SCALAR,
                regex   => qr/^\d+\z/,
                default => 0,
            },
            utf8 => {
                type    => Params::Validate::SCALAR,
                regex   => $bool,
                default => 0,
            },
        }
    );

    # build the prefix
    $self->_build_prefix;

    {    # start "no strict" block
        no strict 'refs';
        $opts{minlevel} = &{ uc( $opts{minlevel} ) }
          unless $opts{minlevel} =~ /^\d\z/;
        $opts{maxlevel} = &{ uc( $opts{maxlevel} ) }
          unless $opts{maxlevel} =~ /^\d\z/;
    }    # end "no strict" block

    if ( ref( $opts{filename} ) eq 'GLOB' ) {
        $opts{fh} = $opts{filename};
    }
    elsif ( $opts{filename} eq '*STDOUT' ) {
        $opts{fh} = \*STDOUT;
    }
    elsif ( $opts{filename} eq '*STDERR' ) {
        $opts{fh} = \*STDERR;
    }

    # if option filename is a GLOB, then we force some options and return
    if ( defined $opts{fh} ) {
        $opts{fileopen} = 1;
        $opts{reopen}   = 0;
        $opts{filelock} = 0;
        my $oldfh = select $opts{fh};
        $| = $opts{autoflush};
        select $oldfh;
        binmode $opts{fh}, ':utf8' if $self->{utf8};
        return $self;
    }

    if ( $opts{mode} eq 'append' ) {
        $opts{mode} = O_WRONLY | O_APPEND | O_CREAT;
    }
    elsif ( $opts{mode} eq 'excl' ) {
        $opts{mode} = O_WRONLY | O_EXCL | O_CREAT;
    }
    elsif ( $opts{mode} eq 'trunc' ) {
        $opts{mode} = O_WRONLY | O_TRUNC | O_CREAT;
    }

    $opts{permissions} = oct( $opts{permissions} );

    # open the log file permanent
    if ( $opts{fileopen} == 1 ) {
        $self->_open or return undef;
        $self->_setino if $opts{reopen} == 1;
    }

    return $self;
}

sub get_prefix { $_[0]->{prefix} }

sub set_prefix {
    my $self = shift;
    $self->{prefix} = shift;
    $self->_build_prefix;
}

sub trace {
    my $self = shift;
    return $self->_print( 'TRACE', @_ );
}

sub close {
    my $self = shift;

    if ( $self->{fileopen} == 1 ) {
        $self->_close or return undef;
    }

    return 1;
}

# to make it possible to call Log::Handler->errstr
sub errstr { $Log::Handler::ERRSTR }

sub DESTROY {
    my $self = shift;
    CORE::close( $self->{fh} )
      if $self->{fh}
          && !ref( $self->{filename} )
          && $self->{filename} !~ /^\*STDOUT\z|^\*STDERR\z/;
}

#
# private stuff
#

sub _open {
    my $self = shift;

    sysopen( my $fh, $self->{filename}, $self->{mode}, $self->{permissions} )
      or return $self->_raise_error(
        "unable to open logfile $self->{filename}: $!");
    chmod( $self->{permissions}, $self->{filename} );

    my $oldfh = select $fh;
    $| = $self->{autoflush};
    select $oldfh;

    binmode $fh, ':utf8' if $self->{utf8};
    $self->{fh} = $fh;

    return 1;
}

sub _close {
    my $self = shift;

    CORE::close( $self->{fh} )
      or return $self->_raise_error(
        "unable to close logfile $self->{filename}: $!");

    delete $self->{fh};

    return 1;
}

sub _setino {
    my $self = shift;
    $self->{inode} = ( stat( $self->{filename} ) )[1];
    return 1;
}

sub _checkino {
    my $self = shift;

    if ( -e $self->{filename} ) {
        my $ino = ( stat( $self->{filename} ) )[1];
        unless ( $self->{inode} == $ino ) {
            $self->_close or return undef;
            $self->_open  or return undef;
            $self->{inode} = $ino;
        }
    }
    else {
        $self->_close or return undef;
        $self->_open  or return undef;
        $self->_setino if $self->{reopen} == 1;
    }

    return 1;
}

sub _lock {
    my $self = shift;

    flock( $self->{fh}, LOCK_EX )
      or return $self->_raise_error(
        "unable to lock logfile $self->{filename}: $!");

    return 1;
}

sub _unlock {
    my $self = shift;

    flock( $self->{fh}, LOCK_UN )
      or return $self->_raise_error(
        "unable to unlock logfile $self->{filename}: $!");

    return 1;
}

sub _print {
    my $self  = shift;
    my $level = shift;

    # TRACE will be logged in any case
    if ( $level ne 'TRACE' ) {
        no strict 'refs';

        # return if we don't want log this level
        return 1
          unless &{$level} >= $self->{minlevel}
              && &{$level} <= $self->{maxlevel};
    }

    if ( !$self->{fileopen} ) {
        $self->_open or return undef;
    }
    elsif ( $self->{reopen} ) {
        $self->_checkino or return undef;
    }

    if ( $self->{filelock} ) {
        $self->_lock or return undef;
    }

    # now we build the message:
    # timestamp . prefix . message . caller . newline
    my $message = '';

    if ( $self->{timeformat} ) {
        $message .= $self->_set_time . ' ';
    }

    if ( length( $self->{prefix} ) ) {
        $message .= join( $level, @{ $self->{prefixes} } );
    }

    if (@_) {
        $message .= join( ' ', @_ );
    }

    if ( $self->{debug} || $level eq 'TRACE' ) {
        $message .= "\n" if $message =~ /.\z|^\z/;
        $message .= "\n" if $message !~ /\n$/;
        my $bt = Devel::Backtrace->new( $self->{debug_skip} );
        my $pt = $bt->points - 1;

        for my $p ( reverse 0 .. $pt ) {
            $message .= ' ' x 3 . "CALL($p):";
            my $c = $bt->point($p);
            for my $k (
                'package', 'filename',  'line',     'subroutine',
                'hasargs', 'wantarray', 'evaltext', 'is_require'
              )
            {
                next unless defined $c->{$k};

                if ( $self->{debug_mode} == 1 ) {
                    $message .= " $k($c->{$k})";
                }
                elsif ( $self->{debug_mode} == 2 ) {
                    $message .=
                      "\n" . ' ' x 6 . sprintf( '%-12s', $k ) . $c->{$k};
                }
            }
            $message .= "\n";
        }
    }
    elsif ( $self->{newline} && $message =~ /.\z|^\z/ )
    {    # I hope that this works on the most OSs
        $message .= "\n";
    }

    if (   $level eq 'ERROR'
        && $self->{emailerrors}
        && defined( $self->{emailsender} )
        && defined( $self->{emailreciept} ) )
    {
        _panic( $message, $self->{emailsender}, $self->{emailreciept} );
    }

    my $fh = $self->{fh};

    print $fh $message or do {
        print STDERR $message if $self->{rewrite_to_stderr};
        return $self->_raise_error("unable to print to logfile: $!");
    };

    if ( $self->{filelock} ) {
        $self->_unlock or return undef;
    }

    if ( !$self->{fileopen} ) {
        $self->_close or return undef;
    }

    return 1;
}

sub _panic {
    my ( $message, $sender, $reciept ) = @_;
    my ( $smtp, $hostname );

    $smtp = Net::SMTP->new('localhost');
    if ( !$smtp ) {

        #
        # catch smtp failure
        #

        return;
    }

    #
    # The hostname of the server is now required by
    # default on every message
    #

    if ( defined $ENV{HOSTNAME} ) {
        $hostname = $ENV{HOSTNAME};
    }
    else {
        $hostname = `/bin/hostname`;
        $hostname .= '';
    }

    if ( $smtp->mail($reciept) && $smtp->to( split( /,/, $reciept ) ) ) {
        $smtp->data();
        $smtp->datasend("To: $reciept\n");
        $smtp->datasend("From: $sender\n");
        $smtp->datasend("Subject: ERROR from $0 on $hostname\n");
        $smtp->datasend("\n");
        $smtp->datasend("\n $message \n");
        $smtp->dataend;
    }
    $smtp->quit;
}

sub _set_time {
    my $self = shift;
    my $time = strftime( $self->{timeformat}, localtime );
    return $time;
}

sub _build_prefix {
    my $self = shift;
    $self->{prefixes} = [ split( /<--LEVEL-->/, $self->{prefix} ) ];
}

sub _raise_error {
    my $self = shift;
    $Log::Handler::ERRSTR = shift;
    return undef unless $self->{die_on_errors};
    my $class = ref($self);
    croak "$class: " . $Log::Handler::ERRSTR;
}

1;

