database sysmaster;
drop database sql_hist;
create database sql_hist in appdbs01 with log;
grant dba to "informix";


{ TABLE "informix".sample_run row size = 39 number of columns = 5 index size = 30 }

create table "informix".sample_run 
  (
    sample_id serial not null ,
    curtime datetime year to second,
    starttime datetime year to second,
    endtime datetime year to second,
    version varchar(10)
  ) extent size 4096 next size 4096 lock mode row;

revoke all on "informix".sample_run from "public" as "informix";

{ TABLE "informix".sql_explain row size = 2096 number of columns = 4 index size = 89 }

create table "informix".sql_explain 
  (
    explain_id serial not null ,
    explain_text lvarchar,
    timestamp datetime year to second,
    md5 varchar(32)
  ) extent size 16 next size 16 lock mode row;

revoke all on "informix".sql_explain from "public" as "informix";

{ TABLE "informix".sql_query row size = 2099 number of columns = 5 index size = 97 }

create table "informix".sql_query 
  (
    query_id serial not null ,
    query_text lvarchar,
    timestamp datetime year to second,
    md5 varchar(32),
    sql_type char(3)
  ) extent size 16 next size 16 lock mode row;

revoke all on "informix".sql_query from "public" as "informix";

{ TABLE "informix".query_sample row size = 45 number of columns = 8 index size = 48 }

create table "informix".query_sample 
  (
    sample_id serial not null ,
    query_id integer,
    explain_id integer,
    total_executions integer,
    max_execution_time decimal(4),
    min_execution_time decimal(4),
    total_time decimal(4),
avg_mem_sorts decimal(4),
avg_log_space decimal(4),
avg_rows_per_sec decimal(4),
avg_rd_cache decimal(4),
avg_buff_wrt decimal(4),
avg_lock_wait decimal(4),
avg_num_sorts decimal(4),
avg_buff_idx_rd decimal(4),
avg_sql_memory decimal(4),
avg_io_wait decimal(4),
avg_wrt_cache decimal(4),
avg_buff_rds decimal(4),
avg_cost decimal(4),
avg_lock_req decimal(4),
avg_lkwait_time decimal(4),
avg_page_wrt decimal(4),
avg_disk_sort decimal(4),
avg_page_rd decimal(4),
    timestamp datetime year to second
  ) extent size 16 next size 16 lock mode row;

revoke all on "informix".query_sample from "public" as "informix";

{ TABLE "informix".query_plan_hist row size = 20 number of columns = 4 index size = 44 }

create table "informix".query_plan_hist 
  (
    query_id integer,
    explain_id integer,
    first_sampled integer,
    timestamp datetime year to second
  ) extent size 16 next size 16 lock mode row;

revoke all on "informix".query_plan_hist from "public" as "informix";


grant select on "informix".sql_explain to "public" as "informix";
grant update on "informix".sql_explain to "public" as "informix";
grant insert on "informix".sql_explain to "public" as "informix";
grant delete on "informix".sql_explain to "public" as "informix";
grant index on "informix".sql_explain to "public" as "informix";
grant select on "informix".sql_query to "public" as "informix";
grant update on "informix".sql_query to "public" as "informix";
grant insert on "informix".sql_query to "public" as "informix";
grant delete on "informix".sql_query to "public" as "informix";
grant index on "informix".sql_query to "public" as "informix";
grant select on "informix".query_sample to "public" as "informix";
grant update on "informix".query_sample to "public" as "informix";
grant insert on "informix".query_sample to "public" as "informix";
grant delete on "informix".query_sample to "public" as "informix";
grant index on "informix".query_sample to "public" as "informix";
grant select on "informix".query_plan_hist to "public" as "informix";
grant update on "informix".query_plan_hist to "public" as "informix";
grant insert on "informix".query_plan_hist to "public" as "informix";
grant delete on "informix".query_plan_hist to "public" as "informix";
grant index on "informix".query_plan_hist to "public" as "informix";

revoke usage on language SPL from public ;

grant usage on language SPL to public ;


create index "informix".query_sample_ix1 on "informix".sample_run 
    (starttime,endtime) using btree  in appdbs01;
create unique index "informix".query_sample_ix_1 on "informix"
    .sample_run (sample_id) using btree  in appdbs01;
alter table "informix".sample_run add constraint primary key 
    (sample_id) constraint "informix".query_sample_pk  ;
create unique index "informix".sql_explain_ix1 on "informix".sql_explain 
    (explain_id,md5) using btree  in appdbs01;
create unique index "informix".sql_explain_ix2 on "informix".sql_explain 
    (md5) using btree  in appdbs01;
create unique index "informix".sql_explain_ix4 on "informix".sql_explain 
    (explain_id) using btree  in appdbs01;
create unique index "informix".sql_query_ix1 on "informix".sql_query 
    (query_id,md5) using btree  in appdbs01;
create unique index "informix".sql_query_ix2 on "informix".sql_query 
    (md5) using btree  in appdbs01;
create index "informix".sql_query_ix3 on "informix".sql_query 
    (sql_type) using btree  in appdbs01;
create unique index "informix".sql_query_ix4 on "informix".sql_query 
    (query_id) using btree  in appdbs01;
create unique index "informix".query_plan_sample_ix1 on "informix"
    .query_sample (sample_id,query_id,explain_id) using btree 
     in appdbs01;
create index "informix".query_plan_sample_ix2 on "informix".query_sample 
    (query_id,explain_id) using btree  in appdbs01;
create index "informix".query_plan_sample_ix3 on "informix".query_sample 
    (query_id) using btree  in appdbs01;
create index "informix".query_plan_sample_ix4 on "informix".query_sample 
    (explain_id) using btree  in appdbs01;
create unique index "informix".query_plan_hist_ix1 on "informix"
    .query_plan_hist (query_id,explain_id,first_sampled) using 
    btree  in appdbs01;
create index "informix".query_plan_hist_ix2 on "informix".query_plan_hist 
    (query_id) using btree  in appdbs01;
create index "informix".query_plan_hist_ix3 on "informix".query_plan_hist 
    (explain_id) using btree  in appdbs01;
create index "informix".query_plan_hist_ix4 on "informix".query_plan_hist 
    (first_sampled) using btree  in appdbs01;


