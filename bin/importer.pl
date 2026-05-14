#!/usr/bin/perl -w
# Copyright, Designs and Patents Act 1988 or under the terms of a
# Licence entered into with the copyright owner.
#
# Warning: the doing of an unauthorised act in relation to a copyright
# work may result in both a civil claim for damages and a criminal
# prosecution.
#
use XML::LibXML;
use Data::Dumper;
use FindBin;
use lib "$FindBin::Bin/../lib";
use DB::Query;
use DB::LoadSQL;
use File::Copy;
use Log::Writer;
use strict;
use vars
  qw($parser $doc $root $top %elements $docroot @queries $dbh %root_attributes $sample_id %queries %explains %query_plans %operations %cfg);

#
# load db object
#

my ( $user, $password, $server, $database ) =
  ( '', '', 'offshore_pte_top', 'sql_hist' );
my $db = DB::Query->new( $user, $password, $database, $server );

$cfg{INFOLOG}  = '../logs/importer.log';
$cfg{LOGLEVEL} = 'info';
$cfg{MAILFROM} = 'importer@ld6ux741.com';
$cfg{MAILRECP} = 'andrew.curry@uk.clara.net';

my $log_info = Log::Writer->new(
    filename     => "$cfg{INFOLOG}",
    mode         => 'append',
    timeformat   => '%Y-%m-%d %H:%M:%S',
    maxlevel     => $cfg{LOGLEVEL},
    emailsender  => $cfg{MAILFROM},
    emailreciept => $cfg{MAILRECP},
    emailerrors  => 0,
    newline      => 1,
    prefix       => '',
);

#
# prepare statements
#

prepare_statements($db);

#
# load libxml object
#

$parser = XML::LibXML->new();

#
# pre load all queries and plans to speed up imports
#

load_data( $db, \%queries, \%explains, \%query_plans );

#
# crude xml file load, to be replaced with while loop etc..
#
#

while (1) {

    my @files = poll_in_directory('/var/crash/INST1/sqltrace/xml_in/');

    foreach my $file (@files) {

        undef %operations;

        $operations{ERRORS} = 0;

        undef @queries;
        $log_info->info("Processing $file");

        eval {
            $doc =
              $parser->parse_file("/var/crash/INST1/sqltrace/xml_in/$file");

        };
        if ($@) {
            $log_info->error(
"Parser Error $@ moving /var/crash/INST1/sqltrace/xml_in/$file to /var/crash/INST1/sqltrace/xml_err/$file"
            );
            move(
                "/var/crash/INST1/sqltrace/xml_in/$file",
                "/var/crash/INST1/sqltrace/xml_err/$file"
            );
            next;
        }

        # get root element
        #

        $root = ( $doc->findnodes('//*') )[0];

#
# on start up make sure the first time its run you get all queries and explains loaded for speed.
#

        if ( defined $root ) {

            for my $root_att ( $root->attributes ) {
                if (   $root_att->getValue =~ /\d+\.\d+/
                    && $root_att->getValue !~ /[A-Za-z]/ )
                {
                    $root_attributes{ $root_att->getName } =
                      sprintf( "%f", $root_att->getValue );
                }
                else {
                    $root_attributes{ $root_att->getName } =
                      $root_att->getValue;
                }
            }

            #
            # process xml data
            #

            process_queries( $root, $docroot, \@queries, \%operations,
                $log_info );

            #
            # import the xml
            #
            #

            if ( !defined $root_attributes{version} ) {
                $root_attributes{version} = $queries{VERSION};
            }

            $sample_id = get_sample_id( $db, \%root_attributes );

            #
            # get query data and insert/update it
            #
            #

            insert_data( $db, $queries{QUERY}, $explains{EXPLAIN},
                $query_plans{PLANS}, \@queries, $sample_id, \%operations,
                $log_info );

            $log_info->info(
"Processed $file: $operations{FOUND_COUNT} Query nodes to process, $operations{EXPLAINPLAN} unique query and execution plans, ",
                $operations{FOUND_COUNT} - $operations{NOT_ARC_COUNT},
                " skipped as archiving plans,$operations{ERRORS} errors\n"
            );
        }
        else {
            $log_info->error(
                "Problem processing $file, not doc root, moving to error");
            move(
                "/var/crash/INST1/sqltrace/xml_in/$file",
                "/var/crash/INST1/sqltrace/xml_err/$file"
            );
        }
        if ( defined $operations{ERRORS} && $operations{ERRORS} > 0 ) {
            $log_info->error(
                "Error processing $file, moving to error (sample_id $sample_id)"
            );
            move(
                "/var/crash/INST1/sqltrace/xml_in/$file",
                "/var/crash/INST1/sqltrace/xml_err/$file"
            );

        }
        else {
            $log_info->info(
                "processed $file, moving to out (sample_id $sample_id)");
            move(
                "/var/crash/INST1/sqltrace/xml_in/$file",
                "/var/crash/INST1/sqltrace/xml_out/$file"
            );
        }

    }
    sleep 60;
}

