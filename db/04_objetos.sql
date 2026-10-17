declare
    l_ddl varchar2(4000);
begin
    -- quem alterou e o ID_USUARIO (tenant), nao o e-mail: a auditoria nao guarda dado pessoal.
    -- Fora do APEX, e antes do tenant na Post-Authentication, fica o usuario do banco.
    -- Pelo schema corrente, e nao por user_*: na ATP quem instala e o ADMIN com current_schema = MMM
    for t in (select c.TABLE_NAME
                from all_tab_columns c
                join all_tables u
                  on u.OWNER      = c.OWNER
                 and u.TABLE_NAME = c.TABLE_NAME
               where c.OWNER = sys_context('USERENV', 'CURRENT_SCHEMA')
                 and c.COLUMN_NAME = 'ALTERADO_EM'
                 and c.TABLE_NAME like 'MMM\_%' escape '\'
               order by c.TABLE_NAME) loop
        l_ddl := replace(q'~create or replace trigger #T#_BU_TRG
before update on #T#
for each row
begin
    :new.ALTERADO_POR := nvl(sys_context('APEX$SESSION', 'APP_TENANT_ID'), user);
    :new.ALTERADO_EM  := systimestamp;
end;~', '#T#', t.TABLE_NAME);
        execute immediate l_ddl;
    end loop;

    -- tela e AJAX nao mandam o grupo: vale o ativo de quem esta logado.
    -- Em job sem sessao APEX o grupo ativo e nulo e o insert sem ID_GRUPO falha (ORA-01400), que e o certo.
    for t in (select c.TABLE_NAME
                from all_tab_columns c
                join all_tables u
                  on u.OWNER      = c.OWNER
                 and u.TABLE_NAME = c.TABLE_NAME
               where c.OWNER = sys_context('USERENV', 'CURRENT_SCHEMA')
                 and c.COLUMN_NAME = 'ID_GRUPO'
                 and c.TABLE_NAME like 'MMM\_%' escape '\'
                 and c.TABLE_NAME not in ('MMM_GRUPO', 'MMM_MEMBRO', 'MMM_GRUPO_ATIVO')
               order by c.TABLE_NAME) loop
        l_ddl := replace(q'~create or replace trigger #T#_BI_TRG
before insert on #T#
for each row
begin
    if :new.ID_GRUPO is null then
        :new.ID_GRUPO := MMM_PKG_SEGURANCA.id_grupo_ativo;
    end if;
end;~', '#T#', t.TABLE_NAME);
        execute immediate l_ddl;
    end loop;
end;
/

create or replace trigger MMM_MEMBRO_SAIU_TRG
after update of SITUACAO on MMM_MEMBRO
for each row
when (new.SITUACAO = 'SAIU' and old.SITUACAO = 'ATIVO')
begin
    -- quem saiu (ou foi tirado pelo dono) perde o grupo como ativo na hora;
    -- senao continuaria vendo a lista de membros pela politica de MMM_MEMBRO
    delete from MMM_GRUPO_ATIVO
     where ID_USUARIO = :new.ID_USUARIO
       and ID_GRUPO   = :new.ID_GRUPO;
end;
/

create or replace view MMM_V_MEUS_GRUPOS as
select g.ID_GRUPO,
       g.NOME,
       g.FL_DEMO,
       m.ID_MEMBRO,
       m.PAPEL,
       m.APELIDO,
       m.COR,
       case when ga.ID_GRUPO is not null then 'S' else 'N' end as FL_ATIVO
  from MMM_MEMBRO m
  join MMM_GRUPO g
    on g.ID_GRUPO = m.ID_GRUPO
  left join MMM_GRUPO_ATIVO ga
    on ga.ID_USUARIO = m.ID_USUARIO
   and ga.ID_GRUPO   = m.ID_GRUPO
 where m.ID_USUARIO = to_number(sys_context('APEX$SESSION', 'APP_TENANT_ID'))
   and m.SITUACAO   = 'ATIVO';

comment on table MMM_V_MEUS_GRUPOS is 'Seletor de grupo: os grupos da pessoa logada, com o ativo marcado.';

create or replace view MMM_V_LISTA_ATIVA as
select li.ID_LISTA_ITEM,
       li.ID_GRUPO,
       li.ID_TITULO,
       li.PIPOCAS,
       li.ORIGEM,
       li.CRIADO_EM,
       m.ID_MEMBRO  as ID_MEMBRO_SUGERIU,
       m.APELIDO    as APELIDO_SUGERIU,
       m.COR        as COR_SUGERIU,
       t.TIPO,
       t.SITUACAO   as SITUACAO_TITULO,
       t.TITULO,
       t.ANO,
       t.DURACAO_MIN,
       t.TEMPORADAS,
       t.CLASSIFICACAO,
       t.NOTA,
       t.IDIOMA_ORIGINAL,
       t.POSTER_PATH,
       nvl(t.LINK_ONDE_ASSISTIR,
           'https://www.themoviedb.org/' || case t.TIPO when 'FILME' then 'movie' else 'tv' end
           || '/' || to_char(t.ID_TMDB) || '/watch?locale=BR') as LINK_TMDB
  from MMM_LISTA_ITEM li
  join MMM_TITULO t
    on t.ID_TITULO = li.ID_TITULO
  join MMM_MEMBRO m
    on m.ID_GRUPO  = li.ID_GRUPO
   and m.ID_MEMBRO = li.ID_MEMBRO_SUGERIU
 where li.RETIRADO_EM is null;

comment on table MMM_V_LISTA_ATIVA is 'Lista do grupo ativo com o titulo e quem sugeriu. Poster por URL do CDN do TMDB, nunca copiado.';

create or replace view MMM_V_TITULO_EM_USO as
select li.ID_TITULO from MMM_LISTA_ITEM li
union
select c.ID_TITULO from MMM_SESSAO_CARTA c
union
select a.ID_TITULO from MMM_ASSISTIDO a
union
select d.ID_TITULO from MMM_DEMO_ITEM d;

comment on table MMM_V_TITULO_EM_USO is 'Titulos que algum grupo (ou a demo) usa. Toda tabela nova com FK para MMM_TITULO entra aqui. Fora do APEX mostra todos; dentro, so os do grupo ativo e os da demo.';

create or replace view MMM_V_TITULO_SAIDA as
select l.ID_TITULO,
       l.ID_SERVICO,
       min(l.SAI_EM) as SAI_EM
  from MMM_LINK_DIRETO l
 where l.SAI_EM >= trunc(cast(systimestamp at time zone 'America/Sao_Paulo' as date))
 group by l.ID_TITULO,
          l.ID_SERVICO;

comment on table MMM_V_TITULO_SAIDA is 'Ultimo dia no catalogo por titulo e servico (Streaming Availability), so datas de hoje em diante.';

-- o que a busca, a pessoa e a saga desta sessao trouxeram (colecao MMM_BUSCA), com as marcas do grupo ativo: a tela, o
-- Adicionar a saga inteira e a contagem do botao usam a mesma regra
create or replace view MMM_V_BUSCA_SESSAO as
select x.SEQ_ID,
       x.ORIGEM,
       x.ID_ORIGEM,
       x.ORDEM,
       x.TIPO,
       x.ID_TMDB,
       x.TITULO,
       x.TITULO_ORIGINAL,
       x.ANO,
       x.DATA_LANCAMENTO,
       x.POSTER_PATH,
       x.PAPEL,
       x.ESTREIA,
       x.FL_LANCADO,
       x.FL_NA_LISTA,
       x.FL_JA_VISTO,
       case when x.FL_LANCADO = 'S' and x.FL_NA_LISTA = 'N' and x.FL_JA_VISTO = 'N' then 'S' else 'N' end as FL_ADICIONAVEL
  from (select c.SEQ_ID,
               c.C005 as ORIGEM,
               c.N003 as ID_ORIGEM,
               c.N004 as ORDEM,
               c.C001 as TIPO,
               c.N001 as ID_TMDB,
               c.C002 as TITULO,
               c.C003 as TITULO_ORIGINAL,
               c.N002 as ANO,
               c.D001 as DATA_LANCAMENTO,
               c.C004 as POSTER_PATH,
               c.C006 as PAPEL,
               c.C007 as ESTREIA,
               c.C008 as FL_LANCADO,
               case when exists (select 1
                                   from MMM_LISTA_ITEM li
                                   join MMM_TITULO t
                                     on t.ID_TITULO = li.ID_TITULO
                                  where li.RETIRADO_EM is null
                                    and t.TIPO    = c.C001
                                    and t.ID_TMDB = c.N001) then 'S' else 'N' end as FL_NA_LISTA,
               case when exists (select 1
                                   from MMM_ASSISTIDO a
                                   join MMM_TITULO t
                                     on t.ID_TITULO = a.ID_TITULO
                                  where t.TIPO    = c.C001
                                    and t.ID_TMDB = c.N001) then 'S' else 'N' end as FL_JA_VISTO
          from APEX_COLLECTIONS c
         where c.COLLECTION_NAME = 'MMM_BUSCA') x;

comment on table MMM_V_BUSCA_SESSAO is 'Titulos que a busca, a pessoa e a saga desta sessao APEX mostraram (colecao MMM_BUSCA), com Na lista e Voces ja viram do grupo ativo. Adicionavel = ja lancado, fora da lista e nunca visto (Adicionar a saga inteira). Nada fica gravado: a colecao some com a sessao.';

create or replace procedure MMM_MAPEAR_PROVEDORES authid definer is
begin
    -- refaz do zero: provedor que saiu da lista fica sem servico
    update MMM_PROVEDOR
       set ID_SERVICO      = null,
           FL_LOGO_SERVICO = 'N'
     where ID_SERVICO is not null;

    for f in (select s.ID_SERVICO,
                     j.ID_TMDB,
                     j.LOGO
                from json_table(q'~[
                        {"s":"netflix","p":8,"l":"S"},{"s":"netflix","p":1796,"l":"N"},
                        {"s":"prime","p":119,"l":"S"},{"s":"prime","p":2100,"l":"N"},
                        {"s":"hbo","p":1899,"l":"S"},{"s":"hbo","p":1825,"l":"N"},
                        {"s":"disney","p":337,"l":"S"},
                        {"s":"globoplay","p":307,"l":"S"},
                        {"s":"appletv","p":350,"l":"S"},{"s":"appletv","p":2243,"l":"N"},
                        {"s":"paramount","p":531,"l":"S"},{"s":"paramount","p":582,"l":"N"},
                        {"s":"paramount","p":2303,"l":"N"},{"s":"paramount","p":1853,"l":"N"},
                        {"s":"claro","p":484,"l":"S"},
                        {"s":"mubi","p":11,"l":"S"},{"s":"mubi","p":201,"l":"N"},
                        {"s":"telecine","p":2156,"l":"S"},
                        {"s":"universal","p":1889,"l":"S"},
                        {"s":"mgm","p":2141,"l":"S"},{"s":"mgm","p":2142,"l":"N"},
                        {"s":"oldflix","p":499,"l":"S"},
                        {"s":"arte","p":2607,"l":"S"},
                        {"s":"mercado","p":2302,"l":"S"},
                        {"s":"apple_loja","p":2,"l":"S"},
                        {"s":"amazon_loja","p":10,"l":"S"},
                        {"s":"google","p":3,"l":"S"},
                        {"s":"claro_video","p":167,"l":"S"}
                     ]~', '$[*]'
                     columns (
                         CODIGO   varchar2(30) path '$.s',
                         ID_TMDB  number       path '$.p',
                         LOGO     varchar2(1)  path '$.l')) j
                join MMM_SERVICO s
                  on s.CODIGO = j.CODIGO) loop
        update MMM_PROVEDOR
           set ID_SERVICO      = f.ID_SERVICO,
               FL_LOGO_SERVICO = f.LOGO
         where ID_TMDB = f.ID_TMDB;
    end loop;
end MMM_MAPEAR_PROVEDORES;
/
