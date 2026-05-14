package SQLTracing::Plugin::XMLGenerator;

use strict;
use warnings;
use POSIX 'strftime';
use Data::Dumper;
use vars qw($VERSION @ISA @EXPORT);
use Storable qw(retrieve);
use XML::LibXML;
use Digest::MD5 qw(md5_base64);
use XML::Validation qw(load_dtd validate_xml);
use Time::Local;

require Exporter;

#require Carp;
@ISA = qw(Exporter);

our $VERSION = '0.01';
@EXPORT = qw(init);

$| = 1;

sub init {
    my ( $self, $name, $cfg, $servernum, $errlog, $sleep, $log_info,$special_sql ) = @_;


    #
    # set up logging object to LOGDIR
    #
    #

    my ( %connections, %sessions, $partitions, $xml, $dtd, %times, $seen, $temps );

    my $log = Log::Writer->new(
        filename    => "$cfg->{LOGDIR}/xmlgenerator_${servernum}.log",
        mode        => 'append',
        timeformat  => '%Y-%m-%d %H:%M:%S',
        maxlevel    => $cfg->{LOGLEVEL},
        emailerrors => 0,
        newline     => 1,
        prefix      => '',
    );

    $log->debug("setting up log object");

    #
    # loop over hist outputs
    #
    
    $temps=$self->get_temps();


    $dtd = load_dtd( $log, $cfg->{DTD} );

    $partitions = retrieve( $cfg->{PARTNSTORE} );

    while ( !get_stop( $cfg->{LOGDIR} ) ) {

        %connections = ();
        %sessions    = ();
        $seen = $times{MAX};
	%times=();
	$times{SEEN}=$seen;

        get_hist( $cfg, $log, $errlog, $log_info, \%connections, \%sessions,
            $partitions, \%times, $temps,$special_sql);

        $xml = build_xml( $cfg, $log, \%connections, \%sessions, \%times );
        output_xml( $cfg, $xml, $log, $dtd );

        if ( $sleep > 5 ) {

            foreach my $sleep_itteration ( 1 .. ~~ ( $sleep / 5 ) ) {

                if ( get_stop( $cfg->{LOGDIR} ) ) {

                    return;
                }
                sleep(5);

            }

        }
        else {
            sleep $sleep;
        }

    }

}

sub get_stop {
    my $dir = shift;

    if ( -e "$dir/stop" ) {
        return 1;
    }

    return 0

}

sub get_hist {
    my ( $cfg, $log, $errlog, $log_info, $connections, $sessions, $partitions,
        $times,$temps,$special_sql )
      = @_;
    my (
        $state, $line,    $sql,  $digest,   $threads,
        $exp,   @explain, $type, $partno,   @session_tmp,
        $cost,  $sid,     @tmp,  @sessions, @lines,
        $md5,   %itt
    );
   my $regex=join('',@{$temps});
  $regex='^['.$regex.']';
  $regex=qr/$regex/;

    `onstat -g his > $cfg->{LOGDIR}/.ghist.tmp$$`;
    sleep 2;
    local $| = 1;
    open( TEST, "$cfg->{LOGDIR}/.ghist.tmp$$" ) || die $!;
    while ( $line = <TEST> ) {
        chomp $line;
        next if ( $line !~ /\S+/ );

	if (defined $line && $line =~/IBM Informix Dynamic Server Version (\d+\.\d+.\S+)\s/) {
	 $times->{VERSION}=$1;
        }
        if ( defined $line && $line =~ /Statement\s*#\s*\d+\s*:/i ) {
            push( @lines, $line );
            do {
                $line = <TEST>;
                if ( defined $line && $line =~ /\S+/ ) {
                    chomp $line;
                    push( @lines, $line );

                }
            } until ( $line =~ /Estimated\s+Estimated\s+Actual/ );
            $line = <TEST>;
            push( @lines, $line );
            $line = <TEST>;
            push( @lines, $line );

            $digest = handle_statment_text( \@lines, $connections,$special_sql );
            if ( defined $digest && $digest =~ /\S+/ ) {
                $md5 = handle_itterator( \@lines, $connections, $digest,
                    $partitions,$regex );
                handle_sessions( \@lines, $connections, $times, $sessions,
                    $digest, $md5, \%itt );
            }
            undef @lines;
            undef $digest;
        }
    }
    close(TEST);
    unlink("$cfg->{LOGDIR}/.ghist.tmp$$");
}

