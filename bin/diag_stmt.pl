#!/usr/bin/perl -w

use strict;
use warnings;
use FindBin;
use Getopt::Std;
use Data::Dumper;
use Digest::MD5 qw(md5_base64);
use lib "$FindBin::Bin/../lib";
use DB::Query;

use vars
  qw (%connections %sessions %part_info %opts $xml %tables %unknown %columns %schema @tables);

$| = 1;

if ( !defined $opts{s} ) {
    $opts{s} = $ENV{INFORMIXSERVER};
}

if ( -t STDIN ) {
    print "please redirect output to this program i.e. onstat -g stm  $0\n";
    exit;
}

my ( $user, $password, $dbserver, $database ) =
  ( '', '', 'offshore_pte_top', 'openbet_pte' );

(
    my $db_source = DBI->connect(
        "dbi:Informix:$database\@$dbserver",
        '', '', { AutoCommit => 1, PrintError => 1, ChopBlanks => 1 }
    )
) || &printerr( __FILE__, __LINE__, $DBI::errstr );

$db_source->do("SET LOCK MODE TO WAIT");
$db_source->do("SET ISOLATION TO DIRTY READ");

#
# get all tables
#

check_tables( $db_source, \@tables, \%columns, \%schema );

parse_stm( \%connections );
get_variables( \%connections, \%tables, \%unknown, \%schema );
my $filename;
foreach my $md5 ( keys %connections ) {
    $filename = $md5;
    $filename =~ s/\//backslash/g;

    if (   $connections{$md5}{SQL_TEXT} =~ /\?/
        && $connections{$md5}{SQL_TEXT} !~ /\?::/ )
    {
        print STDERR "$connections{$md5}{SQL_TEXT}\n";
    }
    else {

        if ( $connections{$md5}{SQL_TEXT} =~ /select/i ) {
            print
"\nSET EXPLAIN FILE TO '../explains/$filename.explain'; set explain ON AVOID_EXECUTE;\n";
            print "$connections{$md5}{SQL_TEXT}\n";
            print ";\n";
        }
    }

}

