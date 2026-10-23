create or replace package MMM_PKG_SA authid definer as

    -- JSON do botao Assistir: {"ok":true,"url":...,"servico":...,"nome":...,"origem":"SA"|"TMDB"}
    -- p_servicos: CODIGO das familias escolhidas na sessao, separados por ":"
    function link_assistir_json(
        p_id_titulo     in number,
        p_servicos      in varchar2,
        p_permitir_rede in varchar2 default 'S') return clob;

    procedure job_varrer_saidas;
    procedure job_preaquecer_demo;

end MMM_PKG_SA;
/

create or replace package body MMM_PKG_SA as

    -- jobs param antes disso para sobrar cota ao ingresso
    c_reserva_ingresso constant number := 300;

    -- a cota do SA e uma so e qualquer conta Google entra no app: teto por pessoa no ciclo.
    -- A estimativa e de ~13 ingressos por grupo no mes; 15 cobre a familia e limita um estranho
    c_teto_pessoa_ciclo constant pls_integer := 15;

    type t_link is record (
        url     varchar2(1000),
        servico varchar2(30),
        nome    varchar2(60),
        origem  varchar2(4));

    function consultar_sa(p_id_titulo in number, p_interativo in boolean) return varchar2 is
        l_tipo    MMM_TITULO.TIPO%type;
        l_id_tmdb MMM_TITULO.ID_TMDB%type;
        l_resp    MMM_PKG_HTTP.t_resposta;
        l_corpo   clob;
        l_agora   timestamp with time zone := systimestamp;
    begin
        select TIPO, ID_TMDB
          into l_tipo, l_id_tmdb
          from MMM_TITULO
         where ID_TITULO = p_id_titulo;

        -- o SA aceita o id do TMDB no caminho (movie/<id>, tv/<id>)
        l_resp := MMM_PKG_HTTP.chamar(
                      p_sistema    => 'SA',
                      p_operacao   => 'DEEP_LINK',
                      p_caminho    => '/shows/' || MMM_PKG_TMDB.rota(l_tipo) || '/' || l_id_tmdb
                                      || '?country=br&series_granularity=show&output_language=en',
                      p_timeout    => case when p_interativo then 6 else 15 end,
                      p_tentativas => 1,
                      p_id_titulo  => p_id_titulo);

        if l_resp.status = 404 then
            -- o SA nao conhece o titulo: anota para nao gastar cota de novo tao cedo
            update MMM_TITULO set SA_CONSULTADO_EM = l_agora where ID_TITULO = p_id_titulo;
            return '404';
        elsif l_resp.resultado <> 'OK' then
            return l_resp.resultado;
        end if;

        l_corpo := l_resp.corpo;
        delete from MMM_LINK_DIRETO where ID_TITULO = p_id_titulo;

        -- addon (canal dentro de outro servico) fica de fora na v1: o botao cai no link do TMDB
        insert into MMM_LINK_DIRETO (ID_TITULO, ID_SERVICO, TIPO_OFERTA, LINK, SAI_EM, SINCRONIZADO_EM)
        select p_id_titulo, x.ID_SERVICO, x.TIPO_OFERTA, x.LINK, x.SAI_EM, l_agora
          from (select s.ID_SERVICO,
                       case jt.TIPO_SA
                           when 'subscription' then 'ASSINATURA'
                           when 'free'         then 'GRATIS'
                           when 'rent'         then 'ALUGUEL'
                           else 'COMPRA'
                       end as TIPO_OFERTA,
                       substr(nvl(jt.VIDEO_LINK, jt.LINK), 1, 1000) as LINK,
                       case when jt.EXPIRA is not null then MMM_PKG_UTIL.de_unix(jt.EXPIRA) end as SAI_EM,
                       row_number() over (partition by s.ID_SERVICO, jt.TIPO_SA order by jt.ORDEM) as RN
                  from json_table(l_corpo, '$.streamingOptions.br[*]' columns (
                           ORDEM      for ordinality,
                           SERVICO    varchar2(30)   path '$.service.id',
                           TIPO_SA    varchar2(15)   path '$.type',
                           LINK       varchar2(1000) path '$.link',
                           VIDEO_LINK varchar2(1000) path '$.videoLink',
                           EXPIRA     number         path '$.expiresOn')) jt
                  join MMM_SERVICO s
                    on s.CODIGO_SA = jt.SERVICO
                   and s.CATEGORIA = case when jt.TIPO_SA in ('rent', 'buy') then 'LOJA' else 'ASSINATURA' end
                 where jt.TIPO_SA in ('subscription', 'free', 'rent', 'buy')) x
         where x.RN = 1
           and x.LINK like 'https://%';

        update MMM_TITULO set SA_CONSULTADO_EM = l_agora where ID_TITULO = p_id_titulo;
        return 'OK';
    end consultar_sa;

    -- o TMDB (renovado toda noite) decide onde o titulo esta; o SA so fornece o link
    function escolher(p_id_titulo in number, p_servicos in apex_t_varchar2) return t_link is
        l_link  t_link;
        l_vazio t_link;
        l_hoje  date := MMM_PKG_UTIL.hoje_br;
    begin
        select x.LINK, x.CODIGO, x.NOME, 'SA'
          into l_link.url, l_link.servico, l_link.nome, l_link.origem
          from (select l.LINK,
                       s.CODIGO,
                       s.NOME,
                       s.ORDEM,
                       case when s.CODIGO in (select column_value from table(p_servicos)) then 0 else 1 end as PREFERIDO,
                       case l.TIPO_OFERTA when 'ASSINATURA' then 0 when 'GRATIS' then 1 when 'ALUGUEL' then 3 else 4 end as ORDEM_TIPO
                  from MMM_LINK_DIRETO l
                  join MMM_SERVICO s
                    on s.ID_SERVICO = l.ID_SERVICO
                 where l.ID_TITULO = p_id_titulo
                   and l.LINK is not null
                   and l.SINCRONIZADO_EM > systimestamp - interval '30' day
                   and (l.SAI_EM is null or l.SAI_EM >= l_hoje)
                   and exists (select 1
                                 from MMM_DISPONIBILIDADE d
                                 join MMM_PROVEDOR p
                                   on p.ID_PROVEDOR = d.ID_PROVEDOR
                                where d.ID_TITULO  = l.ID_TITULO
                                  and p.ID_SERVICO = l.ID_SERVICO)) x
         order by x.PREFERIDO, x.ORDEM_TIPO, x.ORDEM
         fetch first 1 row only;
        return l_link;
    exception
        when no_data_found then
            return l_vazio;
    end escolher;

    -- sem link do SA (Globoplay, cota, titulo desconhecido): pagina de onde assistir do TMDB, sem deep link
    function fallback_tmdb(p_id_titulo in number, p_servicos in apex_t_varchar2) return t_link is
        l_link t_link;
    begin
        select nvl(t.LINK_ONDE_ASSISTIR,
                   'https://www.themoviedb.org/' || MMM_PKG_TMDB.rota(t.TIPO) || '/' || t.ID_TMDB || '/watch?locale=BR')
          into l_link.url
          from MMM_TITULO t
         where t.ID_TITULO = p_id_titulo;
        l_link.origem := 'TMDB';

        begin
            select x.CODIGO, x.NOME
              into l_link.servico, l_link.nome
              from (select distinct s.CODIGO, s.NOME, s.ORDEM, s.CATEGORIA,
                           case when s.CODIGO in (select column_value from table(p_servicos)) then 0 else 1 end as PREFERIDO
                      from MMM_DISPONIBILIDADE d
                      join MMM_PROVEDOR p
                        on p.ID_PROVEDOR = d.ID_PROVEDOR
                      join MMM_SERVICO s
                        on s.ID_SERVICO = p.ID_SERVICO
                     where d.ID_TITULO = p_id_titulo
                       and s.FL_ATIVO  = 'S') x
             order by x.PREFERIDO, case x.CATEGORIA when 'ASSINATURA' then 0 else 1 end, x.ORDEM
             fetch first 1 row only;
        exception
            when no_data_found then
                null;
        end;
        return l_link;
    end fallback_tmdb;

    function link_assistir(p_id_titulo in number, p_servicos in apex_t_varchar2, p_permitir_rede in boolean) return t_link is
        l_link     t_link;
        l_prov_em  MMM_TITULO.PROVEDORES_EM%type;
        l_sa_em    MMM_TITULO.SA_CONSULTADO_EM%type;
        l_cobertas number;
        l_res      varchar2(12);
    begin
        select PROVEDORES_EM, SA_CONSULTADO_EM
          into l_prov_em, l_sa_em
          from MMM_TITULO
         where ID_TITULO = p_id_titulo;

        -- onde esta hoje: renova so o vencedor, se passou de 12 horas
        if p_permitir_rede and (l_prov_em is null or l_prov_em < systimestamp - interval '12' hour) then
            l_res := MMM_PKG_TMDB.atualizar_provedores(p_id_titulo, p_interativo => true);
        end if;

        l_link := escolher(p_id_titulo, p_servicos);
        if l_link.url is not null then
            return l_link;
        end if;

        -- so gasta cota se algum servico onde o titulo esta tiver cobertura no SA
        select count(*)
          into l_cobertas
          from MMM_DISPONIBILIDADE d
          join MMM_PROVEDOR p
            on p.ID_PROVEDOR = d.ID_PROVEDOR
          join MMM_SERVICO s
            on s.ID_SERVICO = p.ID_SERVICO
         where d.ID_TITULO = p_id_titulo
           and s.CODIGO_SA is not null;

        if p_permitir_rede
           and l_cobertas > 0
           and (l_sa_em is null or l_sa_em < systimestamp - interval '7' day)
           and MMM_PKG_HTTP.chamadas_da_sessao('SA', 60) < 5
           and MMM_PKG_HTTP.chamadas_sa_da_pessoa < c_teto_pessoa_ciclo
           and MMM_PKG_HTTP.cota_sa_disponivel then
            l_res  := consultar_sa(p_id_titulo, p_interativo => true);
            l_link := escolher(p_id_titulo, p_servicos);
            if l_link.url is not null then
                return l_link;
            end if;
        end if;

        return fallback_tmdb(p_id_titulo, p_servicos);
    end link_assistir;

    function link_assistir_json(
        p_id_titulo     in number,
        p_servicos      in varchar2,
        p_permitir_rede in varchar2 default 'S') return clob is
        l_link     t_link;
        l_json     clob;
        l_servicos apex_t_varchar2 := apex_string.split(p_servicos, ':');
    begin
        if l_servicos is null then
            l_servicos := apex_t_varchar2();
        end if;
        l_link := link_assistir(
                      p_id_titulo     => p_id_titulo,
                      p_servicos      => l_servicos,
                      p_permitir_rede => p_permitir_rede = 'S');

        select json_object(
                   'ok'      value 'true' format json,
                   'url'     value l_link.url,
                   'servico' value l_link.servico,
                   'nome'    value l_link.nome,
                   'origem'  value l_link.origem
                   returning clob)
          into l_json
          from dual;
        return l_json;
    end link_assistir_json;

    procedure job_varrer_saidas is
        l_catalogos varchar2(4000);
        l_hoje      date   := MMM_PKG_UTIL.hoje_br;
        l_de        number;
        l_ate       number;
        l_ultimo    number;
        l_dia_de    date;
        l_segunda   boolean;
        l_completo  boolean := false;
        l_cursor    varchar2(4000);
        l_resp      MMM_PKG_HTTP.t_resposta;
        l_corpo     clob;
        l_doc       json_object_t;
        l_shows     json_object_t;
        l_show      json_object_t;
        l_tmdb      varchar2(40);
        l_tipo      varchar2(5);
        l_id_tmdb   number;
        l_id        number;
        l_servico   number;
        l_paginas   pls_integer := 0;
        l_casados   pls_integer := 0;
    begin
        if not MMM_PKG_HTTP.cota_sa_disponivel(p_reserva => c_reserva_ingresso) then
            MMM_PKG_UTIL.log_app('SA_SAIDAS', 0, 'pulado para guardar cota do ingresso ('
                                 || MMM_PKG_HTTP.requisicoes_sa_no_ciclo || ' no ciclo)');
            return;
        end if;

        -- marca d'agua (dias desde 2000-01-01, no log): dia que falhou entra na rodada seguinte;
        -- na segunda, revarre a semana para pegar saida avisada com menos de 7 dias
        select max(QUANTIDADE)
          into l_ultimo
          from MMM_INTEGRACAO_LOG
         where SISTEMA   = 'APP'
           and OPERACAO  = 'SA_SAIDAS_ATE'
           and CRIADO_EM > systimestamp - interval '31' day;
        l_segunda := to_char(l_hoje, 'DY', 'NLS_DATE_LANGUAGE=ENGLISH') = 'MON';
        l_dia_de  := case
                         when l_segunda then l_hoje + 1
                         else greatest(l_hoje + 1, nvl(date '2000-01-01' + l_ultimo + 1, l_hoje + 7))
                     end;
        l_de  := MMM_PKG_UTIL.para_unix(l_dia_de);
        l_ate := MMM_PKG_UTIL.para_unix(l_hoje + 8) - 1;
        if l_de > l_ate then
            return;
        end if;

        -- so os servicos que algum grupo real assina, ate 32 catalogos
        select listagg(x.CATALOGO, ',') within group (order by x.CATALOGO)
          into l_catalogos
          from (select distinct s.CODIGO_SA || '.subscription' as CATALOGO
                  from MMM_GRUPO_SERVICO gs
                  join MMM_GRUPO g
                    on g.ID_GRUPO = gs.ID_GRUPO
                  join MMM_SERVICO s
                    on s.ID_SERVICO = gs.ID_SERVICO
                 where g.FL_DEMO   = 'N'
                   and s.CATEGORIA = 'ASSINATURA'
                   and s.CODIGO_SA is not null
                 fetch first 32 rows only) x;

        if l_catalogos is null then
            MMM_PKG_UTIL.log_app('SA_SAIDAS', 0, 'nenhum grupo assina servico coberto pelo SA');
            return;
        end if;

        -- da marca d'agua ate D+7 (na segunda, a semana toda), uma pagina de cada vez
        loop
            l_paginas := l_paginas + 1;
            l_resp := MMM_PKG_HTTP.chamar(
                          p_sistema    => 'SA',
                          p_operacao   => 'SAIDAS',
                          p_caminho    => '/changes?country=br&change_type=expiring&item_type=show'
                                          || '&catalogs=' || MMM_PKG_HTTP.escapar(l_catalogos)
                                          || '&from=' || l_de || '&to=' || l_ate
                                          || case when l_cursor is not null
                                                  then '&cursor=' || MMM_PKG_HTTP.escapar(l_cursor) end,
                          p_timeout    => 15,
                          p_tentativas => 1);
            exit when l_resp.resultado <> 'OK';

            l_corpo := l_resp.corpo;
            l_doc   := json_object_t.parse(l_corpo);
            l_shows := case when l_doc.has('shows') then l_doc.get_object('shows') end;

            for c in (select jt.SHOW_ID, jt.SERVICO, jt.TIPO_SA, jt.INSTANTE, jt.LINK
                        from json_table(l_corpo, '$.changes[*]' columns (
                                 SHOW_ID  varchar2(40)   path '$.showId',
                                 SERVICO  varchar2(30)   path '$.service.id',
                                 TIPO_SA  varchar2(15)   path '$.streamingOptionType',
                                 INSTANTE number         path '$.timestamp',
                                 LINK     varchar2(1000) path '$.link')) jt
                       where jt.INSTANTE is not null
                         and jt.TIPO_SA in ('subscription', 'free')) loop
                l_tmdb    := null;
                l_id      := null;
                l_servico := null;
                if l_shows is not null and l_shows.has(c.SHOW_ID) then
                    l_show := l_shows.get_object(c.SHOW_ID);
                    l_tmdb := l_show.get_string('tmdbId');
                end if;
                l_tipo    := case regexp_substr(l_tmdb, '^(movie|tv)/', 1, 1, null, 1)
                                 when 'movie' then 'FILME'
                                 when 'tv'    then 'SERIE'
                             end;
                l_id_tmdb := to_number(regexp_substr(l_tmdb, '/([0-9]+)$', 1, 1, null, 1));

                if l_tipo is not null and l_id_tmdb is not null then
                    select max(t.ID_TITULO)
                      into l_id
                      from MMM_TITULO t
                     where t.TIPO    = l_tipo
                       and t.ID_TMDB = l_id_tmdb;
                    select max(s.ID_SERVICO)
                      into l_servico
                      from MMM_SERVICO s
                     where s.CODIGO_SA = c.SERVICO
                       and s.CATEGORIA = 'ASSINATURA';
                end if;

                if l_id is not null and l_servico is not null then
                    merge into MMM_LINK_DIRETO d
                    using (select l_id as ID_TITULO,
                                  l_servico as ID_SERVICO,
                                  case c.TIPO_SA when 'free' then 'GRATIS' else 'ASSINATURA' end as TIPO_OFERTA,
                                  case when c.LINK like 'https://%' then substr(c.LINK, 1, 1000) end as LINK,
                                  MMM_PKG_UTIL.de_unix(c.INSTANTE) as SAI_EM
                             from dual) s
                       on (d.ID_TITULO = s.ID_TITULO and d.ID_SERVICO = s.ID_SERVICO and d.TIPO_OFERTA = s.TIPO_OFERTA)
                     when matched then update
                          set d.SAI_EM          = s.SAI_EM,
                              d.LINK            = nvl(s.LINK, d.LINK),
                              d.SINCRONIZADO_EM = systimestamp
                     when not matched then insert (ID_TITULO, ID_SERVICO, TIPO_OFERTA, LINK, SAI_EM, SINCRONIZADO_EM)
                          values (s.ID_TITULO, s.ID_SERVICO, s.TIPO_OFERTA, s.LINK, s.SAI_EM, systimestamp);
                    l_casados := l_casados + 1;
                end if;
            end loop;
            commit;

            l_cursor := case when l_doc.has('hasMore') and l_doc.get_boolean('hasMore')
                             then l_doc.get_string('nextCursor') end;
            l_completo := l_cursor is null;
            exit when l_cursor is null or l_paginas >= case when l_segunda then 20 else 8 end;
        end loop;

        -- a marca so anda quando o cursor chegou ao fim; o que faltou entra na rodada seguinte
        if l_completo then
            MMM_PKG_UTIL.log_app('SA_SAIDAS_ATE', (l_hoje + 7) - date '2000-01-01');
        end if;
        MMM_PKG_UTIL.log_app('SA_SAIDAS', l_casados, l_paginas || ' paginas, ' || l_casados || ' titulos nossos com data de saida');
    end job_varrer_saidas;

    -- a demo nunca chama o SA ao vivo; o link dela e renovado aqui, no maximo 10 por semana
    procedure job_preaquecer_demo is
        l_qtd pls_integer := 0;
        l_res varchar2(12);
    begin
        for t in (select t.ID_TITULO
                    from MMM_TITULO t
                    join MMM_DEMO_ITEM d
                      on d.ID_TITULO = t.ID_TITULO
                   where t.SITUACAO = 'OK'
                     and (t.SA_CONSULTADO_EM is null or t.SA_CONSULTADO_EM < systimestamp - interval '30' day)
                     and exists (select 1
                                   from MMM_DISPONIBILIDADE di
                                   join MMM_PROVEDOR p
                                     on p.ID_PROVEDOR = di.ID_PROVEDOR
                                   join MMM_SERVICO s
                                     on s.ID_SERVICO = p.ID_SERVICO
                                  where di.ID_TITULO = t.ID_TITULO
                                    and s.CODIGO_SA is not null)
                   order by t.SA_CONSULTADO_EM nulls first) loop
            exit when l_qtd >= 10 or not MMM_PKG_HTTP.cota_sa_disponivel(p_reserva => c_reserva_ingresso);
            l_res := consultar_sa(t.ID_TITULO, p_interativo => false);
            commit;
            exit when l_res in ('COTA', 'CIRCUITO', 'ACL', 'CERTIFICADO');
            l_qtd := l_qtd + 1;
        end loop;
        MMM_PKG_UTIL.log_app('SA_DEMO', l_qtd, l_qtd || ' titulos da demo com link renovado');
    end job_preaquecer_demo;