sub handle_sessions {
    my ( $files, $connections, $times, $sessions, $digest, $md5, $itt ) = @_;
    my ( $line, @session_tmp, $sid, $sample, $time, $timestamp );
    return if ( scalar @{$files} == 0 );
    for ( my $i = 0 ; $i < scalar @{$files} ; $i++ ) {
        if ( $files->[$i] =~ /Sess_id/ ) {
            $i++;
            $line = $files->[$i];
            $line =~ s/^\s*//g;

            if ( $line =~
                /(\d+)\s+(\d+)\s+(.*)\s+(\d+:\d+:\d+)\s+(\S+)\s+\S+\s+\S+/ )
            {
                $sid       = $1;
                $sample    = $4;
                $time      = $5;
                $timestamp = get_epoch( $sample, $times );

                if ( !defined $3 ) {
                    die "error";
                }
                $connections->{$digest}{SQL_PERF}{TOTAL_TIME} += $time;
                $connections->{$digest}{SQL_PERF}{TOTAL}++;
                $connections->{$digest}{SQL_TYPE} = $3;

                $sessions->{$digest}{$md5}{$sid}{$sample}{TIME} = $time;
                $sessions->{$digest}{$md5}{$sid}{$sample}{SAMPLE_TIME} =
                  $timestamp;
                $sessions->{$digest}{$md5}{$sid}{$sample}{TOTAL}++;
                $sessions->{$digest}{$md5}{$sid}{$sample}{USER_ID} = $2;

                $connections->{$digest}{SQL_TYPE} =~ s/\s+$//g;

                if ( !defined $connections->{$digest}{EXP}{$md5}{EXP_PERF}{MIN}
                    || $connections->{$digest}{EXP}{$md5}{EXP_PERF}{MIN} >
                    $time )
                {
                    $connections->{$digest}{EXP}{$md5}{EXP_PERF}{MIN} = $time;
                }
                if ( !defined $connections->{$digest}{EXP}{$md5}{EXP_PERF}{MAX}
                    || $connections->{$digest}{EXP}{$md5}{EXP_PERF}{MAX} <
                    $time )
                {
                    $connections->{$digest}{EXP}{$md5}{EXP_PERF}{MAX} = $time;
                }
                $connections->{$digest}{EXP}{$md5}{EXP_PERF}{TOTAL}++;
                $connections->{$digest}{EXP}{$md5}{EXP_PERF}{TOTAL_TIME}+=$time;

            }
            else {
                die "error";
            }
        }
        if ( $files->[$i] =~ /Estimated\s+Estimated\s+Actual/ ) {
            $line = $files->[ $i + 2 ];
            $line =~ s/^\s+//g;
            $sessions->{$digest}{$md5}{$sid}{$sample}{COST} +=
              ( split( /\s+/, $line ) )[0];
            $sessions->{$digest}{$md5}{$sid}{$sample}{ESTROWS} +=
              ( split( /\s+/, $line ) )[1];
            $sessions->{$digest}{$md5}{$sid}{$sample}{ACTROW} +=
              ( split( /\s+/, $line ) )[2];
            $sessions->{$digest}{$md5}{$sid}{$sample}{SQLMEMORY} +=
              ( split( /\s+/, $line ) )[6];

handle_min_max_avg((split( /\s+/, $line ) )[0],$connections->{$digest}{EXP}{$md5}{EXP_PERF},'COST');
handle_min_max_avg((split( /\s+/, $line ) )[1],$connections->{$digest}{EXP}{$md5}{EXP_PERF},'ESTROWS');
handle_min_max_avg((split( /\s+/, $line ) )[2],$connections->{$digest}{EXP}{$md5}{EXP_PERF},'ACTROW');
handle_min_max_avg((split( /\s+/, $line ) )[6],$connections->{$digest}{EXP}{$md5}{EXP_PERF},'SQLMEMORY');

        }
        if ( $files->[$i] =~ /Page\s+Buffer\s+Read/ ) {
            $line = $files->[ $i + 2 ];
            $line =~ s/^\s+//g;
            $sessions->{$digest}{$md5}{$sid}{$sample}{PAGEREAD} +=
              ( split( /\s+/, $line ) )[0];
            $sessions->{$digest}{$md5}{$sid}{$sample}{BUFFERREAD} +=
              ( split( /\s+/, $line ) )[1];
            $sessions->{$digest}{$md5}{$sid}{$sample}{READPERCCACHE} +=
              ( split( /\s+/, $line ) )[2];
            $sessions->{$digest}{$md5}{$sid}{$sample}{BUFFERIDXREAD} +=
              ( split( /\s+/, $line ) )[3];
            $sessions->{$digest}{$md5}{$sid}{$sample}{PAGEWRITE} +=
              ( split( /\s+/, $line ) )[4];
            $sessions->{$digest}{$md5}{$sid}{$sample}{BUFFERWRITE} +=
              ( split( /\s+/, $line ) )[5];
            $sessions->{$digest}{$md5}{$sid}{$sample}{WRITEPERCCACHE} +=
              ( split( /\s+/, $line ) )[6];
handle_min_max_avg((split( /\s+/, $line ) )[0],$connections->{$digest}{EXP}{$md5}{EXP_PERF},'PAGEREAD');
handle_min_max_avg((split( /\s+/, $line ) )[1],$connections->{$digest}{EXP}{$md5}{EXP_PERF},'BUFFERREAD');
handle_min_max_avg((split( /\s+/, $line ) )[2],$connections->{$digest}{EXP}{$md5}{EXP_PERF},'READPERCCACHE');
handle_min_max_avg((split( /\s+/, $line ) )[3],$connections->{$digest}{EXP}{$md5}{EXP_PERF},'BUFFERIDXREAD');
handle_min_max_avg((split( /\s+/, $line ) )[4],$connections->{$digest}{EXP}{$md5}{EXP_PERF},'PAGEWRITE');
handle_min_max_avg((split( /\s+/, $line ) )[5],$connections->{$digest}{EXP}{$md5}{EXP_PERF},'BUFFERWRITE');
handle_min_max_avg((split( /\s+/, $line ) )[6],$connections->{$digest}{EXP}{$md5}{EXP_PERF},'WRITEPERCCACHE');
        }
        if ( $files->[$i] =~ /Lock\s+Lock\s+LK/ ) {
            $line = $files->[ $i + 2 ];
            $line =~ s/^\s+//g;
            $sessions->{$digest}{$md5}{$sid}{$sample}{LOCKREQ} +=
              ( split( /\s+/, $line ) )[0];
            $sessions->{$digest}{$md5}{$sid}{$sample}{LOCKWAIT} +=
              ( split( /\s+/, $line ) )[1];
            $sessions->{$digest}{$md5}{$sid}{$sample}{LOCKWAITTIME} +=
              ( split( /\s+/, $line ) )[2];
            $sessions->{$digest}{$md5}{$sid}{$sample}{LOGSPACE} +=
              ( split( /\s+/, $line ) )[3];
            $sessions->{$digest}{$md5}{$sid}{$sample}{NUMSORTS} +=
              ( split( /\s+/, $line ) )[5];
            $sessions->{$digest}{$md5}{$sid}{$sample}{DISKSORTS} +=
              ( split( /\s+/, $line ) )[6];
            $sessions->{$digest}{$md5}{$sid}{$sample}{MEMORYSORTS} +=
              ( split( /\s+/, $line ) )[7];
handle_min_max_avg((split( /\s+/, $line ) )[0],$connections->{$digest}{EXP}{$md5}{EXP_PERF},'LOCKREQ');
handle_min_max_avg((split( /\s+/, $line ) )[1],$connections->{$digest}{EXP}{$md5}{EXP_PERF},'LOCKWAIT');
handle_min_max_avg((split( /\s+/, $line ) )[2],$connections->{$digest}{EXP}{$md5}{EXP_PERF},'LOCKWAITTIME');
handle_min_max_avg((split( /\s+/, $line ) )[3],$connections->{$digest}{EXP}{$md5}{EXP_PERF},'LOGSPACE');
handle_min_max_avg((split( /\s+/, $line ) )[5],$connections->{$digest}{EXP}{$md5}{EXP_PERF},'NUMSORTS');
handle_min_max_avg((split( /\s+/, $line ) )[6],$connections->{$digest}{EXP}{$md5}{EXP_PERF},'DISKSORTS');
handle_min_max_avg((split( /\s+/, $line ) )[7],$connections->{$digest}{EXP}{$md5}{EXP_PERF},'MEMORYSORTS');
        }
	if ( $files->[$i] =~ /Total\s+Total\s+Avg/ ) {
            $line = $files->[ $i + 2 ];
            $line =~ s/^\s+//g;
            $sessions->{$digest}{$md5}{$sid}{$sample}{TOTALEXE} +=
              ( split( /\s+/, $line ) )[0];
            $sessions->{$digest}{$md5}{$sid}{$sample}{TOTALTIME} +=
              ( split( /\s+/, $line ) )[1];   
            $sessions->{$digest}{$md5}{$sid}{$sample}{AVGTIME} +=
              ( split( /\s+/, $line ) )[2];
            $sessions->{$digest}{$md5}{$sid}{$sample}{MAXTIME} +=
              ( split( /\s+/, $line ) )[3];
            $sessions->{$digest}{$md5}{$sid}{$sample}{AVGIOWAIT} +=
              ( split( /\s+/, $line ) )[4];
            $sessions->{$digest}{$md5}{$sid}{$sample}{IOWAITTIME} +=
              ( split( /\s+/, $line ) )[5];
            $sessions->{$digest}{$md5}{$sid}{$sample}{AVGROWSPERSEC} +=
              ( split( /\s+/, $line ) )[6];
handle_min_max_avg((split( /\s+/, $line ) )[0],$connections->{$digest}{EXP}{$md5}{EXP_PERF},'TOTALEXE');
handle_min_max_avg((split( /\s+/, $line ) )[1],$connections->{$digest}{EXP}{$md5}{EXP_PERF},'TOTALTIME');
handle_min_max_avg((split( /\s+/, $line ) )[2],$connections->{$digest}{EXP}{$md5}{EXP_PERF},'AVGTIME');
handle_min_max_avg((split( /\s+/, $line ) )[3],$connections->{$digest}{EXP}{$md5}{EXP_PERF},'MAXTIME');
handle_min_max_avg((split( /\s+/, $line ) )[4],$connections->{$digest}{EXP}{$md5}{EXP_PERF},'AVGIOWAIT');
handle_min_max_avg((split( /\s+/, $line ) )[5],$connections->{$digest}{EXP}{$md5}{EXP_PERF},'IOWAITTIME');
handle_min_max_avg((split( /\s+/, $line ) )[6],$connections->{$digest}{EXP}{$md5}{EXP_PERF},'AVGROWSPERSEC');
        }

    }
}



