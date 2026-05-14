package File::Modified;
$File::Modified::VERSION = '0.10';
use 5.006;
use strict;
use warnings;

our @ISA;

sub new {
    my ( $class, %args ) = @_;

    my $method = $args{method} || "MD5";
    my $files  = $args{files}  || [];

    my $self = {
        Defaultmethod => $method,
        Files         => {},
    };

    bless $self, $class;

    $self->addfile(@$files);

    return $self;
}

sub _make_digest_signature {
    my ( $self, $digest ) = @_;

    eval "use Digest::$digest";

    if ( !$@ ) {
        no strict 'refs';
        if ( @{"Digest::${digest}::ISA"} ) {
            @{"File::Modified::Signature::${digest}::ISA"} =
              qw(File::Modified::Signature::Digest);
            return 1;
        }
    }
    return undef;
}

sub add {
    my ( $self, $filename, $method ) = @_;
    $method ||= $self->{Defaultmethod};

    my $signatureclass = "File::Modified::Signature::$method";
    my $s = eval { $signatureclass->new($filename) };
    if ( !$@ ) {
        return $self->{Files}->{$filename} = $s;
    }
    else {

        # retry and try Digest::$method

        if ( $self->_make_digest_signature($method) ) {
            my $s = $signatureclass->new($filename);
            return $self->{Files}->{$filename} = $s;
        }
        else {
            return undef;
        }
    }
}

sub addfile {
    my ( $self, @files ) = @_;

    my @result;

    # We only return something if the caller wants it
    if ( defined wantarray ) {
        push @result, $self->add($_) for @files;
        return @result;
    }
    else {
        $self->add($_) for @files;
    }
}

sub update {
    my ($self) = @_;

    $_->initialize() for values %{ $self->{Files} };
}

sub changed {
    my ($self) = @_;

    return map { $_->{Filename} }
      grep { $_->changed() } ( values %{ $self->{Files} } );
}

1;