end MMM_PKG_SA;
/

create or replace package MMM_PKG_LISTA authid definer as

    function ficha_json(p_id_titulo in number) return clob;

    -- Adicionar pela busca; um titulo tirado volta a ativo na mesma linha
    function adicionar(p_tipo in varchar2, p_id_tmdb in number, p_pipocas in number, p_origem in varchar2) return number;

    -- p_escolhas: [{"seq":1,"tipo":"FILME","idTmdb":872585,"pipocas":2}]
    function adicionar_da_nota(p_escolhas in clob) return number;

    -- Adicionar a saga inteira: as partes que a saga desta sessao mostrou, ja lancadas, fora da lista e nunca vistas pelo
    -- grupo; sem chamar o TMDB (o titulo novo nasce PENDENTE e o job completa). Devolve quantas entraram
    function adicionar_saga(p_id_saga in number, p_pipocas in number, p_origem in varchar2) return number;

    procedure tirar(p_id_lista_item in number);
    procedure devolver(p_id_lista_item in number);

end MMM_PKG_LISTA;
/

create or replace package body MMM_PKG_LISTA as

    procedure incluir(p_id_titulo in number, p_pipocas in number, p_origem in varchar2, p_texto in varchar2 default null) is
        l_id_membro number := MMM_PKG_SEGURANCA.id_membro_atual;
    begin
        if l_id_membro is null then
            raise_application_error(-20701, 'Escolha um grupo antes.');
        end if;

        merge into MMM_LISTA_ITEM li
        using (select l_id_membro as ID_MEMBRO,
                      p_id_titulo as ID_TITULO,
                      least(greatest(nvl(p_pipocas, 2), 1), 3) as PIPOCAS,
                      substr(p_origem, 1, 100) as ORIGEM,
                      substr(p_texto, 1, 200) as TEXTO
                 from dual) s
           on (li.ID_GRUPO = MMM_PKG_SEGURANCA.id_grupo_ativo and li.ID_TITULO = s.ID_TITULO)
         when matched then update
              set li.ID_MEMBRO_SUGERIU = s.ID_MEMBRO,
                  li.PIPOCAS           = s.PIPOCAS,
                  li.ORIGEM            = s.ORIGEM,
                  li.TEXTO_DIGITADO    = s.TEXTO,
                  li.RETIRADO_EM       = null,
                  li.ID_MEMBRO_RETIROU = null,
                  li.MOTIVO_RETIRADA   = null
              where li.RETIRADO_EM is not null
         when not matched then insert (ID_TITULO, ID_MEMBRO_SUGERIU, PIPOCAS, ORIGEM, TEXTO_DIGITADO)
              values (s.ID_TITULO, s.ID_MEMBRO, s.PIPOCAS, s.ORIGEM, s.TEXTO);
    end incluir;

    function adicionar(p_tipo in varchar2, p_id_tmdb in number, p_pipocas in number, p_origem in varchar2) return number is
        l_id_titulo number;
        l_situacao  MMM_TITULO.SITUACAO%type;
    begin
        l_id_titulo := MMM_PKG_TMDB.garantir_titulo(p_tipo, p_id_tmdb);
        incluir(l_id_titulo, p_pipocas, p_origem);
        -- o run_job comita: so depois de o item entrar na lista, senao um titulo PENDENTE ficaria orfao
        select SITUACAO
          into l_situacao
          from MMM_TITULO
         where ID_TITULO = l_id_titulo;
        if l_situacao = 'PENDENTE' then
            MMM_PKG_TMDB.acordar_job_completar;
        end if;
        return l_id_titulo;
    end adicionar;

    function adicionar_da_nota(p_escolhas in clob) return number is
        l_id_titulo number;
        l_linha     varchar2(200);
        l_qtd       pls_integer := 0;
    begin
        for e in (select jt.SEQ, jt.TIPO, jt.ID_TMDB, jt.PIPOCAS
                    from json_table(p_escolhas, '$[*]' columns (
                             SEQ     number      path '$.seq',
                             TIPO    varchar2(5) path '$.tipo',
                             ID_TMDB number      path '$.idTmdb',
                             PIPOCAS number      path '$.pipocas')) jt
                   fetch first 30 rows only) loop
            l_id_titulo := MMM_PKG_TMDB.titulo_da_nota(e.SEQ, e.TIPO, e.ID_TMDB);
            select max(c.C001)
              into l_linha
              from APEX_COLLECTIONS c
             where c.COLLECTION_NAME = 'MMM_NOTA'
               and c.SEQ_ID          = e.SEQ;
            incluir(l_id_titulo, e.PIPOCAS, 'Nota antiga', l_linha);
            l_qtd := l_qtd + 1;
        end loop;

        -- sinopse, duracao e onde assistir chegam pelo job, em segundo plano
        MMM_PKG_TMDB.acordar_job_completar;
        return l_qtd;
    end adicionar_da_nota;

    function adicionar_saga(p_id_saga in number, p_pipocas in number, p_origem in varchar2) return number is
        -- como a nota: um pedido nao passa de 30 titulos
        c_max_partes constant pls_integer := 30;
        l_na_sessao  pls_integer;
        l_qtd        pls_integer := 0;
        l_pendentes  pls_integer := 0;
        l_novas      pls_integer;
        l_id_titulo  number;
        l_situacao   MMM_TITULO.SITUACAO%type;
    begin
        if MMM_PKG_SEGURANCA.id_membro_atual is null then
            raise_application_error(-20701, 'Escolha um grupo antes.');
        end if;
        -- so vale a saga que esta tela abriu nesta sessao: e dela que vem o titulo de quem ainda nao esta no catalogo
        select count(*)
          into l_na_sessao
          from MMM_V_BUSCA_SESSAO v
         where v.ORIGEM    = 'SAGA'
           and v.ID_ORIGEM = p_id_saga;
        if l_na_sessao = 0 then
            raise_application_error(-20613, 'Abra a saga de novo para adicionar.');
        end if;

        -- na demo, cada parte que o catalogo ainda nao tem e uma chamada do job ao TMDB: conta no teto da visita
        select count(*)
          into l_novas
          from (select v.TIPO,
                       v.ID_TMDB
                  from MMM_V_BUSCA_SESSAO v
                 where v.ORIGEM         = 'SAGA'
                   and v.ID_ORIGEM      = p_id_saga
                   and v.FL_ADICIONAVEL = 'S'
                 order by v.ORDEM
                 fetch first c_max_partes rows only) p
         where not exists (select 1
                             from MMM_TITULO t
                            where t.TIPO    = p.TIPO
                              and t.ID_TMDB = p.ID_TMDB);
        MMM_PKG_TMDB.reservar_demo(l_novas);

        -- a mesma regra da contagem do botao (MMM_V_BUSCA_SESSAO, pelo VPD do grupo ativo)
        for p in (select v.TIPO,
                         v.ID_TMDB
                    from MMM_V_BUSCA_SESSAO v
                   where v.ORIGEM         = 'SAGA'
                     and v.ID_ORIGEM      = p_id_saga
                     and v.FL_ADICIONAVEL = 'S'
                   order by v.ORDEM
                   fetch first c_max_partes rows only) loop
            l_id_titulo := MMM_PKG_TMDB.titulo_da_sessao(p.TIPO, p.ID_TMDB);
            incluir(l_id_titulo, p_pipocas, p_origem);
            l_qtd := l_qtd + 1;
            select SITUACAO
              into l_situacao
              from MMM_TITULO
             where ID_TITULO = l_id_titulo;
            if l_situacao = 'PENDENTE' then
                l_pendentes := l_pendentes + 1;
            end if;
        end loop;

        -- o run_job comita: so no fim, com tudo ja na lista
        if l_pendentes > 0 then
            MMM_PKG_TMDB.acordar_job_completar;
        end if;
        return l_qtd;
    end adicionar_saga;

    procedure tirar(p_id_lista_item in number) is
    begin
        -- qualquer membro tira titulo da lista; o VPD limita ao grupo ativo
        update MMM_LISTA_ITEM
           set RETIRADO_EM       = systimestamp,
               ID_MEMBRO_RETIROU = MMM_PKG_SEGURANCA.id_membro_atual,
               MOTIVO_RETIRADA   = 'MANUAL'
         where ID_LISTA_ITEM = p_id_lista_item
           and RETIRADO_EM is null;
        if sql%rowcount = 0 then
            raise_application_error(-20702, 'Esse título já não está na lista.');
        end if;
    end tirar;

    procedure devolver(p_id_lista_item in number) is
    begin
        update MMM_LISTA_ITEM
           set RETIRADO_EM       = null,
               ID_MEMBRO_RETIROU = null,
               MOTIVO_RETIRADA   = null
         where ID_LISTA_ITEM   = p_id_lista_item
           and MOTIVO_RETIRADA = 'MANUAL';
        if sql%rowcount = 0 then
            raise_application_error(-20703, 'Não deu para devolver esse título.');
        end if;
    end devolver;

    function ficha_json(p_id_titulo in number) return clob is
        l_json clob;
        l_hoje date := MMM_PKG_UTIL.hoje_br;
    begin
        select json_object(
                   'ok'     value 'true' format json,
                   'titulo' value json_object(
                       'id'            value t.ID_TITULO,
                       'tipo'          value t.TIPO,
                       'idTmdb'        value t.ID_TMDB,
                       'titulo'        value t.TITULO,
                       'ano'           value t.ANO,
                       'duracao'       value t.DURACAO_MIN,
                       'temporadas'    value t.TEMPORADAS,
                       'nota'          value t.NOTA,
                       'cls'           value t.CLASSIFICACAO,
                       'sinopse'       value dbms_lob.substr(t.SINOPSE, 1500, 1),
                       'sinopseIdioma' value t.SINOPSE_IDIOMA,
                       'poster'        value t.POSTER_PATH,
                       'fundo'         value t.FUNDO_PATH,
                       'trailer'       value t.TRAILER_CHAVE,
                       'tmdbUrl'       value nvl(t.LINK_ONDE_ASSISTIR,
                                                 'https://www.themoviedb.org/' || MMM_PKG_TMDB.rota(t.TIPO) || '/' || t.ID_TMDB),
                       'generos'       value (select json_arrayagg(g.NOME order by g.NOME returning clob)
                                                from MMM_TITULO_GENERO tg
                                                join MMM_GENERO g
                                                  on g.ID_GENERO = tg.ID_GENERO
                                               where tg.ID_TITULO = p_id_titulo) format json,
                       'onde'          value (select json_arrayagg(
                                                         json_object(
                                                             'servico' value o.CODIGO,
                                                             'nome'    value o.NOME,
                                                             'logo'    value o.LOGO,
                                                             'tipo'    value o.TIPO,
                                                             'saiEm'   value to_char(o.SAI_EM, 'DD/MM'))
                                                         order by o.ORDEM returning clob)
                                                from (select s.CODIGO,
                                                             s.NOME,
                                                             s.ORDEM,
                                                             (select max(pl.LOGO_PATH)
                                                                from MMM_PROVEDOR pl
                                                               where pl.ID_SERVICO      = s.ID_SERVICO
                                                                 and pl.FL_LOGO_SERVICO = 'S') as LOGO,
                                                             case when s.CATEGORIA = 'LOJA' then 'LOJA' else 'ASSINATURA' end as TIPO,
                                                             (select min(l.SAI_EM)
                                                                from MMM_LINK_DIRETO l
                                                               where l.ID_TITULO  = p_id_titulo
                                                                 and l.ID_SERVICO = s.ID_SERVICO
                                                                 and l.SAI_EM    >= l_hoje) as SAI_EM
                                                        from MMM_SERVICO s
                                                       where s.FL_ATIVO = 'S'
                                                         and exists (select 1
                                                                       from MMM_DISPONIBILIDADE d
                                                                       join MMM_PROVEDOR p
                                                                         on p.ID_PROVEDOR = d.ID_PROVEDOR
                                                                      where d.ID_TITULO  = p_id_titulo
                                                                        and p.ID_SERVICO = s.ID_SERVICO)) o) format json,
                       'minhaVez'      value (select case when m.CARTAS_MINHA_VEZ = 1 then 'true' else 'false' end
                                                from MMM_MEMBRO m
                                               where m.ID_MEMBRO = MMM_PKG_SEGURANCA.id_membro_atual) format json,
                       -- Faz parte da saga e Mais com: so quando os detalhes ja foram lidos com o elenco
                       'saga'          value case when t.ID_SAGA_TMDB is not null then
                                                 json_object('id'   value t.ID_SAGA_TMDB,
                                                             'nome' value MMM_PKG_TMDB.nome_saga(t.SAGA_NOME))
                                             end format json,
                       'pessoas'       value t.PESSOAS_JSON format json,
                       -- Voce tambem pode gostar: ate 10, na ordem do TMDB, sem o que o grupo ativo ja viu ou escolheu na Hora
                       -- do Cinema (a mesma regra do Voces ja viram da busca) e com o que esta na lista marcado
                       'recomendacoes' value (select json_arrayagg(
                                                         json_object(
                                                             'tipo'       value r.TIPO,
                                                             'idTmdb'     value r.ID_TMDB,
                                                             'titulo'     value r.TITULO,
                                                             'ano'        value r.ANO,
                                                             'posterPath' value r.POSTER,
                                                             'naLista'    value case r.NA_LISTA when 'S' then 'true' else 'false' end format json
                                                             absent on null)
                                                         order by r.POS returning clob)
                                                from (select j.TIPO,
                                                             j.ID_TMDB,
                                                             j.TITULO,
                                                             j.ANO,
                                                             j.POSTER,
                                                             row_number() over (order by j.N) as POS,
                                                             case when exists (select 1
                                                                                 from MMM_LISTA_ITEM li
                                                                                 join MMM_TITULO tl
                                                                                   on tl.ID_TITULO = li.ID_TITULO
                                                                                where li.RETIRADO_EM is null
                                                                                  and tl.TIPO    = j.TIPO
                                                                                  and tl.ID_TMDB = j.ID_TMDB) then 'S' else 'N' end as NA_LISTA
                                                        from MMM_TITULO tr,
                                                             json_table(tr.RECOMENDACOES_JSON, '$[*]' columns (
                                                                 N       for ordinality,
                                                                 TIPO    varchar2(5)   path '$.tipo',
                                                                 ID_TMDB number        path '$.idTmdb',
                                                                 TITULO  varchar2(400) path '$.titulo',
                                                                 ANO     number        path '$.ano',
                                                                 POSTER  varchar2(200) path '$.posterPath')) j
                                                       where tr.ID_TITULO = p_id_titulo
                                                         and j.TIPO in ('FILME', 'SERIE')
                                                         and j.ID_TMDB is not null
                                                         and not exists (select 1
                                                                           from MMM_ASSISTIDO a
                                                                           join MMM_TITULO ta
                                                                             on ta.ID_TITULO = a.ID_TITULO
                                                                          where ta.TIPO    = j.TIPO
                                                                            and ta.ID_TMDB = j.ID_TMDB)) r
                                               where r.POS <= 10) format json,
                       'item'          value (select json_object(
                                                         'id'      value li.ID_LISTA_ITEM,
                                                         'pipocas' value li.PIPOCAS,
                                                         'origem'  value li.ORIGEM,
                                                         'apelido' value m.APELIDO,
                                                         'cor'     value m.COR)
                                                from MMM_LISTA_ITEM li
                                                join MMM_MEMBRO m
                                                  on m.ID_GRUPO  = li.ID_GRUPO
                                                 and m.ID_MEMBRO = li.ID_MEMBRO_SUGERIU
                                               where li.ID_TITULO   = p_id_titulo
                                                 and li.RETIRADO_EM is null) format json
                       absent on null
                       returning clob)
                   returning clob)
          into l_json
          from MMM_TITULO t
         where t.ID_TITULO = p_id_titulo;
        return l_json;
    exception
        when no_data_found then
            raise_application_error(-20701, 'Título não encontrado.');
    end ficha_json;

end MMM_PKG_LISTA;
/