sub handle_itterator {
    my ( $files, $connections, $digest, $partitions,$regex ) = @_;
    my ( $type, @explain, $exp, $line, $partno, $hex_partno, $md5 );

   

    foreach my $line ( @{$files} ) {
        chomp $line;
        if (   $line !~ /Iterator\/Explain/
            && $line !~ /Statement information:/ )
        {
            if ( $line =~
                /\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+(\d+)\s+(.*)/ )
            {
                $partno     = $1;
                $hex_partno = sprintf( "%x", $partno );
                $type       = $2;

                if ( $hex_partno =~ /$regex/ ) {
                    push( @explain, "temp_table($type)" );
                }
                elsif ( $partno =~ /^0$/ ) {
                    $partno = 0;
                }
                else {
                    if ( defined $partitions->{DEC}{$partno} ) {
                        $partno = $partitions->{DEC}{$partno};
                    }
                    else {
                        $partno = "unknown:$partno";
                    }
                    push( @explain, "$type($partno)" );
                }
            }
        }

    }
    $exp = join( ',', @explain );

    if ( $exp =~ /^\s*$/ ) {
        $exp = 'EMPTY';
    }
    $md5 = md5_base64($exp);
    $connections->{$digest}{EXP}{SQL}{$exp}++;
    $connections->{$digest}{EXP}{$exp}{MD5} = $md5;
    $connections->{$digest}{TOTAL}{$exp}++;
    return $md5;
}

