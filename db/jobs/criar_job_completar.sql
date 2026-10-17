-- MMM_JOB_COMPLETAR: completa a cada 10 minutos os titulos PENDENTE, os que entram pela nota colada, e o AJAX o
-- acorda na hora com RUN_JOB. O job roda com o usuario de quem o cria, e o VPD e a guarda dos jobs o reconhecem pelo
-- BG_JOB_ID. Apaga e recria: pode rodar de novo.
set serveroutput on size unlimited
set feedback off
set linesize 200
whenever sqlerror exit failure rollback

declare
    l_qtd number;
begin
    select count(*)
      into l_qtd
      from dba_scheduler_jobs
     where owner    = 'MMM'
       and job_name = 'MMM_JOB_COMPLETAR';
    if l_qtd > 0 then
        dbms_scheduler.drop_job(job_name => 'MMM.MMM_JOB_COMPLETAR', force => true);
    end if;

    dbms_scheduler.create_job(
        job_name        => 'MMM.MMM_JOB_COMPLETAR',
        job_type        => 'PLSQL_BLOCK',
        job_action      => 'begin MMM_PKG_TMDB.job_completar_pendentes; end;',
        start_date      => systimestamp,
        repeat_interval => 'FREQ=MINUTELY;INTERVAL=10',
        enabled         => true,
        auto_drop       => false,
        comments        => 'Completa titulos pendentes (nota colada); acordado pelo AJAX com RUN_JOB');
end;
/

column job_name format a20
column job_creator format a12
column proxima format a17
select job_name,
       job_creator,
       enabled,
       state,
       repeat_interval,
       to_char(next_run_date at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI') as proxima
  from dba_scheduler_jobs
 where owner    = 'MMM'
   and job_name = 'MMM_JOB_COMPLETAR';

exit
