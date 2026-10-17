-- MMM_JOB_HORARIO e MMM_JOB_DIARIO: sem eles nao valem o Excluir minha conta (dados somem em ate uma hora), a demo
-- apagada em 24 horas nem os prazos da Privacidade. Horarios em UTC, o fuso da ATP: :15 de toda hora e 07:00 (04:00
-- em Brasilia). O job roda com o usuario de quem o cria, e o VPD e a guarda dos jobs o reconhecem pelo BG_JOB_ID.
-- Apaga e recria: pode rodar de novo.
set serveroutput on size unlimited
set feedback off
set linesize 200
whenever sqlerror exit failure rollback

declare
    procedure recriar(p_nome in varchar2, p_acao in varchar2, p_intervalo in varchar2, p_comentario in varchar2) is
        l_qtd number;
    begin
        select count(*)
          into l_qtd
          from dba_scheduler_jobs
         where owner    = 'MMM'
           and job_name = p_nome;
        if l_qtd > 0 then
            dbms_scheduler.drop_job(job_name => 'MMM.' || p_nome, force => true);
        end if;

        dbms_scheduler.create_job(
            job_name        => 'MMM.' || p_nome,
            job_type        => 'PLSQL_BLOCK',
            job_action      => p_acao,
            start_date      => systimestamp,
            repeat_interval => p_intervalo,
            enabled         => true,
            auto_drop       => false,
            comments        => p_comentario);
    end recriar;
begin
    recriar('MMM_JOB_HORARIO',
            'begin MMM_PKG_RETENCAO.executar_horario; end;',
            'FREQ=HOURLY;BYMINUTE=15;BYSECOND=0',
            'Visitas da demo vencidas, sessoes paradas ha 3 h e contas a apagar ou anonimizar');
    recriar('MMM_JOB_DIARIO',
            'begin MMM_PKG_RETENCAO.executar_diario; end;',
            'FREQ=DAILY;BYHOUR=7;BYMINUTE=0;BYSECOND=0',
            'Itens tirados, sessoes sem filme, links vencidos, prazo do TMDB, log e alerta de renovacao');
end;
/

column job_name format a20
column job_creator format a12
column repeat_interval format a42
column proxima format a17
select job_name,
       job_creator,
       enabled,
       state,
       repeat_interval,
       to_char(next_run_date at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI') as proxima
  from dba_scheduler_jobs
 where owner = 'MMM'
   and job_name in ('MMM_JOB_HORARIO', 'MMM_JOB_DIARIO', 'MMM_JOB_COMPLETAR')
 order by job_name;

exit
