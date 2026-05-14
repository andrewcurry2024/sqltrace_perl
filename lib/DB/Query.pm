package DB::Query;

use strict;
use warnings;
use DBI;

use vars qw($VERSION @ISA @EXPORT);

require Exporter;

#require Carp;
@ISA = qw(Exporter);

our $VERSION = '0.01';
@EXPORT = qw(new  setHandle  getHandle db_err);

sub new {
    my ( $class, $user, $password, $database, $server ) = @_;
    my $self = bless {
        'user'     => $user,
        'password' => $password,
        'database' => $database,
        'server'   => $server
    };

    #
    # initialise connection object
    #

    _init_db( $self, $user, $password, $server, $database );

    return $self;
}

sub _init_db {

    my ( $self, $user, $password, $server, $database ) = @_;

    my $DR = DBI->install_driver('Informix')
      || dberr( __FILE__, __LINE__, $DBI::errstr,
        "Driver Installation Failure\n" );

    my $DBH = $DR->connect(
        "$database\@$server",
        $user,
        $password,
        {
            RaiseError => 1,
            AutoCommit => 1,
            PrintError => 1,
            ChopBlanks => 1
        }
    ) || dberr( __FILE__, __LINE__, $DBI::errstr, "DB Connection Failure\n" );
    $DBH->do('SET LOCK MODE TO WAIT');
    $DBH->do('SET INFORMIXCONTIME 10');

    _setDBHandle( $self, $DBH );
}

sub _setDBHandle {
    my ( $self, $db ) = @_;
    $self->{'db_handle'} = $db;
}

sub dberr {

    my ( $file, $line, $errstr, $msg ) = @_;
    my ( %include, $err_msg );

    #
    # We have got here because of a DB problem
    #

    $err_msg = sprintf "Error with %s at %s - %s\n%s\n", $file, $line, $errstr,
      $msg;

    #
    # Need to add a proper error handler call
    #

    print $err_msg;
    exit;
}

sub setHandle {
    my ( $self, $query, $name ) = @_;
    $self->{'query_handle'}{$name} = $self->{'db_handle'}->prepare($query)
      || ( dberr( __FILE__, __LINE__, $DBI::errstr ) );

}

sub getHandle {
    my ( $self, $name ) = @_;
    return $self->{'query_handle'}{$name};
}

sub closeConnection {
    my ($self) = @_;
    my $dbh = $self->{'db_handle'};
    $dbh->disconnect || ( dberr( __FILE__, __LINE__, $DBI::errstr ) );
}
1;
__END__

=head1 NAME

DB::Query - Perl extension for setting up queries and retrieving the perpared handles

=head1 SYNOPSIS

  use DB::Query;

=head1 DESCRIPTION


=head1 SEE ALSO

=head1 AUTHOR

=cut


