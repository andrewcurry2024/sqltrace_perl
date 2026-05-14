package DB::LoadSQL;

use strict;
use warnings;
use DBI;

use vars qw($VERSION @ISA @EXPORT);

require Exporter;
@ISA = qw(Exporter);

our $VERSION = '0.01';
@EXPORT = qw(prepare_statements);

sub prepare_statements {
my($dbh,$log)=@_;

#sample_id            serial                                  no
#curtime              datetime year to second                 yes
#starttime            datetime year to second                 yes
#endtime              datetime year to second                 yes

$dbh->setHandle( "select sample_id from sample_run where starttime=? and endtime=?",
    'GetSampleId' );

$dbh->setHandle( "SELECT DBINFO('version', 'major')|| '.' || DBINFO('version', 'minor')||'.'||DBINFO('version', 'os')||DBINFO('version', 'level')
   FROM systables
   WHERE tabid = 1;",
    'GetDBVersion' );

$dbh->setHandle( "select query_id,explain_id from query_plan_hist",
    'GetQueryExplainHist' );

$dbh->setHandle( "insert into query_plan_hist (query_id,explain_id,first_sampled,timestamp) values(?,?,?,CURRENT);",
    'InsQueryExplainHist' );

$dbh->setHandle( "insert into sample_run (sample_id,curtime,starttime,endtime,version) values(0,CURRENT,?,?,?); ",
    'InsSample' );

$dbh->setHandle( "insert into sql_query (query_id,query_text,md5,timestamp,sql_type) values(0,?,?,CURRENT,?); ",
    'InsQuery' );
$dbh->setHandle( "insert into sql_explain (explain_id,explain_text,md5,timestamp) values(0,?,?,CURRENT); ",
    'InsExplain' );
$dbh->setHandle( "insert into query_sample (sample_id,query_id,explain_id,total_executions,total_time,min_execution_time,max_execution_time,avg_mem_sorts,avg_log_space,avg_rows_per_sec,avg_rd_cache,avg_buff_wrt,avg_lock_wait,avg_num_sorts,avg_buff_idx_rd,avg_sql_memory,avg_io_wait,avg_wrt_cache,avg_buff_rds,avg_cost,avg_lock_req,avg_lkwait_time,avg_page_wrt,avg_disk_sort,avg_page_rd,timestamp) values(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,CURRENT); ",
    'InsQueryExplain' );
$dbh->setHandle( "select TRIM(md5) as md5, query_id  from sql_query",
    'SelQuery' );

$dbh->setHandle( "select TRIM(md5) as md5, explain_id from sql_explain;",
    'SelExplain' );
}

1;

