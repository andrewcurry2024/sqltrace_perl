package General::PartInfo;
require Exporter;
use strict;
use Data::Dumper;
use vars qw(@ISA @EXPORT);
@ISA    = qw ( Exporter );
@EXPORT = qw (
  load_partitions
);

use vars qw (%opts %partitions);

#
# get initial base
#

sub load_partitions {
    my ( $opts, $partitions ) = @_;
    get_databases( $opts, $partitions );

    #
    # get other partitions
    #

    get_other_partitions( $opts, 'sysmaster', $partitions );

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
    my ( $partnum, $tabname, $dbspace, $index, $partition );

    `dbaccess $db\@$opts->{s} - << !EOF 2> /dev/null
unload to ".tables.tmp$$"
select hex(t.partnum),TRIM(dbsname),TRIM(NVL(ta.tabname,t.tabname)),TRIM(NVL(dbspace,DBINFO("DBSPACE",t.partnum))),TRIM(i.idxname),TRIM(s.partition)
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
        ( $partnum, $db, $tabname, $dbspace, $index, $partition ) =
          split( /\|/, $row );

        $partnum = lc($partnum);
        $partnum =~ s/0x//g;

        if ( $index !~ /\S+/ ) {
            $index = undef;
        }
        if ( $partition !~ /\S+/ ) {
            $partition = undef;
        }

        if ( defined $index && defined $partition ) {
            if ( $partition eq $dbspace ) {
                $partitions->{$partnum} =
                  "${db}:${tabname}#${index},${dbspace}";
            }
            else {
                $partitions->{$partnum} =
                  "${db}:${tabname}#${index}:$partition,${dbspace}";
            }
        }
        elsif ( defined $index && !defined $partition ) {
            $partitions->{$partnum} = "${db}:${tabname}#${index},$dbspace";
        }
        elsif ( !defined $index && !defined $partition ) {
            $partitions->{$partnum} = "${db}:${tabname},$dbspace";
        }
        elsif ( !defined $index && defined $partition ) {
            if ( $partition eq $dbspace ) {
                $partitions->{$partnum} = "${db}:${tabname},$dbspace";
            }
            else {
                $partitions->{$partnum} =
                  "${db}:${tabname}:$partition,$dbspace";
            }
        }
        else {
            $partitions->{$partnum} = "${db}:${tabname},$dbspace";
        }
    }

}

sub get_other_partitions {
    my ( $opts, $db, $partitions ) = @_;
    my ( $row, @rows );
    my ( $partnum, $tabname, $dbspace, $index, $partition );

    `dbaccess $db\@$opts->{s} - << !EOF 2> /dev/null
unload to ".tables.tmp$$"
select hex(t.partnum),TRIM(dbsname),TRIM(NVL(ta.tabname,t.tabname)),TRIM(NVL(dbspace,DBINFO("DBSPACE",t.partnum))),TRIM(i.idxname),TRIM(s.partition)
from
sysmaster:systabnames t, outer(sysfragments s),outer(sysindexes i, systables ta)
where t.partnum=s.partn
and i.idxname=t.tabname
and i.tabid=ta.tabid
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
        ( $partnum, $db, $tabname, $dbspace, $index, $partition ) =
          split( /\|/, $row );
        $partnum = lc($partnum);
        $partnum =~ s/0x//g;

        next if ( defined $partitions->{$partnum} );

        if ( $index !~ /\S+/ ) {
            $index = undef;
        }
        if ( $partition !~ /\S+/ ) {
            $partition = undef;
        }

        if ( defined $index && defined $partition ) {
            if ( $partition eq $dbspace ) {
                $partitions->{$partnum} =
                  "${db}:${tabname}#${index},${dbspace}";
            }
            else {
                $partitions->{$partnum} =
                  "${db}:${tabname}#${index}:$partition,${dbspace}";
            }
        }
        elsif ( defined $index && !defined $partition ) {
            $partitions->{$partnum} = "${db}:${tabname}#${index},$dbspace";
        }
        elsif ( !defined $index && !defined $partition ) {
            $partitions->{$partnum} = "${db}:${tabname},$dbspace";
        }
        elsif ( !defined $index && defined $partition ) {
            if ( $partition eq $dbspace ) {
                $partitions->{$partnum} = "${db}:${tabname},$dbspace";
            }
            else {
                $partitions->{$partnum} =
                  "${db}:${tabname}:$partition,$dbspace";
            }
        }
        else {
            $partitions->{$partnum} = "${db}:${tabname},$dbspace";
        }
    }

}