sub handle_statment_text {
    my ( $files, $connections,$special_sql ) = @_;
    my ( $digest, $sql, $line, $find, $replace,$regex );

    return if ( scalar @{$files} == 0 );
    for ( my $i = 0 ; $i < scalar @{$files} ; $i++ ) {
        if (   $files->[$i] =~ /Procedure Call Stack:/
            || $files->[$i] =~ /Statement text:/ )
        {
            if ( $files->[$i] =~ /Procedure Call Stack:/ ) {
                $i++;
                $sql = $files->[$i];
                last;
            }
            else {
                $i++;
                do {
                    if (   defined $files->[$i]
                        && $files->[$i] !~ /using tables \[/
                        && $files->[$i] !~ /using table \[/
                        && $files->[$i] !~ /Iterator\/Explain/
                        && $files->[$i] !~ /Host Variables/ )
                    {
                        $sql .= $files->[$i];
                    }
                    $i++;
                  } until ( $files->[$i] =~ /Iterator\/Explain/
                      || $files->[$i] =~ /Host Variables/
                      || $files->[$i] =~ /Statement information:/
                      || $i == scalar @{$files} );
            }
        }
    }

    if ( !defined $sql ) {
        print Dumper($files);
        die "ERROR\n";
    }
#tmparccustomertoken_56015_xxxxx_xxxxx
    if ( $sql =~ /tmparc\w+_\S+_\S+/ ) {
        $find    = '(tmparc\w+)_\S+_\S+';
        $replace = '"$1_xxxxx_xxxxx"';
        $sql =~ s/$find/$replace /eeg;

        $find    = '(tmparc\w+)_\S+_\S+_\S+';
        $replace = '"$1_xxxxx_xxxxx"';
        $sql =~ s/$find/$replace /eeg;

        $find    = '(tmparc\w+)_\S+_xxxxx_xxxxx';
        $replace = '"$1_idx "';
        $sql =~ s/$find /${replace}/eeg;
    }
    $sql =~ s/\s+/ /g;
    $sql =~ s/\t+/ /g;
    $sql =~ s/^\s+//g;

#
# check if its one of the special cases
#

foreach my $special (keys %{$special_sql}) {


$regex=quotemeta($special);

if($sql =~/${regex}/im) {
	$sql=$special_sql->{$special};
}

}

    $digest = md5_base64($sql);
    $connections->{$digest}{SQL}{$sql}++;
    $connections->{$digest}{TOTAL}{$sql}++;
    $connections->{$digest}{SQL_TEXT} = $sql;
    return $digest;
}

sub build_xml {
    my ( $cfg, $log, $connections, $sessions, $times ) = @_;
    my ( $root, $doc );

    if ( !defined $doc ) {

        eval { $doc = XML::LibXML::Document->new( '1.0', 'UTF-8' ); };
        $@ && do {
            die "Couldn't create xml root element: $@";
            return 0;
        };

    }

    my $dtd_o = $doc->createInternalSubset( 'ClaranetSQLTrace', undef,
        'ClaranetSQLTrace.dtd' );
    $doc->setInternalSubset($dtd_o);
    $root = XML::LibXML::Element->new('ClaranetSQLTrace');

    build_queries( $connections, $sessions, $doc, $root );

    $root->setAttribute( 'min_sample_time', $times->{MIN_READ} );
    $root->setAttribute( 'max_sample_time', $times->{MAX_READ} );
    $root->setAttribute( 'version', $times->{VERSION} );

    #
    # create elements
    #

    $doc->setDocumentElement($root);

    return $doc;
}

sub build_queries {
    my ( $connections, $sessions, $doc, $ele ) = @_;
    my ( %teams, $team, %attributes, $child, $QueryNode );
    my $QueriesNode = $doc->createElement('Queries');
    foreach my $hash (

        sort {
            $connections->{$b}{SQL_PERF}{TOTAL_TIME} <=> $connections->{$a}
              {SQL_PERF}{TOTAL_TIME}
        }
        keys %{$connections}
      )
    {

        foreach my $sql ( keys %{ $connections->{$hash}{SQL} } ) {
            $QueryNode =
              handle_query( $connections->{$hash}, $sessions->{$hash}, $doc,
                $ele, $sql, $hash );
            $QueriesNode->appendChild($QueryNode);
            $ele->appendChild($QueriesNode);
        }

    }
}

sub handle_query {
    my ( $connection, $session, $doc, $ele, $sql, $md5 ) = @_;
    my $QueryNode;
    my $QueryText;
    my $Plans;
    my $Plan;
    my $Sessions;
    my $Session;
    $QueryNode = $doc->createElement('Query');
    $QueryText = $doc->createElement('QueryText');
    $Sessions  = $doc->createElement('QueryText');
    $Plans     = $doc->createElement('ExplainPlans');
    $Sessions  = $doc->createElement('Executions');
    $QueryNode->setAttribute( 'md5',      $md5 );
    $QueryNode->setAttribute( 'sql_type', $connection->{SQL_TYPE} );
    $QueryNode->setAttribute( 'total_time',
        $connection->{SQL_PERF}{TOTAL_TIME} );
    $QueryNode->setAttribute( 'total_executions_in_sample',
        $connection->{TOTAL}{$sql} );
    $QueryNode->setAttribute( 'total_explains',
        scalar( keys %{ $connection->{EXP}{SQL} } ) );
    $QueryText->appendText( $connection->{SQL_TEXT} );
    $QueryNode->appendChild($QueryText);

    foreach my $exp ( keys %{ $connection->{EXP}{SQL} } ) {

        $Plan = handle_plans( $connection->{EXP}{$exp}{MD5},
            $doc, $ele, $exp, $connection->{EXP} );
        $Plans->appendChild($Plan);
        foreach
          my $sid ( keys %{ $session->{ $connection->{EXP}{$exp}{MD5} } } )
        {
            foreach my $sample (
                keys %{ $session->{ $connection->{EXP}{$exp}{MD5} }{$sid} } )
            {
                $Session = handle_session(
                    $session->{ $connection->{EXP}{$exp}{MD5} }{$sid}{$sample},
                    $doc, $ele, $sid, $connection->{EXP}{$exp}{MD5}
                );
                $Sessions->appendChild($Session);
            }
        }
    }

    $QueryNode->appendChild($Plans);
    $QueryNode->appendChild($Sessions);

    return $QueryNode;
}

sub handle_plans {
    my ( $md5, $doc, $ele, $exp, $struct ) = @_;
my %interested=(
'COST' => 'cost',
'SQLMEMORY' => 'sql_memory',
'PAGEREAD' => 'page_reads',
'BUFFERREAD' => 'buffer_reads',
'READPERCCACHE' => 'read_percent_cache',
'BUFFERIDXREAD' => 'buffer_index_read',
'PAGEWRITE' => 'page_write',
'BUFFERWRITE' => 'buffer_write',
'WRITEPERCCACHE' => 'write_percent_cache',
'LOCKREQ' => 'lock_request',
'LOCKWAIT' => 'lock_wait',
'LOCKWAITTIME' => 'lock_wait_time',
'LOGSPACE' => 'log_space',
'NUMSORTS' => 'number_of_sorts',
'DISKSORTS' => 'disk_sorts',
'MEMORYSORTS' => 'memory_sorts',
'AVGIOWAIT' => 'average_io_wait',
'AVGROWSPERSEC' => 'average_rows_per_second'
);

   my $Plan     = $doc->createElement('ExplainPlan');
    my $PlanText = $doc->createElement('PlanText');
    $Plan->setAttribute( 'md5',                $md5 );
    $Plan->setAttribute( 'min_execution_time', $struct->{$md5}{EXP_PERF}{MIN} );
    $Plan->setAttribute( 'max_execution_time', $struct->{$md5}{EXP_PERF}{MAX} );
    $Plan->setAttribute( 'total_executions', $struct->{$md5}{EXP_PERF}{TOTAL} );
    $Plan->setAttribute( 'total_time', $struct->{$md5}{EXP_PERF}{TOTAL_TIME} );


foreach my $key (%interested) {
if(defined $struct->{$md5}{EXP_PERF}{$key}) {
#$Plan->setAttribute( "min_".$interested{$key}, $struct->{$md5}{EXP_PERF}{$key}{MIN} );
#$Plan->setAttribute( "max_".$interested{$key}, $struct->{$md5}{EXP_PERF}{$key}{MAX} );
#$Plan->setAttribute( "avg_".$interested{$key}, $struct->{$md5}{EXP_PERF}{$key}{AVG} );
$Plan->setAttribute( "avg_".$interested{$key}, $struct->{$md5}{EXP_PERF}{$key}{AVG} );
}
}

    $PlanText->appendText($exp);
    $Plan->appendChild($PlanText);
    return $Plan;
}

sub handle_session {
    my ( $session, $doc, $ele, $id, $md5 ) = @_;

    my $Session = $doc->createElement('Execution');
    $Session->setAttribute( 'sid',          $id );
    $Session->setAttribute( 'cost',         $session->{COST} );
    $Session->setAttribute( 'time',         $session->{SAMPLE_TIME} );
    $Session->setAttribute( 'user_id',      $session->{USER_ID} );
    $Session->setAttribute( 'total',      $session->{TOTAL} );
    $Session->setAttribute( 'execute_time', $session->{TIME} );
    $Session->setAttribute( 'plan_md5',     $md5 );
    return $Session;

}

sub output_xml {
    my ( $cfg, $doc, $log, $dtd ) = @_;
    my ( $timestamp, $filename, $outdir, $acronym );

    $timestamp =
        ( 1900 + (localtime)[5] ) . "-"
      . sprintf( "%2.2d", ( 1 + (localtime)[4] ) ) . "-"
      . sprintf( "%2.2d", (localtime)[3] );
    $timestamp .= " "
      . sprintf( "%2.2d", (localtime)[2] ) . ":"
      . sprintf( "%2.2d", (localtime)[1] ) . ":"
      . sprintf( "%2.2d", (localtime)[0] );
    $timestamp =~ s/\W//g;

    if ( defined $cfg->{INDIR} && defined $cfg->{ERRDIR} ) {
        if ( validate_xml( $log, $doc, $dtd ) ) {
            $filename = "$cfg->{INDIR}/sqltracer_${timestamp}.xml";
            open( FILE, "> $filename" ) || die $!;    # or do something
            print FILE $doc->toString(1);
            close(FILE);
            $log->info(
                "generated xml $cfg->{INDIR}/sqltracer_${timestamp}.xml");
        }
        else {
            $filename = "$cfg->{ERRDIR}/sqltracer_${timestamp}.xml";
            open( FILE, "> $filename" ) || die $!;    # or do something
            print FILE $doc->toString(1);
            close(FILE);
            $log->info(
"validation errors generating in  $cfg->{ERRDIR}/sqltracer_${timestamp}.xml"
            );
        }

    }

}

sub get_epoch {
    my ( $time, $times ) = @_;

    #
    # get todays time
    #
    #
    my ( $sec, $min, $hour, $mday, $mon, $year ) = localtime(time);
    $year += 1900;

    #
    # get the time for now
    #
    #
    my ( $h, $m, $s ) = split( ':', $time );

    #
    # use the new time and date to generate an ephoch
    # to use for a comparison
    #

    my $time_epoch = timelocal( $s, $m, $h, $mday, $mon, $year );

    #
    # store the max and min for output and for filtering
    #

    if ( !defined $times->{MAX} || $times->{MAX} < $time_epoch ) {
        $times->{MAX} = $time_epoch;
        $times->{MAX_READ} =
          strftime( "%Y-%m-%d %H:%M:%S", localtime($time_epoch) );
    }
    if ( !defined $times->{MIN} || $times->{MIN} > $time_epoch ) {
        $times->{MIN} = $time_epoch;
        $times->{MIN_READ} =
          strftime( "%Y-%m-%d %H:%M:%S", localtime($time_epoch) );
    }
    return strftime( "%Y-%m-%d %H:%M:%S", localtime($time_epoch) );
}

sub handle_min_max_avg {
my ($value,$struct,$key)=@_;
   if ( !defined $struct->{$key}{MIN}
                    || $struct->{$key}{MIN} >
                    $value )
                {
                    $struct->{$key}{MIN} = $value;
                }
                if ( !defined $struct->{$key}{MAX}
                    || $struct->{$key}{MAX} <
                    $value )
                {
                    $struct->{$key}{MAX} = $value;
                }
                $struct->{$key}{COUNT}++;
                $struct->{$key}{TOTAL}+=$value;
                $struct->{$key}{AVG}=sprintf("%.02f",$struct->{$key}{TOTAL}/$struct->{$key}{COUNT});

}