$db->closeConnection();

sub get_sample_id {
    my ( $dbh, $attr ) = @_;

    my ( $sample_id, $dbs_select, $dbs_insert, $db_ref );

    $dbs_select = $dbh->getHandle('GetSampleId');
    $dbs_select->execute( $attr->{min_sample_time}, $attr->{max_sample_time} )
      || ( dberr( __FILE__, __LINE__, $DBI::errstr ) );

    $db_ref = $dbs_select->fetchall_arrayref();

    $sample_id = $db_ref->[0][0];

    if ( !defined $sample_id ) {
        $dbs_insert = $dbh->getHandle('InsSample');
        $dbs_insert->execute(
            $attr->{min_sample_time},
            $attr->{max_sample_time},
            $attr->{version}
        ) || ( dberr( __FILE__, __LINE__, $DBI::errstr ) );

        $sample_id = ( $dbs_insert->{ix_sqlerrd}[1] );

    }

    return $sample_id;
}

sub process_queries {
    my ( $node, $xdoc, $queries, $operations, $log_info ) = @_;
    my ( $name, $count );
    foreach my $queries_root ( $node->getElementsByTagName('Query') ) {
        $operations->{QUERY}++;
        $count++;
        $name = $queries_root->nodeName();
        process_query( $queries_root, $docroot, $queries, $operations,
            $log_info );
    }
}

sub process_query {
    my ( $node, $xdoc, $queries, $operations, $log_info ) = @_;
    my ( $name, $query_attributes, $exe_attributes, %total_temp );

    #
    # get attributes
    #

    for my $query_att ( $node->attributes ) {
        if ( $query_att->getValue =~ /\d+\.\d+/ ) {
            $query_attributes->{ $query_att->getName } =
              sprintf( "%f", $query_att->getValue );
        }
        else {
            $query_attributes->{ $query_att->getName } = $query_att->getValue;
        }
    }

    #
    # handle the query
    # get the id for the query
    #

    foreach my $query ( $node->getElementsByTagName('QueryText') ) {
        $name = $query->nodeName;
        $query_attributes->{'query_text'} = $query->textContent;
    }

    $operations->{FOUND_COUNT}++;
    return if ( $query_attributes->{'query_text'} =~ /tmparc/ );
    $operations->{NOT_ARC_COUNT}++;

#
# older xml versions didnt have the total execution time for a query plan easily accessable.. this is a hack to be removed after import of initial data
#

    if ( !defined $node->findvalue('./ExplainPlans/ExplainPlan/@total_time')
        || $node->findvalue('./ExplainPlans/ExplainPlan/@total_time') !~ /\S+/ )
    {
        foreach my $execution ( $node->findnodes('./Executions/Execution') ) {
            if (   defined $execution->findvalue('./@md5')
                && defined $execution->findvalue('./@execute_time') )
            {
                $total_temp{ $execution->findvalue('./@plan_md5') } +=
                  $execution->findvalue('./@execute_time');
            }
        }
    }

    #
    # we have the query id for the plan, now we need to get the explains
    #

    foreach my $plan ( $node->getElementsByTagName('ExplainPlans') ) {
        foreach my $query ( $plan->getElementsByTagName('ExplainPlan') ) {
            $operations->{EXPLAINPLAN}++;
            $name = $query->nodeName();

            for my $query_att ( $query->attributes ) {
                if ( $query_att->getValue =~ /\d+\.\d+/ ) {
                    $exe_attributes->{ $query_att->getName } =
                      sprintf( "%f", $query_att->getValue );
                }
                else {
                    $exe_attributes->{ $query_att->getName } =
                      $query_att->getValue;
                }
            }

            if ( !defined $exe_attributes->{total_time} ) {
                $exe_attributes->{'total_time'} =
                  $total_temp{ $exe_attributes->{md5} };
            }
            foreach my $querytext ( $query->getElementsByTagName('PlanText') ) {
                $operations->{QUERYPLANS}++;
                $name = $querytext->nodeName();
                $exe_attributes->{'explain_text'} = $querytext->textContent;
            }
            push( @{ $query_attributes->{'explains'} },
                { %{$exe_attributes} } );

        }
    }

    push( @{$queries}, $query_attributes );
}

