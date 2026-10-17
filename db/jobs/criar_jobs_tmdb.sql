-- MMM_JOB_TMDB_NOITE e MMM_JOB_CATALOGO_MES. Sem o da noite, o titulo em lista fica sem renovar e sai aos 175 dias
-- (prazo do TMDB), e o onde assistir fica parado no dia em que entrou; sem o do mes, generos e provedores saem aos
-- 175 dias e levam o mapeamento clima-genero junto. Horarios em UTC, o fuso da ATP: 07:30 (04:30 em Brasilia, meia
-- hora depois do diario) e dia 1 as 06:00 (03:00). O job roda com o usuario de quem o cria, e o VPD e a guarda dos
-- jobs o reconhecem pelo BG_JOB_ID. Apaga e recria: pode rodar de novo.
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
    recriar('MMM_JOB_TMDB_NOITE',
            'begin MMM_PKG_TMDB.job_noite; end;',
            'FREQ=DAILY;BYHOUR=7;BYMINUTE=30;BYSECOND=0',
            'Detalhes do TMDB aos 30 dias e onde assistir das listas ativas');
    recriar('MMM_JOB_CATALOGO_MES',
            'begin MMM_PKG_TMDB.job_catalogo_mensal; end;',
            'FREQ=MONTHLY;BYMONTHDAY=1;BYHOUR=6;BYMINUTE=0;BYSECOND=0',
            'Generos e provedores BR do TMDB e mapeamento das familias de servico');
end;
/

column job_name format a22
column job_creator format a12
column repeat_interval format a56
column proxima format a17
select job_name,
       job_creator,
       enabled,
       state,
       repeat_interval,
       to_char(next_run_date at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI') as proxima
  from dba_scheduler_jobs
 where owner = 'MMM'
   and job_name like 'MMM_JOB%'
 order by job_name;

exit