sub get_variables {
    my ( $connections, $tables, $unknown, $schema ) = @_;
    my ( $sql, @tables, @fields, $real_sql, $special );

  QUERY: foreach my $md5 ( keys %{$connections} ) {
        undef @tables;

        $real_sql = $connections->{$md5}{SQL_TEXT};
        if ( $real_sql =~
/([a-zA-Z]+\s*\(\s*[a-zA-Z]+\s*\(.*\)\s*,\s*\?\)\s*([!=<>]+|matches|line)\s*\?)/
          )
        {
            my $subs = $1;
            my $rep  = 999;
            my $ret  = $subs;
            $ret =~ s/\?/$rep/e;
            $ret =~ s/\?/100/e;
            $subs = quotemeta($subs);
            $connections->{$md5}{SQL_TEXT} =~ s/$subs/$ret/eg;
        }
        @fields = $real_sql =~ /mod\s*\(\s*\S+\s*,\?\)\s*=\s*\?/gi;
        foreach my $var (@fields) {
            if ( $var =~ /(mod\s*\(\s*\S+\s*,\?\)\s*=\s*\?)/i ) {
                my $subs = $1;
                my $ret  = $subs;
                $ret =~ s/\?/8/e;
                $ret =~ s/\?/0/e;
                $subs = quotemeta($subs);
                $connections->{$md5}{SQL_TEXT} =~ s/$subs/$ret/eg;

            }
        }
        $real_sql = $connections->{$md5}{SQL_TEXT};

        $sql = $connections->{$md5}{SQL_TEXT};

        if ( $sql =~ /\?/ ) {

            $sql =~ s/outer//g;
            $sql =~ s/\(//g;
            $sql =~ s/\)//g;
            $sql =~ s/\s+/ /g;

            while ( $sql =~ /join\s+(.*?)\s+on/ig ) {
                push @tables, $1;
            }
            while ( $sql =~ /,\s*([\w,_:@ ]+(?=where))/ig ) {
                push @tables, ( split( /\s*,\s*/, $1 ) );
            }
            while ( $sql =~
                /from\s+\(?\s*([\w,_:@ ]+(?=inner|outer|left|right|join))/ig )
            {
                push @tables, ( split( /\s*,\s*/, $1 ) );
            }
            $sql =~ s/left outer join//g;
            $sql =~ s/right outer join//g;
            $sql =~ s/inner join//g;
            $sql =~ s/left join/,/g;

            while ( $sql =~ /from\s+([\w,_:@ ]+(?=where))/ig ) {
                push @tables, ( split( /\s*,\s*/, $1 ) );
            }
            while ( $sql =~ /update\s+(\{.*\})*\s*(.*)?\s+set/ig ) {
                push @tables, ( split( /\s*,\s*/, $2 ) );
            }

            if ( $sql =~ /^insert|execute|table\(set|tmparc/i ) {

                delete $connections->{$md5};
                next QUERY;

            }
            elsif ( scalar(@tables) == 0 ) {
                print STDERR "SKIPPING $sql\n";
                next;
            }
        }
        else {
        }

        foreach my $tab (@tables) {
            chomp $tab;
            $tab =~ s/^\s+//g;
            $tab =~ s/\s+$//g;
            if ( $tab =~ /(\S+)?\s+(\S+)?/ ) {
                $tables{$1}                             = 1;
                $connections->{$md5}{TABLES}{ lc($1) }  = lc($2);
                $connections->{$md5}{RTABLES}{ lc($2) } = $1;
            }
            else {
                $tables{$tab}                             = 1;
                $connections->{$md5}{TABLES}{$tab}        = lc($tab);
                $connections->{$md5}{RTABLES}{ lc($tab) } = lc($tab);
            }

        }
        if ( $real_sql =~
/([a-zA-Z]+\s*\(\s*[a-zA-Z]+\s*\(.*\)\s*,\s*\?\)\s*([!=<>]+|matches|like)\s*\?)/i
          )
        {
            my $subs = $1;
            my $rep  = 999;
            my $ret  = $subs;
            $ret =~ s/\?/$rep/e;
            $ret =~ s/\?/100/e;
            $subs = quotemeta($subs);
            $connections->{$md5}{SQL_TEXT} =~ s/$subs/$ret/eg;
        }

        undef @fields;
        @fields =
          $real_sql =~ /(([A-Za-z0-9_\.]+\s*([!=<>]+|matches|like)+\s*\?)+)/ig;
        foreach my $var (@fields) {
            if ( $var =~ /([A-Za-z0-9_\.]+)\s*([!=<>]+|matches|like)+\s*\?+/i )
            {
                if ( $1 =~ /(\S+)\.(\S+)/ ) {
                    $connections->{$md5}{VARIABLE}{$var} =
                      $connections->{$md5}{RTABLES}{ lc($1) };
                }
                else {
                    if ( scalar(@tables) == 1 ) {
                        $connections->{$md5}{VARIABLE}{$var} = $tables[0];
                    }
                    else {
                        $connections->{$md5}{VARIABLE}{$var} =
                          workout_tables( $tables, $var, $schema );
                        $unknown->{$md5} = ( $connections->{$md5} );
                    }
                }
            }
        }
        @fields = $real_sql =~ /([A-Za-z0-9_\.]+\s*in\s*\(\s*[\?, ]+\s*\)+)/gi;
        foreach my $var (@fields) {
            if ( $var =~ /([A-Za-z0-9_\.]+)\s*in\s*\([\?, ]+\s*\)+/ ) {
                if ( $1 =~ /(\S+)\.\S+/ ) {
                    $connections->{$md5}{VARIABLE}{$var} =
                      $connections->{$md5}{RTABLES}{ lc($1) };
                }
                else {
                    if ( scalar(@tables) == 1 ) {
                        $connections->{$md5}{VARIABLE}{$var} = $tables[0];
                    }
                    else {
                        $connections->{$md5}{VARIABLE}{$var} =
                          workout_tables( $tables, $var, $schema );
                        $unknown->{$md5} = ( $connections->{$md5} );
                    }
                }
            }
        }
        @fields = $real_sql =~ /([A-Za-z0-9_\.]+\s*between\s*\?\s*and\s*\?)/gi;
        foreach my $var (@fields) {
            if ( $var =~ /([A-Za-z0-9_\.]+)\s*between\s*\?\s*and\s*\?/ ) {
                if ( $1 =~ /(\S+)\.\S+/ ) {
                    $connections->{$md5}{VARIABLE}{$var} =
                      $connections->{$md5}{RTABLES}{ lc($1) };
                }
                else {
                    if ( scalar(@tables) == 1 ) {
                        $connections->{$md5}{VARIABLE}{$var} = $tables[0];
                    }
                    else {
                        $connections->{$md5}{VARIABLE}{$var} =
                          workout_tables( $tables, $var, $schema );
                        $unknown->{$md5} = ( $connections->{$md5} );
                    }
                }
            }
        }
        @fields = $real_sql =~ /([A-Za-z]+\s*\(.*\)\s*[=><!]+\s*\?)/gi;
        foreach my $var (@fields) {
            if ( $var =~ /[A-Za-z]+\s*\((.*)\)\s*[=><!]+\s*\?/ ) {
                $special = $1;
                if ( $special =~ /\,/ ) {
                    $special = ( split( /,/, $special ) )[0];
                }
                if ( $special =~ /(\S+)\.\S+/ ) {
                    $connections->{$md5}{VARIABLE}{$var} =
                      $connections->{$md5}{RTABLES}{ lc($special) };
                }
                else {
                    if ( scalar(@tables) == 1 ) {
                        $connections->{$md5}{VARIABLE}{$var} = $tables[0];
                    }
                    else {
                        $connections->{$md5}{VARIABLE}{$var} =
                          workout_tables( $tables, $special, $schema );
                        $unknown->{$md5} = ( $connections->{$md5} );
                    }
                }
            }
        }
        @fields = $real_sql =~ /((\'\S+\')\s*=\s*\?)/g;
        foreach my $var (@fields) {
            if ( $var =~ /((\'\S+\')\s*=\s*\?)/ ) {
                my $subs = $1;
                my $rep  = $2;
                my $ret  = $subs;
                $ret =~ s/\?/$rep/ge;
                $subs = quotemeta($subs);
                $connections->{$md5}{SQL_TEXT} =~ s/$subs/$ret/eg;
            }
        }

        @fields = $real_sql =~ /(\?\s*=\s*(\'\S+\'))/g;
        foreach my $var (@fields) {
            if ( $var =~ /(\?\s*=\s*(\'\S+\'))/ ) {
                my $subs = $1;
                my $rep  = $2;
                my $ret  = $subs;
                $ret =~ s/\?/$rep/ge;
                $subs = quotemeta($subs);
                $connections->{$md5}{SQL_TEXT} =~ s/$subs/$ret/eg;

            }
        }
        @fields = $real_sql =~ /current\s*[-+]\s*\?\s*units/gi;
        foreach my $var (@fields) {
            if ( $var =~ /(current\s*[-+]\s*\?\s*units)/i ) {
                my $subs = $1;
                my $rep  = 600;
                my $ret  = $subs;
                $ret =~ s/\?/$rep/ge;
                $subs = quotemeta($subs);
                $connections->{$md5}{SQL_TEXT} =~ s/$subs/$ret/eg;

            }
        }
        $connections->{$md5}{SQL_TEXT} =~ s/first\s+\?/first 1000/gi;

        #
        # this is where we try and see the values we need to substiture in
        #

        foreach my $subs ( keys %{ $connections->{$md5}{VARIABLE} } ) {
            if (   $subs =~ /(\S+)\.(\S+)/
                && $subs !~
                /[a-zA-Z]+\s*(\(.*\))\s*([!=<>]+|matches|like)+\s*\?/i )
            {
                if ( defined $connections->{$md5}{VARIABLE}{$subs}
                    && !
                    defined $schema->{
                        lc( $connections->{$md5}{VARIABLE}{$subs} ) }
                    { lc($2) } )
                {

#
# need to check the other tables involved in case its a messy query which uses the same names... BAD!!
# not nice but will work
#

                    foreach my $table ( keys %{ $connections->{$md5}{TABLES} } )
                    {
                        if ( defined $schema->{ lc($table) }{ lc($2) } ) {
                            $connections->{$md5}{VARIABLE}{$subs} = $table;
                            last;
                        }

                    }

                    if ( defined $connections->{$md5}{VARIABLE}{$subs}
                        && !
                        defined $schema->{
                            lc( $connections->{$md5}{VARIABLE}{$subs} ) }
                        { lc($2) } )
                    {
                        print STDERR
"No table defined for $connections->{$md5}{VARIABLE}{$subs} removing $2\n";
                        delete( $connections->{$md5} );
                        next QUERY;
                    }

                }
                my $value =
                  ( $schema->{ lc( $connections->{$md5}{VARIABLE}{$subs} ) }
                      { lc($2) } );
                if ( !defined $value ) {
                    print STDERR "$subs\n";
                    print STDERR Dumper( $connections->{$md5} );
                    print STDERR "HELLO IM HERE\n";
                }
                if ( $value !~ /^\d+$/ ) {
                    $value = "'$value'";
                }
                my $ret = $subs;
                $ret =~ s/\?/$value/ge;

                $subs = quotemeta($subs);
                $connections->{$md5}{SQL_TEXT} =~ s/$subs/$ret/eg;
            }
            elsif ( $subs =~ /[a-zA-Z]+\s*\((.*)\)\s*[=><!]+\s*\?/ ) {

                $special = $1;
                if ( $special =~ /\,/ ) {
                    $special = ( split( /,/, $special ) )[0];
                }

                if ( defined $connections->{$md5}{VARIABLE}{$subs}
                    && !
                    defined $schema->{
                        lc( $connections->{$md5}{VARIABLE}{$subs} ) }
                    {$special} )
                {

                    #need to work out my tables

                    foreach my $table ( keys %{ $connections->{$md5}{TABLES} } )
                    {
                        if ( defined $schema->{ lc($table) }{$special} ) {
                            $connections->{$md5}{VARIABLE}{$subs} = $table;
                            last;
                        }

                    }

                    if ( defined $connections->{$md5}{VARIABLE}{$subs}
                        && !
                        defined $schema->{
                            lc( $connections->{$md5}{VARIABLE}{$subs} ) }
                        {$special} )
                    {
                        print STDERR
"No table defined for $connections->{$md5}{VARIABLE}{$subs} removing $subs $special\n";
                        delete( $connections->{$md5} );
                        next QUERY;
                    }

                }
                my $value =
                  ( $schema->{ lc( $connections->{$md5}{VARIABLE}{$subs} ) }
                      {$special} );
                if ( !defined $value ) {
                    print STDERR "$subs $1\n";
                    print STDERR Dumper( $connections->{$md5} );
                    print STDERR "HELLO IM HERE 3\n";
                    print STDERR Dumper(
                        $schema->{ lc( $connections->{$md5}{VARIABLE}{$subs} ) }
                    );
                }
                if ( $value !~ /^\d+$/ ) {
                    $value = "'$value'";
                }
                my $ret = $subs;
                $ret =~ s/\?/$value/ge;

                $subs = quotemeta($subs);
                $connections->{$md5}{SQL_TEXT} =~ s/$subs/$ret/eg;

            }
            elsif ( $subs =~ /([\w_]+)/ ) {
                if ( defined $connections->{$md5}{VARIABLE}{$subs}
                    && !
                    defined $schema->{
                        lc( $connections->{$md5}{VARIABLE}{$subs} ) }{$1} )
                {

#
# need to check the other tables involved in case its a messy query which uses the same names... BAD!!
# not nice but will work
#

                    foreach my $table ( keys %{ $connections->{$md5}{TABLES} } )
                    {
                        if ( defined $schema->{ lc($table) }{ lc($1) } ) {
                            $connections->{$md5}{VARIABLE}{$subs} = $table;
                            last;
                        }

                    }

                    if ( defined $connections->{$md5}{VARIABLE}{$subs}
                        && !
                        defined $schema->{
                            lc( $connections->{$md5}{VARIABLE}{$subs} ) }
                        { lc($1) } )
                    {
                        print STDERR
"No table defined for $connections->{$md5}{VARIABLE}{$subs} removing $subs\n";
                        delete( $connections->{$md5} );
                        delete( $connections->{$md5} );
                        next QUERY;
                    }

                }
                my $value =
                  ( $schema->{ lc( $connections->{$md5}{VARIABLE}{$subs} ) }
                      { lc($1) } );
                if ( !defined $value ) {
                    print STDERR "$subs $1\n";
                    print STDERR Dumper( $connections->{$md5} );
                    print STDERR "HELLO IM HERE 2\n";
                    print STDERR Dumper(
                        $schema->{ lc( $connections->{$md5}{VARIABLE}{$subs} ) }
                    );
                }
                if ( $value !~ /^\d+$/ ) {
                    $value = "'$value'";
                }
                my $ret = $subs;
                $ret =~ s/\?/$value/ge;

                $subs = quotemeta($subs);
                $connections->{$md5}{SQL_TEXT} =~ s/$subs/$ret/eg;
            }
        }
    }
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

sub handle_statment_text {
    my ( $files, $connections ) = @_;
    my ( $digest, $sql, $line, $find, $replace );

    return if ( scalar @{$files} == 0 );
    for ( my $i = 0 ; $i < scalar @{$files} ; $i++ ) {
        next if ( !defined $files->[$i] );
        $files->[$i] =~ s/^\s_//g;
        if ( $files->[$i] =~ /--\+/ ) {
            $sql .= " $files->[$i]\n";
        }
        elsif ( $files->[$i] =~ /(.*)--/ && $files->[$i] !~ /\'[-]+\'/ ) {
            $sql .= $1;
        }
        elsif ( $files->[$i] =~ /^\s*--/ ) {
            next;
        }
        else {
            $sql .= " $files->[$i]";
        }
    }

    if ( !defined $sql ) {
        print STDERR Dumper($files);
        exit;
    }

    $sql =~ s/^\s+//g;
    $sql =~ s/\s+$//g;
    $sql =~ s/;\s*$//g;
    $sql =~ s/[^\S\r\n]+/ /g;

    $digest = md5_base64($sql);
    $connections{$digest}{SQL_TEXT} = $sql;
    return $digest;
}

sub get_table_data {
    my ( $db_source, $tabname, $cols, $ret, $def ) = @_;
    my ( $sql, $tabnames_cid, $value );

    $sql = "
SELECT FIRST 1 * from $tabname;
";

    ( $tabnames_cid = $db_source->prepare("$sql") )
      || &printerr( __FILE__, __LINE__, $DBI::errstr );

    ( $tabnames_cid->execute() )
      || &printerr( __FILE__, __LINE__, $DBI::errstr );

    my $src_tables = $tabnames_cid->fetchall_arrayref();

    foreach my $colno ( keys %{$cols} ) {
        if ( defined $src_tables->[0][ $colno - 1 ] ) {
            $ret->{$tabname}{ $cols->{$colno}{colname} } =
              $src_tables->[0][ $colno - 1 ];
        }
        else {
            $value = $def->{ $cols->{$colno}{colname} }{coltype};
            $value = ( split( /:/, $value ) )[1];
            $ret->{$tabname}{ $cols->{$colno}{colname} } = $value;
        }

    }

}

sub check_tables {
    my ( $db_source, $tables, $columns, $ret ) = @_;
    my ( $sql, $tabnames_cid, $src_tables, $ele, $src_cols, $column_cid,
        %default );

    #
    # check table names
    #

    $sql = "
SELECT tabname,tabid,owner from systables
WHERE tabid > 99
and tabtype='T'
;
";

    ( $tabnames_cid = $db_source->prepare("$sql") )
      || &printerr( __FILE__, __LINE__, $DBI::errstr );

    ( $tabnames_cid->execute() )
      || &printerr( __FILE__, __LINE__, $DBI::errstr );

    $src_tables = $tabnames_cid->fetchall_hashref( [ 'tabname', 'tabid' ] );

    #
    # check table structures
    #

    $sql = "
	SELECT DISTINCT t.tabname,c.colname,c.colno,c.coltype,c.collength,d.type||' '||TRIM((d.default)::varchar(128)) as default
	FROM syscolumns c, systables t, outer (sysdefaults d)
	WHERE t.tabid=c.tabid
	AND t.tabid > 99
	AND t.tabid=d.tabid
	AND d.colno=c.colno
	AND d.tabid=c.tabid
	AND d.class='T'
	AND t.tabtype='T'
	ORDER BY 1,3
";

    ( $column_cid = $db_source->prepare("$sql") )
      || &printerr( __FILE__, __LINE__, $DBI::errstr );

    ( $column_cid->execute() )
      || &printerr( __FILE__, __LINE__, $DBI::errstr );

    $src_cols = $column_cid->fetchall_hashref( [ 'tabname', 'colno' ] );

    foreach my $tabname ( keys %{$src_cols} ) {
        foreach my $colno ( keys %{ $src_cols->{$tabname} } ) {
            foreach my $key ( keys %{ $src_cols->{$tabname}{$colno} } ) {
                if ( $key eq 'coltype' ) {
                    $default{$tabname}{ $src_cols->{$tabname}{$colno}{colname} }
                      {$key} =
                      check_coltype( $src_cols->{$tabname}{$colno}{$key} );
                    $default{$tabname}{ $src_cols->{$tabname}{$colno}{colname} }
                      {$key} =~ s/^\s+//g;

                }
                else {

                  # $default{$tabname}{ $src_cols->{$tabname}{$colno}{colname} }
                  #   {$key} = $src_cols->{$tabname}{$colno}{$key};
                }
            }
        }
    }

    foreach my $tabname ( keys %{$src_cols} ) {
        foreach my $colno ( keys %{ $src_cols->{$tabname} } ) {

            $columns->{$tabname}{$colno} =
              $src_cols->{$tabname}{$colno}{colname};
        }
        get_table_data( $db_source, $tabname, $src_cols->{$tabname}, $ret,
            $default{$tabname} );
    }

}

sub check_coltype {
    my ($coltype) = @_;
    my $allow_nulls = ' ';
    if ( $coltype >= 256 ) {
        $coltype     = $coltype - 256;
        $allow_nulls = 'NOT NULL ';
    }

    if ( $coltype == 0 ) {
        return ${allow_nulls} . ':C';
    }
    elsif ( $coltype == 1 ) {
        return ${allow_nulls} . ':1';
    }
    elsif ( $coltype == 2 ) {
        return ${allow_nulls} . ':1';
    }
    elsif ( $coltype == 3 ) {
        return ${allow_nulls} . ':1.0';
    }
    elsif ( $coltype == 4 ) {
        return ${allow_nulls} . ':1.0';
    }
    elsif ( $coltype == 5 ) {
        return ${allow_nulls} . ':1.0';
    }
    elsif ( $coltype == 6 ) {
        return ${allow_nulls} . ':1';
    }
    elsif ( $coltype == 7 ) {
        return ${allow_nulls} . ':2019-01-10';
    }
    elsif ( $coltype == 8 ) {
        return ${allow_nulls} . ':10.00';
    }
    elsif ( $coltype == 10 ) {
        return ${allow_nulls} . ':2019-01-01 11:00:00';
    }
    elsif ( $coltype == 11 ) {
        return ${allow_nulls} . ':1';
    }
    elsif ( $coltype == 12 ) {
        return ${allow_nulls} . ':C';
    }
    elsif ( $coltype == 13 ) {
        return ${allow_nulls} . ':C';
    }
    elsif ( $coltype == 14 ) {
        return ${allow_nulls} . ':5';
    }
    elsif ( $coltype == 15 ) {
        return ${allow_nulls} . ':C';
    }
    elsif ( $coltype == 16 ) {
        return ${allow_nulls} . ':C';
    }
    elsif ( $coltype == 17 ) {
        return ${allow_nulls} . ':1';
    }
    elsif ( $coltype == 18 ) {
        return ${allow_nulls} . ':1';
    }
    elsif ( $coltype == 19 ) {
        return ${allow_nulls} . ':SET';
    }
    elsif ( $coltype == 20 ) {
        return ${allow_nulls} . ':MULTISET';
    }
    elsif ( $coltype == 21 ) {
        return ${allow_nulls} . ':LIST';
    }
    elsif ( $coltype == 22 ) {
        return ${allow_nulls} . ':ROW';
    }
    elsif ( $coltype == 23 ) {
        return ${allow_nulls} . ':COLLECTION';
    }
    elsif ( $coltype == 24 ) {
        return ${allow_nulls} . ':ROWREF';
    }
    elsif ( $coltype == 40 ) {
        return ${allow_nulls} . ':OPAQUE VARIABLE';
    }
    elsif ( $coltype == 41 ) {
        return ${allow_nulls} . ':OPAQUE FIXED';
    }
    elsif ( $coltype == 42 ) {
        return ${allow_nulls} . ':8';
    }
    elsif ( $coltype == 52 ) {
        return ${allow_nulls} . ':5778977';
    }
    elsif ( $coltype == 53 ) {
        return ${allow_nulls} . ':6';
    }
    else {
        return ${allow_nulls} . ':UNKNOWN DATA TYPE';
    }
}

sub workout_tables {
    my ( $tables, $column, $schema ) = @_;
    foreach my $tab ( keys %{$tables} ) {
        if ( defined $schema->{$tab}{$column} ) {
            return $tab;
        }
    }

}

sub parse_stm {
    my ($connections) = @_;
    my ( $line, @lines, $md5, $digest, $seen, $moved );
    my (@data);
    $seen  = 0;
    $moved = 0;
    my $ifh = *STDIN;
    while ( $line = <$ifh> ) {
        chomp $line;
        push( @data, $line );
    }
    for ( my $i = 0 ; $i < scalar(@data) ; $i++ ) {
        next if ( !defined $data[$i] );
        next if ( $data[$i] =~ /^IBM/ );
        next if ( $data[$i] =~ /^\s*$/ );
        if (   $data[$i] =~ /--\s*stmt:/i
            || $data[$i] =~ /^\s*session\s+\d+/i
            || $data[$i] =~ /^[0-9A-Fa-f]+\s+\S+/
            || $data[$i] =~ /sdblock\s+heapsz/ )
        {
            if ( scalar(@lines) > 0 ) {
                $digest = handle_statment_text( \@lines, $connections );
                undef @lines;
                undef $digest;
            }

        }
        if ( $data[$i] =~
/^[0-9A-Fa-f]+\s+\S+\s*((\bselect\b|\binsert\b|\bdelete\b|\bupdate\b|\bexecute\b).*)/i
            || $data[$i] =~
            /^\s*((\bselect\b|\binsert\b|\bdelete\b|\bupdate\b|\bexecute\b).*)/i
            || $data[$i] =~
/^[0-9A-Fa-f]+\s+\S+\s*[-]+\s*((\bselect\b|\binsert\b|\bdelete\b|\bupdate\b|\bexecute\b).*)/i
          )
        {
            push( @lines, $1 );
        }
        elsif ( defined $data[$i] ) {
            if (   ( $data[$i] !~ /^--/ )
                && $data[$i] !~ /^[0-9A-Fa-f]+\s+\S+/
                && $data[$i] !~ /^\s+$/i
                && $data[$i] !~ /<SPL/i
                && $data[$i] !~ /^session/i
                && $data[$i] !~ /sdblock\s+heapsz/ )
            {
                if (   $data[$i] =~ /.*?\s*[-][-]+\s*.*/
                    && $data[$i] !~ /\'[-]+\'/ )
                {
                    if ( defined $1 ) {
                        push( @lines, $1 );
                    }
                    else {
                        push( @lines, $data[$i] );
                    }
                }
                else {
                    push( @lines, $data[$i] );
                }
            }
        }

    }
    if ( scalar(@lines) > 0 ) {
        $digest = handle_statment_text( \@lines, $connections );
    }
}