sub load_data {
    my ( $dbh, $queries, $explains, $query_plan ) = @_;
    my ( $sel_version, $sel_queries, $sel_explains, $sel_query_plan, $db_ref );

    $sel_queries = $dbh->getHandle('SelQuery');
    $sel_queries->execute() || ( dberr( __FILE__, __LINE__, $DBI::errstr ) );

    $db_ref = $sel_queries->fetchall_hashref( ['md5'] );
    $queries->{QUERY} = \%{$db_ref};

    $sel_explains = $dbh->getHandle('SelExplain');
    $sel_explains->execute() || ( dberr( __FILE__, __LINE__, $DBI::errstr ) );

    $db_ref = $sel_explains->fetchall_hashref( ['md5'] );
    $explains->{EXPLAIN} = \%{$db_ref};

    $sel_query_plan = $dbh->getHandle('GetQueryExplainHist');
    $sel_query_plan->execute()
      || ( dberr( __FILE__, __LINE__, $DBI::errstr ) );

    $db_ref = $sel_query_plan->fetchall_hashref( [ 'query_id', 'explain_id' ] );
    $query_plan->{PLANS} = \%{$db_ref};

    $sel_version = $dbh->getHandle('GetDBVersion');
    $sel_version->execute() || ( dberr( __FILE__, __LINE__, $DBI::errstr ) );

    $db_ref = $sel_version->fetchall_arrayref();
    $queries->{VERSION} = $db_ref->[0][0];

}

sub insert_data {

    my ( $dbh, $queries, $explains, $query_plans, $data, $sample_id,
        $operations, $log_info )
      = @_;
    my ( $query_id, $dbs_insert, $explain_id );


    foreach my $query ( @{$data} ) {

        if ( !defined $queries->{ $query->{md5} }{query_id} ) {

            #
            # we are new so need to insert
            #

            $dbs_insert = $dbh->getHandle('InsQuery');
            $dbs_insert->execute( $query->{query_text}, $query->{md5},
                $query->{sql_type} )
              || (
                dberr( __FILE__, __LINE__, $DBI::errstr, $operations,
                    $log_info
                )
              );
            $query_id = ( $dbs_insert->{ix_sqlerrd}[1] );
            $queries->{ $query->{md5} }{query_id} = $query_id;
            $operations->{QUERY_INS}++;

        }
        else {

            $operations->{QUERY_KNOWN}++;
            $query_id = $queries->{ $query->{md5} }{query_id};

        }

        foreach my $explain ( @{ $query->{explains} } ) {

            if ( !defined $explains->{ $explain->{md5} }{explain_id} ) {

                $operations->{EXPLAIN_INS}++;

                #
                # we are new so need to insert
                #

                $dbs_insert = $dbh->getHandle('InsExplain');
                $dbs_insert->execute( $explain->{explain_text},
                    $explain->{md5} )
                  || (
                    dberr( __FILE__, __LINE__, $DBI::errstr, $operations,
                        $log_info
                    )
                  );
                $explain_id = ( $dbs_insert->{ix_sqlerrd}[1] );
                $explains->{ $explain->{md5} }{explain_id} = $explain_id;

            }
            else {

                $operations->{EXPLAIN_KNOWN}++;
                $explain_id = $explains->{ $explain->{md5} }{explain_id};

            }

            #
            # check and add if the plan is new for that query
            #
            #

            if ( !defined $query_plans->{$query_id}{$explain_id} ) {

                $dbs_insert = $dbh->getHandle('InsQueryExplainHist');
                $dbs_insert->execute( $query_id, $explain_id, $sample_id )
                  || (
                    dberr( __FILE__, __LINE__, $DBI::errstr, $operations,
                        $log_info
                    )
                  );
                $query_plans->{$query_id}{$explain_id} = 1;

            }

            $dbs_insert = $dbh->getHandle('InsQueryExplain');
            $dbs_insert->execute(
                $sample_id,
                $query_id,
                $explain_id,
               sprintf("%.2f",$explain->{total_executions}),
                sprintf("%.2f",$explain->{total_time}),
                sprintf("%.3f",$explain->{min_execution_time}),
                sprintf("%.3f",$explain->{max_execution_time}),
                sprintf("%.2f",$explain->{avg_memory_sorts}),
                sprintf("%.2f",$explain->{avg_log_space}),
                sprintf("%.2f",$explain->{avg_average_rows_per_second}),
                sprintf("%.2f",$explain->{avg_read_percent_cache}),
                sprintf("%.2f",$explain->{avg_buffer_write}),
                sprintf("%.2f",$explain->{avg_lock_wait}),
                sprintf("%.2f",$explain->{avg_number_of_sorts}),
                sprintf("%.2f",$explain->{avg_buffer_index_read}),
                sprintf("%.2f",$explain->{avg_sql_memory}),
                sprintf("%.2f",$explain->{avg_average_io_wait}),
                sprintf("%.2f",$explain->{avg_write_percent_cache}),
                sprintf("%.2f",$explain->{avg_buffer_reads}),
                sprintf("%.2f",$explain->{avg_cost}),
                sprintf("%.2f",$explain->{avg_lock_request}),
                sprintf("%.3f",$explain->{avg_lock_wait_time}),
                sprintf("%.3f",$explain->{avg_page_write}),
                sprintf("%.3f",$explain->{avg_disk_sorts}),
                sprintf("%.3f",$explain->{avg_page_reads})
            ); 
            if (   defined $dbs_insert->{ix_sqlcode}
                && $dbs_insert->{ix_sqlcode} != 0
                && $dbs_insert->{ix_sqlcode} != '-239' )
            {
                dberr( __FILE__, __LINE__, $DBI::errstr, $operations,
                    $log_info
                );
            }
            elsif ( defined $dbs_insert->{ix_sqlcode}
                && $dbs_insert->{ix_sqlcode} == '-239' )
            {

                #
                # row alread exists so for now dont handle anything and continue
                # not great code but most efficient
                #

                $operations->{DUPLICATE_QE}++;
            }
        }

    }

}

sub poll_in_directory {
    my ($spooldir) = @_;
    my ( @dir, @files, %hash );
    my ( $file, $fullpath, $now, $mod_time, $sort_name );

    #
    # empty list of files to go
    #
    undef @files;
    undef %hash;

    #
    # try and open the spool directory
    #
    if ( opendir( DIR, $spooldir ) ) {

        #
        # read all the files in
        # but ignore the obvious
        #
        @dir = grep( /xml/, readdir(DIR) );
        closedir(DIR);

        #
        # now see how many of these files are safe to send
        # by checking the modification times against
        # the current time
        #
        $now = time();

        foreach $file (@dir) {

            if ( $file =~ /sqltracer_(\d+).xml/ ) {

                $sort_name = $1;

                #
                # need full path for stat
                #
                $fullpath = $spooldir . '/' . $file;

                #
                # stat file to make sure it exists
                # (and get the modification time)
                #
                next unless ( $mod_time = ( stat($fullpath) )[9] );

                #
                # check modification time of file
                # if this is too recent then the
                # file MIGHT still be being written to
                #
                if ( $mod_time < ( $now - 2 ) ) {

                    #
                    # safe to send this one
                    # so add it to the list
                    #
                    push( @files, $file );

                    $hash{$file} = $sort_name;
                }
            }

        }

        #
        # Make sure files are ordered by file timestamp
        # readdir will be close but not guaranteed
        #

        return sort { $hash{$a} <=> $hash{$b} } @files;
    }
    else {
        die $!;
    }
}

sub dberr {
    my ( $t1, $t2, $t3, $operations, $log ) = @_;

    #
    # print out database error and die
    #
    my $error = "Error in $t1, line $t2: $t3";
    $log->info($error);
    $operations->{ERRORS}++;
print STDERR $error;
    exit;
}

