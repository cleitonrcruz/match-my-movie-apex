create or replace package MMM_PKG_TMDB authid definer as

    c_job_completar constant varchar2(30) := 'MMM_JOB_COMPLETAR';

    function rota(p_tipo in varchar2) return varchar2;
    function normalizar(p_texto in varchar2) return varchar2;

    -- nome em portugues dos generos de serie que o TMDB devolve em ingles; publica porque o MERGE chama em SQL
    function nome_genero(p_id_tmdb in number, p_nome in varchar2) return varchar2;

    -- devolvem OK, 404, ERRO ou PARAR (credencial, ACL, certificado ou circuito aberto)
    function atualizar_titulo(p_id_titulo in number, p_interativo in boolean default false) return varchar2;
    function atualizar_provedores(p_id_titulo in number, p_interativo in boolean default false) return varchar2;

    -- acha ou cria o titulo pelo id do TMDB; chamado pelo Adicionar (dentro da sessao APEX)
    function garantir_titulo(p_tipo in varchar2, p_id_tmdb in number) return number;
    -- o mesmo, pela ficha aberta no Voce tambem pode gostar: o titulo novo e uma chamada por toque, no limite da sessao
    function titulo_da_ficha(p_tipo in varchar2, p_id_tmdb in number) return number;

    function buscar_json(p_termo in varchar2) return clob;
    -- p_continuar = 'S': processa so as linhas que ficaram NAO_PROCESSADA no pedido anterior
    function reconhecer_nota(p_texto in varchar2, p_continuar in varchar2 default 'N') return clob;
    function titulo_da_nota(p_seq in number, p_tipo in varchar2, p_id_tmdb in number) return number;

    procedure acordar_job_completar;

    -- jobs (DBMS_SCHEDULER, fora do APEX)
    procedure job_completar_pendentes;
    procedure job_noite;
    procedure job_catalogo_mensal;

    -- busca por pessoa e saga: uma chamada ao TMDB por toque, no teto da demo e no limite da sessao
    function pessoa_json(p_id_pessoa in number) return clob;
    function saga_json(p_id_saga in number) return clob;
    -- partes da saga desta sessao com as marcas, sem rede (resposta do Adicionar a saga inteira)
    function saga_da_sessao_json(p_id_saga in number) return clob;
    -- acha o titulo pelo id do TMDB ou o cria PENDENTE com o que a busca, a pessoa ou a saga desta sessao trouxe, sem rede;
    -- o MMM_JOB_COMPLETAR completa depois
    function titulo_da_sessao(p_tipo in varchar2, p_id_tmdb in number) return number;

    -- leitura das respostas do TMDB, sem rede e sem tabela: as rotinas da tela chamam e da para testar com respostas guardadas
    function separar_ano(p_termo in varchar2, p_ano out number) return varchar2;
    function nome_saga(p_nome in varchar2) return varchar2;
    function ler_busca(p_multi in clob, p_colecoes in clob, p_ano in number default null, p_hoje in date default null,
                       p_termo in varchar2 default null) return clob;
    function ler_pessoa(p_creditos in clob, p_hoje in date default null) return clob;
    function ler_saga(p_colecao in clob, p_hoje in date default null) return clob;
    function ler_extras(p_detalhes in clob, p_tipo in varchar2) return clob;
    function ler_recomendacoes(p_detalhes in clob, p_tipo in varchar2) return varchar2;

    -- resposta da tela a partir do que o TMDB ja respondeu: guarda os titulos na colecao da sessao (o Adicionar cai nesses
    -- dados se os detalhes falharem) e marca o que esta na lista e o que o grupo ja viu
    function montar_busca(p_multi in clob, p_colecoes in clob, p_ano in number default null, p_termo in varchar2 default null) return clob;
    function montar_pessoa(p_id_pessoa in number, p_creditos in clob) return clob;
    function montar_saga(p_id_saga in number, p_colecao in clob) return clob;

    -- grava no titulo uma resposta de detalhes ja recebida, pela mesma rotina do Adicionar e dos jobs
    procedure gravar_detalhes(p_id_titulo in number, p_corpo in clob);

    -- visitante da demo: as chamadas que o job vai fazer por ele (partes novas da saga) contam no teto da visita e da hora
    procedure reservar_demo(p_qtd in pls_integer);

    -- avulso: elenco, saga e recomendacoes dos titulos em uso que ainda nao tem
    procedure job_repor_detalhes;

end MMM_PKG_TMDB;
/

create or replace package body MMM_PKG_TMDB as

    c_colecao_busca constant varchar2(30) := 'MMM_BUSCA';
    c_colecao_nota  constant varchar2(30) := 'MMM_NOTA';

    -- demo publica: teto de chamadas ao TMDB por visita e somando todos os visitantes na hora
    c_teto_visita_tmdb constant pls_integer := 60;
    c_teto_demo_hora   constant pls_integer := 600;

    -- busca, pessoa e saga por minuto na mesma sessao: a busca roda a cada letra
    c_teto_minuto_sessao constant pls_integer := 40;
    -- lista da pessoa: os titulos mais novos, por tipo (filmes e series)
    c_teto_lista_pessoa  constant pls_integer := 80;
    -- caminho de imagem do TMDB que pode virar URL, o mesmo teste do mmm.js
    c_caminho_imagem     constant varchar2(60) := '^/[A-Za-z0-9_-]+\.(jpg|jpeg|png|svg)$';

    function rota(p_tipo in varchar2) return varchar2 is
    begin
        return case p_tipo when 'FILME' then 'movie' when 'SERIE' then 'tv' end;
    end rota;

    function normalizar(p_texto in varchar2) return varchar2 is
        l_texto varchar2(4000);
    begin
        l_texto := lower(p_texto);
        l_texto := translate(l_texto, 'áàâãäéèêëíìîïóòôõöúùûüçñ', 'aaaaaeeeeiiiiooooouuuucn');
        l_texto := replace(l_texto, '&', ' e ');
        return trim(regexp_replace(l_texto, '[^a-z0-9]+', ' '));
    end normalizar;

    procedure registrar_falha(p_id_titulo in number, p_status in number) is
    begin
        update MMM_TITULO
           set FALHAS_SEGUIDAS    = FALHAS_SEGUIDAS + 1,
               ULTIMA_FALHA_EM    = systimestamp,
               ULTIMO_STATUS_HTTP = p_status
         where ID_TITULO = p_id_titulo;
    end registrar_falha;

    -- classificacao BR do TMDB normalizada para a lista que o jogo entende
    function classificacao_br(p_valor in varchar2) return varchar2 is
        l_valor varchar2(10) := upper(trim(p_valor));
    begin
        if l_valor in ('L', 'AL', 'LIVRE') then
            return 'L';
        elsif l_valor in ('10', '12', '14', '16', '18') then
            return l_valor;
        end if;
        return null;
    end classificacao_br;

    -- o TMDB devolve em ingles oito generos de serie mesmo com language=pt-BR; o mapeamento clima-genero
    -- usa o id, entao so o nome muda
    function nome_genero(p_id_tmdb in number, p_nome in varchar2) return varchar2 is
    begin
        return case p_id_tmdb
                   when 10759 then 'Ação e aventura'
                   when 10762 then 'Infantil'
                   when 10763 then 'Notícias'
                   when 10764 then 'Reality show'
                   when 10765 then 'Ficção científica e fantasia'
                   when 10766 then 'Novela'
                   when 10767 then 'Talk show'
                   when 10768 then 'Guerra e política'
                   else p_nome
               end;
    end nome_genero;

    -- ---------- leitura das respostas do TMDB (sem rede e sem tabela) ----------

    -- "duna 2021" e "o rei leao (2019)": o ano sai da consulta e vira filtro. Entre parenteses vale em qualquer lugar,
    -- como na nota; solto, so no fim e depois do nome ("1917" e "2012" sozinhos sao titulos) e so ano que ja pode ter
    -- estreia ("blade runner 2049" fica como esta)
    function separar_ano(p_termo in varchar2, p_ano out number) return varchar2 is
        l_termo varchar2(400) := trim(p_termo);
        l_ano   number;
    begin
        p_ano := null;
        l_ano := to_number(regexp_substr(l_termo, '\(((19|20)[0-9]{2})\)', 1, 1, null, 1));
        if l_ano is not null then
            p_ano := l_ano;
            return trim(regexp_replace(regexp_replace(l_termo, '\(((19|20)[0-9]{2})\)', ' ', 1, 1), '\s+', ' '));
        end if;
        l_ano := to_number(regexp_substr(l_termo, '^.*\S\s+((19|20)[0-9]{2})$', 1, 1, null, 1));
        if l_ano is not null and l_ano <= extract(year from sysdate) + 3 then
            p_ano := l_ano;
            return trim(regexp_replace(l_termo, '\s+((19|20)[0-9]{2})$', ''));
        end if;
        return l_termo;
    end separar_ano;

    -- o TMDB chama a saga de "Harry Potter: Coleção"; a tela ja diz que e saga
    function nome_saga(p_nome in varchar2) return varchar2 is
        l_nome varchar2(400);
    begin
        l_nome := trim(regexp_replace(p_nome, '\s*(:|-|–)?\s*\(?(cole[cç][aã]o|collection)\)?\s*$', '', 1, 1, 'i'));
        return coalesce(l_nome, p_nome);
    end nome_saga;

    -- /search/multi e /search/collection: titulos como hoje (com o filtro do ano), ate 3 pessoas com foto e ate 3 sagas
    function ler_busca(p_multi in clob, p_colecoes in clob, p_ano in number default null, p_hoje in date default null,
                       p_termo in varchar2 default null) return clob is
        l_hoje    date := nvl(p_hoje, MMM_PKG_UTIL.hoje_br);
        l_ano_txt varchar2(4) := to_char(p_ano);
        l_com_ano pls_integer := 0;
        l_itens   clob;
        l_pessoas clob;
        l_sagas   clob;
        l_saida   clob;
    begin
        -- ficam os titulos daquele ano ou com o ano no nome; sem nenhum, o filtro sai e a tela avisa
        if p_ano is not null then
            select count(*)
              into l_com_ano
              from json_table(p_multi, '$.results[*]' columns (
                       MEDIA_TYPE     varchar2(10)  path '$.media_type',
                       TITLE          varchar2(400) path '$.title',
                       NAME           varchar2(400) path '$.name',
                       ORIGINAL_TITLE varchar2(400) path '$.original_title',
                       ORIGINAL_NAME  varchar2(400) path '$.original_name',
                       RELEASE_DATE   varchar2(10)  path '$.release_date',
                       FIRST_AIR_DATE varchar2(10)  path '$.first_air_date')) jt
             where jt.MEDIA_TYPE in ('movie', 'tv')
               and (substr(coalesce(jt.RELEASE_DATE, jt.FIRST_AIR_DATE), 1, 4) = l_ano_txt
                    or instr(coalesce(jt.TITLE, jt.NAME) || ' ' || coalesce(jt.ORIGINAL_TITLE, jt.ORIGINAL_NAME), l_ano_txt) > 0);
        end if;

        select json_arrayagg(
                   json_object(
                       'tipo'       value x.TIPO,
                       'idTmdb'     value x.ID_TMDB,
                       'titulo'     value x.TITULO,
                       'original'   value x.ORIGINAL,
                       'ano'        value x.ANO,
                       'data'       value to_char(x.DATA, 'YYYY-MM-DD'),
                       'posterPath' value x.POSTER_PATH,
                       'estreia'    value case
                                              when x.DATA is null then 'Sem data de estreia'
                                              when x.DATA > l_hoje then 'Estreia em '
                                                  || to_char(x.DATA, 'mon', 'nls_date_language=''BRAZILIAN PORTUGUESE''')
                                                  || '/' || to_char(x.DATA, 'yyyy')
                                          end,
                       'lancado'    value case when x.DATA <= l_hoje then 'true' else 'false' end format json
                       absent on null returning clob)
                   order by x.ORDEM returning clob)
          into l_itens
          from (select case jt.MEDIA_TYPE when 'movie' then 'FILME' else 'SERIE' end as TIPO,
                       jt.ID_TMDB,
                       coalesce(jt.TITLE, jt.NAME) as TITULO,
                       coalesce(jt.ORIGINAL_TITLE, jt.ORIGINAL_NAME) as ORIGINAL,
                       to_number(substr(coalesce(jt.RELEASE_DATE, jt.FIRST_AIR_DATE), 1, 4) default null on conversion error) as ANO,
                       to_date(coalesce(jt.RELEASE_DATE, jt.FIRST_AIR_DATE) default null on conversion error, 'YYYY-MM-DD') as DATA,
                       substr(coalesce(jt.RELEASE_DATE, jt.FIRST_AIR_DATE), 1, 4) as ANO_TXT,
                       coalesce(jt.TITLE, jt.NAME) || ' ' || coalesce(jt.ORIGINAL_TITLE, jt.ORIGINAL_NAME) as NOMES,
                       jt.POSTER_PATH,
                       jt.ORDEM
                  from json_table(p_multi, '$.results[*]' columns (
                           ORDEM          for ordinality,
                           MEDIA_TYPE     varchar2(10)  path '$.media_type',
                           ID_TMDB        number        path '$.id',
                           TITLE          varchar2(400) path '$.title',
                           NAME           varchar2(400) path '$.name',
                           ORIGINAL_TITLE varchar2(400) path '$.original_title',
                           ORIGINAL_NAME  varchar2(400) path '$.original_name',
                           RELEASE_DATE   varchar2(10)  path '$.release_date',
                           FIRST_AIR_DATE varchar2(10)  path '$.first_air_date',
                           POSTER_PATH    varchar2(200) path '$.poster_path')) jt
                 where jt.MEDIA_TYPE in ('movie', 'tv')
                   and jt.ID_TMDB is not null
                   and coalesce(jt.TITLE, jt.NAME) is not null) x
         where l_com_ano = 0
            or x.ANO_TXT = l_ano_txt
            or instr(x.NOMES, l_ano_txt) > 0;

        -- so pessoa com foto e conhecida no TMDB (popularidade de 1 para cima) ou com o nome igual ao que foi digitado: os
        -- homonimos (Christopher Nolan) e quem so tem o termo no nome (Steffi Duna na busca de duna) ficam de fora
        select json_arrayagg(
                   json_object(
                       'id'           value p.ID,
                       'nome'         value p.NOME,
                       'area'         value p.AREA,
                       'conhecidoPor' value p.CONHECIDO,
                       'fotoPath'     value p.FOTO
                       absent on null returning clob)
                   order by p.ORDEM returning clob)
          into l_pessoas
          from (select jt.ORDEM,
                       max(jt.ID) as ID,
                       max(jt.NOME) as NOME,
                       max(case jt.AREA
                               when 'Acting'            then 'Atuação'
                               when 'Directing'         then 'Direção'
                               when 'Writing'           then 'Roteiro'
                               when 'Production'        then 'Produção'
                               when 'Sound'             then 'Música e som'
                               when 'Camera'            then 'Fotografia'
                               when 'Editing'           then 'Montagem'
                               when 'Art'               then 'Direção de arte'
                               when 'Costume & Make-Up' then 'Figurino e maquiagem'
                               when 'Visual Effects'    then 'Efeitos visuais'
                               when 'Lighting'          then 'Iluminação'
                               when 'Creator'           then 'Criação'
                               when 'Crew'              then 'Equipe técnica'
                           end) as AREA,
                       max(jt.FOTO) as FOTO,
                       listagg(case when jt.KF_N <= 3 then coalesce(jt.KF_TITLE, jt.KF_NAME) end, ', ')
                           within group (order by jt.KF_N) as CONHECIDO,
                       row_number() over (order by jt.ORDEM) as POSICAO
                  from json_table(p_multi, '$.results[*]' columns (
                           ORDEM      for ordinality,
                           MEDIA_TYPE varchar2(10)  path '$.media_type',
                           ID         number        path '$.id',
                           NOME       varchar2(200) path '$.name',
                           AREA       varchar2(60)  path '$.known_for_department',
                           FOTO       varchar2(200) path '$.profile_path',
                           POPULARIDADE number      path '$.popularity',
                           nested path '$.known_for[*]' columns (
                               KF_N     for ordinality,
                               KF_TITLE varchar2(400) path '$.title',
                               KF_NAME  varchar2(400) path '$.name'))) jt
                 where jt.MEDIA_TYPE = 'person'
                   and jt.ID is not null
                   and jt.NOME is not null
                   and regexp_like(jt.FOTO, c_caminho_imagem)
                   and (jt.POPULARIDADE >= 1 or MMM_PKG_TMDB.normalizar(jt.NOME) = MMM_PKG_TMDB.normalizar(p_termo))
                 group by jt.ORDEM) p
         where p.POSICAO <= 3;

        if p_colecoes is not null then
            select json_arrayagg(
                       json_object(
                           'id'         value s.ID,
                           'nome'       value MMM_PKG_TMDB.nome_saga(s.NOME),
                           'posterPath' value s.POSTER
                           absent on null returning clob)
                       order by s.ORDEM returning clob)
              into l_sagas
              from (select jt.ID,
                           jt.NOME,
                           jt.POSTER,
                           jt.ORDEM,
                           row_number() over (order by jt.ORDEM) as POSICAO
                      from json_table(p_colecoes, '$.results[*]' columns (
                               ORDEM  for ordinality,
                               ID     number        path '$.id',
                               NOME   varchar2(300) path '$.name',
                               POSTER varchar2(200) path '$.poster_path')) jt
                     where jt.ID is not null
                       and jt.NOME is not null) s
             where s.POSICAO <= 3;
        end if;

        select json_object(
                   'itens'      value nvl(l_itens, to_clob('[]')) format json,
                   'pessoas'    value nvl(l_pessoas, to_clob('[]')) format json,
                   'sagas'      value nvl(l_sagas, to_clob('[]')) format json,
                   'ano'        value p_ano,
                   'filtrouAno' value case when p_ano is null then null when l_com_ano > 0 then 'true' else 'false' end format json
                   absent on null returning clob)
          into l_saida
          from dual;
        return l_saida;
    end ler_busca;

    -- /person/{id}/combined_credits: atuou, dirigiu (e criou, na serie) viram um titulo so, com o papel ao lado; filmes
    -- e series separados, os mais novos primeiro (o que nao estreou fica no topo, o sem data no fim). Ficam de fora as
    -- participacoes como ele mesmo (documentarios, entrevistas, homenagens), os programas de entrevista e de jornal
    -- (generos 10767 e 10763) e o que nao tem poster
    function ler_pessoa(p_creditos in clob, p_hoje in date default null) return clob is
        l_hoje  date := nvl(p_hoje, MMM_PKG_UTIL.hoje_br);
        l_saida clob;
    begin
        with creditos as (
                 select jt.MEDIA_TYPE,
                        jt.ID_TMDB,
                        jt.N,
                        coalesce(jt.TITLE, jt.NAME) as TITULO,
                        coalesce(jt.ORIGINAL_TITLE, jt.ORIGINAL_NAME) as ORIGINAL,
                        coalesce(jt.RELEASE_DATE, jt.FIRST_AIR_DATE) as DATA_TXT,
                        jt.POSTER_PATH,
                        jt.GENEROS,
                        jt.PERSONAGEM,
                        cast(null as varchar2(100)) as FUNCAO
                   from json_table(p_creditos, '$.cast[*]' columns (
                            N              for ordinality,
                            MEDIA_TYPE     varchar2(10)  path '$.media_type',
                            ID_TMDB        number        path '$.id',
                            TITLE          varchar2(400) path '$.title',
                            NAME           varchar2(400) path '$.name',
                            ORIGINAL_TITLE varchar2(400) path '$.original_title',
                            ORIGINAL_NAME  varchar2(400) path '$.original_name',
                            RELEASE_DATE   varchar2(10)  path '$.release_date',
                            FIRST_AIR_DATE varchar2(10)  path '$.first_air_date',
                            POSTER_PATH    varchar2(200) path '$.poster_path',
                            GENEROS        varchar2(400) format json path '$.genre_ids',
                            PERSONAGEM     varchar2(400) path '$.character')) jt
                 union all
                 select jt.MEDIA_TYPE,
                        jt.ID_TMDB,
                        100000 + jt.N,
                        coalesce(jt.TITLE, jt.NAME),
                        coalesce(jt.ORIGINAL_TITLE, jt.ORIGINAL_NAME),
                        coalesce(jt.RELEASE_DATE, jt.FIRST_AIR_DATE),
                        jt.POSTER_PATH,
                        jt.GENEROS,
                        null,
                        jt.FUNCAO
                   from json_table(p_creditos, '$.crew[*]' columns (
                            N              for ordinality,
                            MEDIA_TYPE     varchar2(10)  path '$.media_type',
                            ID_TMDB        number        path '$.id',
                            TITLE          varchar2(400) path '$.title',
                            NAME           varchar2(400) path '$.name',
                            ORIGINAL_TITLE varchar2(400) path '$.original_title',
                            ORIGINAL_NAME  varchar2(400) path '$.original_name',
                            RELEASE_DATE   varchar2(10)  path '$.release_date',
                            FIRST_AIR_DATE varchar2(10)  path '$.first_air_date',
                            POSTER_PATH    varchar2(200) path '$.poster_path',
                            GENEROS        varchar2(400) format json path '$.genre_ids',
                            FUNCAO         varchar2(100) path '$.job')) jt
                  where jt.FUNCAO in ('Director', 'Creator')),
             validos as (
                 select c.MEDIA_TYPE,
                        c.ID_TMDB,
                        c.N,
                        c.TITULO,
                        c.ORIGINAL,
                        c.DATA_TXT,
                        c.POSTER_PATH,
                        c.FUNCAO,
                        -- "(voice)" vira "(voz)" e "(uncredited)" sai; so a voz, sem nome de personagem, fica "voz"
                        nullif(trim(regexp_replace(regexp_replace(regexp_replace(c.PERSONAGEM,
                                   '\(uncredited\)', '', 1, 0, 'i'), '\(voice\)', '(voz)', 1, 0, 'i'), '\s+', ' ')), '(voz)') as PERSONAGEM,
                        case when regexp_like(c.PERSONAGEM, '\(voice\)', 'i') then 1 else 0 end as VOZ
                   from creditos c
                  where c.MEDIA_TYPE in ('movie', 'tv')
                    and c.ID_TMDB is not null
                    and c.TITULO is not null
                    and not regexp_like(nvl(c.GENEROS, '[]'), '(^|[^0-9])(10767|10763)([^0-9]|$)')
                    and (c.FUNCAO is not null
                         or not regexp_like(trim(nvl(c.PERSONAGEM, '-')), '^(self|himself|herself|ele mesmo|ela mesma)([^[:alpha:]]|$)', 'i'))),
             obras as (
                 select case v.MEDIA_TYPE when 'movie' then 'FILME' else 'SERIE' end as TIPO,
                        v.ID_TMDB,
                        max(v.TITULO) as TITULO,
                        max(v.ORIGINAL) as ORIGINAL,
                        to_date(max(v.DATA_TXT) default null on conversion error, 'YYYY-MM-DD') as DATA,
                        max(v.POSTER_PATH) as POSTER_PATH,
                        listagg(distinct v.PERSONAGEM, ' / ') within group (order by v.PERSONAGEM) as PERSONAGENS,
                        max(v.VOZ) as VOZ,
                        max(case when v.FUNCAO = 'Director' then 1 else 0 end) as DIRECAO,
                        max(case when v.FUNCAO = 'Creator' then 1 else 0 end) as CRIACAO,
                        min(v.N) as N
                   from validos v
                  group by v.MEDIA_TYPE,
                           v.ID_TMDB),
             lista as (
                 select o.TIPO,
                        o.ID_TMDB,
                        o.TITULO,
                        o.ORIGINAL,
                        o.DATA,
                        o.POSTER_PATH,
                        substr(case when o.PERSONAGENS is not null then ' · como ' || o.PERSONAGENS
                                    when o.VOZ = 1 then ' · voz' end
                               || case when o.DIRECAO = 1 then ' · Direção' end
                               || case when o.CRIACAO = 1 then ' · Criação' end, 4, 150) as PAPEL,
                        row_number() over (partition by o.TIPO order by o.DATA desc nulls last, o.N) as POSICAO
                   from obras o)
        select json_object(
                   'filmes'      value nvl(json_arrayagg(
                                               case when l.TIPO = 'FILME' and l.POSICAO <= c_teto_lista_pessoa then
                                                   json_object(
                                                       'tipo'       value l.TIPO,
                                                       'idTmdb'     value l.ID_TMDB,
                                                       'titulo'     value l.TITULO,
                                                       'original'   value l.ORIGINAL,
                                                       'ano'        value extract(year from l.DATA),
                                                       'data'       value to_char(l.DATA, 'YYYY-MM-DD'),
                                                       'posterPath' value case when regexp_like(l.POSTER_PATH, c_caminho_imagem) then l.POSTER_PATH end,
                                                       'papel'      value l.PAPEL,
                                                       'estreia'    value case
                                                                              when l.DATA is null then 'Sem data de estreia'
                                                                              when l.DATA > l_hoje then 'Estreia em '
                                                                                  || to_char(l.DATA, 'mon', 'nls_date_language=''BRAZILIAN PORTUGUESE''')
                                                                                  || '/' || to_char(l.DATA, 'yyyy')
                                                                          end,
                                                       'lancado'    value case when l.DATA <= l_hoje then 'true' else 'false' end format json
                                                       absent on null returning clob)
                                               end format json
                                               order by l.POSICAO returning clob), to_clob('[]')) format json,
                   'series'      value nvl(json_arrayagg(
                                               case when l.TIPO = 'SERIE' and l.POSICAO <= c_teto_lista_pessoa then
                                                   json_object(
                                                       'tipo'       value l.TIPO,
                                                       'idTmdb'     value l.ID_TMDB,
                                                       'titulo'     value l.TITULO,
                                                       'original'   value l.ORIGINAL,
                                                       'ano'        value extract(year from l.DATA),
                                                       'data'       value to_char(l.DATA, 'YYYY-MM-DD'),
                                                       'posterPath' value case when regexp_like(l.POSTER_PATH, c_caminho_imagem) then l.POSTER_PATH end,
                                                       'papel'      value l.PAPEL,
                                                       'estreia'    value case
                                                                              when l.DATA is null then 'Sem data de estreia'
                                                                              when l.DATA > l_hoje then 'Estreia em '
                                                                                  || to_char(l.DATA, 'mon', 'nls_date_language=''BRAZILIAN PORTUGUESE''')
                                                                                  || '/' || to_char(l.DATA, 'yyyy')
                                                                          end,
                                                       'lancado'    value case when l.DATA <= l_hoje then 'true' else 'false' end format json
                                                       absent on null returning clob)
                                               end format json
                                               order by l.POSICAO returning clob), to_clob('[]')) format json,
                   'totalFilmes' value count(case when l.TIPO = 'FILME' then 1 end),
                   'totalSeries' value count(case when l.TIPO = 'SERIE' then 1 end)
                   returning clob)
          into l_saida
          from lista l;
        return l_saida;
    end ler_pessoa;

    -- /collection/{id}: as partes vem fora de ordem (Harry Potter, Avatar) e ficam na ordem de lancamento; o que ainda
    -- nao estreou vai com a data e nao conta no Adicionar a saga inteira
    function ler_saga(p_colecao in clob, p_hoje in date default null) return clob is
        l_hoje  date := nvl(p_hoje, MMM_PKG_UTIL.hoje_br);
        l_saida clob;
    begin
        select json_object(
                   'id'         value s.ID,
                   'nome'       value MMM_PKG_TMDB.nome_saga(s.NOME),
                   'posterPath' value s.POSTER,
                   'partes'     value nvl((select json_arrayagg(
                                                      json_object(
                                                          'tipo'       value p.TIPO,
                                                          'idTmdb'     value p.ID_TMDB,
                                                          'titulo'     value p.TITULO,
                                                          'original'   value p.ORIGINAL,
                                                          'ano'        value extract(year from p.DATA),
                                                          'data'       value to_char(p.DATA, 'YYYY-MM-DD'),
                                                          'posterPath' value p.POSTER_PATH,
                                                          'estreia'    value case
                                                                                 when p.DATA is null then 'Sem data de estreia'
                                                                                 when p.DATA > l_hoje then 'Estreia em '
                                                                                     || to_char(p.DATA, 'mon', 'nls_date_language=''BRAZILIAN PORTUGUESE''')
                                                                                     || '/' || to_char(p.DATA, 'yyyy')
                                                                             end,
                                                          'lancado'    value case when p.DATA <= l_hoje then 'true' else 'false' end format json
                                                          absent on null returning clob)
                                                      order by p.DATA nulls last, p.N returning clob)
                                             from (select case jt.MEDIA_TYPE when 'tv' then 'SERIE' else 'FILME' end as TIPO,
                                                          jt.ID_TMDB,
                                                          jt.N,
                                                          coalesce(jt.TITLE, jt.NAME) as TITULO,
                                                          coalesce(jt.ORIGINAL_TITLE, jt.ORIGINAL_NAME) as ORIGINAL,
                                                          to_date(coalesce(jt.RELEASE_DATE, jt.FIRST_AIR_DATE) default null on conversion error,
                                                                  'YYYY-MM-DD') as DATA,
                                                          jt.POSTER_PATH
                                                     from json_table(p_colecao, '$.parts[*]' columns (
                                                              N              for ordinality,
                                                              MEDIA_TYPE     varchar2(10)  path '$.media_type',
                                                              ID_TMDB        number        path '$.id',
                                                              TITLE          varchar2(400) path '$.title',
                                                              NAME           varchar2(400) path '$.name',
                                                              ORIGINAL_TITLE varchar2(400) path '$.original_title',
                                                              ORIGINAL_NAME  varchar2(400) path '$.original_name',
                                                              RELEASE_DATE   varchar2(10)  path '$.release_date',
                                                              FIRST_AIR_DATE varchar2(10)  path '$.first_air_date',
                                                              POSTER_PATH    varchar2(200) path '$.poster_path')) jt
                                                    where jt.ID_TMDB is not null
                                                      and coalesce(jt.TITLE, jt.NAME) is not null) p), to_clob('[]')) format json
                   absent on null returning clob)
          into l_saida
          from json_table(p_colecao, '$' columns (
                   ID     number        path '$.id',
                   NOME   varchar2(300) path '$.name',
                   POSTER varchar2(200) path '$.poster_path')) s;
        return l_saida;
    end ler_saga;

    -- detalhes com o append do elenco: a saga do filme (belongs_to_collection) e as pessoas da ficha, ate 3 do elenco
    -- pela ordem do TMDB e quem dirigiu o filme (credits) ou criou a serie (created_by); na serie o elenco vem do
    -- aggregate_credits. A mesma pessoa no elenco e na direcao aparece uma vez, como elenco
    function ler_extras(p_detalhes in clob, p_tipo in varchar2) return clob is
        l_saida clob;
    begin
        select json_object(
                   'saga'    value (select json_object('id' value s.ID, 'nome' value s.NOME)
                                      from json_table(p_detalhes, '$.belongs_to_collection' columns (
                                               ID   number        path '$.id',
                                               NOME varchar2(300) path '$.name')) s
                                     where p_tipo = 'FILME'
                                       and s.ID is not null
                                       and s.NOME is not null) format json,
                   'pessoas' value nvl((select json_arrayagg(
                                                   json_object(
                                                       'id'       value y.ID,
                                                       'nome'     value y.NOME,
                                                       'papel'    value y.PAPEL,
                                                       'fotoPath' value y.FOTO
                                                       absent on null)
                                                   order by y.GRUPO, y.POSICAO returning varchar2(4000))
                                          from (select x.*,
                                                       row_number() over (partition by x.ID order by x.GRUPO, x.POSICAO) as VEZ
                                                  from (select 1 as GRUPO, e.ID, substr(e.NOME, 1, 100) as NOME, 'ELENCO' as PAPEL, e.FOTO,
                                                               row_number() over (order by e.ORDEM nulls last, e.N) as POSICAO
                                                          from json_table(p_detalhes, '$.credits.cast[*]' columns (
                                                                   N     for ordinality,
                                                                   ID    number        path '$.id',
                                                                   NOME  varchar2(200) path '$.name',
                                                                   ORDEM number        path '$.order',
                                                                   FOTO  varchar2(200) path '$.profile_path')) e
                                                         where p_tipo = 'FILME'
                                                           and e.ID is not null
                                                           and e.NOME is not null
                                                        union all
                                                        select 1, e.ID, substr(e.NOME, 1, 100), 'ELENCO', e.FOTO,
                                                               row_number() over (order by e.ORDEM nulls last, e.N)
                                                          from json_table(p_detalhes, '$.aggregate_credits.cast[*]' columns (
                                                                   N     for ordinality,
                                                                   ID    number        path '$.id',
                                                                   NOME  varchar2(200) path '$.name',
                                                                   ORDEM number        path '$.order',
                                                                   FOTO  varchar2(200) path '$.profile_path')) e
                                                         where p_tipo = 'SERIE'
                                                           and e.ID is not null
                                                           and e.NOME is not null
                                                        union all
                                                        select 2, d.ID, substr(max(d.NOME), 1, 100), 'DIRECAO', max(d.FOTO),
                                                               row_number() over (order by min(d.N))
                                                          from json_table(p_detalhes, '$.credits.crew[*]' columns (
                                                                   N      for ordinality,
                                                                   ID     number        path '$.id',
                                                                   NOME   varchar2(200) path '$.name',
                                                                   FUNCAO varchar2(100) path '$.job',
                                                                   FOTO   varchar2(200) path '$.profile_path')) d
                                                         where p_tipo = 'FILME'
                                                           and d.FUNCAO = 'Director'
                                                           and d.ID is not null
                                                           and d.NOME is not null
                                                         group by d.ID
                                                        union all
                                                        select 2, c.ID, substr(c.NOME, 1, 100), 'CRIACAO', c.FOTO,
                                                               row_number() over (order by c.N)
                                                          from json_table(p_detalhes, '$.created_by[*]' columns (
                                                                   N    for ordinality,
                                                                   ID   number        path '$.id',
                                                                   NOME varchar2(200) path '$.name',
                                                                   FOTO varchar2(200) path '$.profile_path')) c
                                                         where p_tipo = 'SERIE'
                                                           and c.ID is not null
                                                           and c.NOME is not null) x
                                                 where x.POSICAO <= case x.GRUPO when 1 then 3 else 2 end) y
                                         where y.VEZ = 1), '[]') format json
                   absent on null returning clob)
          into l_saida
          from dual;
        return l_saida;
    end ler_extras;

    -- Voce tambem pode gostar: as recomendacoes do TMDB (nao os "similar", que comparam so genero e palavra-chave e
    -- trazem muito titulo sem relacao), na ordem dele, sem adulto e sem poster, ate 20 e ate caber na coluna
    -- (4000 bytes; o grupo esconde os que ja viu na hora de mostrar). Nulo = a resposta nao trouxe o bloco (o valor de antes
    -- fica); [] = trouxe e veio vazio
    function ler_recomendacoes(p_detalhes in clob, p_tipo in varchar2) return varchar2 is
        l_saida varchar2(4000);
        l_veio  pls_integer;
    begin
        select count(*)
          into l_veio
          from dual
         where json_exists(p_detalhes, '$.recommendations.results');
        if l_veio = 0 then
            return null;
        end if;
        select json_arrayagg(r.ITEM format json order by r.POS returning varchar2(4000))
          into l_saida
          from (select x.ITEM,
                       x.POS,
                       sum(lengthb(x.ITEM) + 1) over (order by x.POS) as ACUMULADO
                  from (select json_object(
                                   'tipo'       value case j.MIDIA when 'movie' then 'FILME' when 'tv' then 'SERIE' else p_tipo end,
                                   'idTmdb'     value j.ID,
                                   'titulo'     value substr(coalesce(j.TITLE, j.NAME), 1, 80),
                                   'ano'        value to_number(substr(coalesce(j.LANCAMENTO, j.ESTREIA), 1, 4) default null on conversion error),
                                   'posterPath' value j.POSTER
                                   absent on null returning varchar2(400)) as ITEM,
                               row_number() over (order by j.N) as POS
                          from json_table(p_detalhes, '$.recommendations.results[*]' columns (
                                   N          for ordinality,
                                   ID         number        path '$.id',
                                   MIDIA      varchar2(10)  path '$.media_type',
                                   TITLE      varchar2(400) path '$.title',
                                   NAME       varchar2(400) path '$.name',
                                   LANCAMENTO varchar2(10)  path '$.release_date',
                                   ESTREIA    varchar2(10)  path '$.first_air_date',
                                   POSTER     varchar2(200) path '$.poster_path',
                                   ADULTO     varchar2(5)   path '$.adult')) j
                         where j.ID is not null
                           and coalesce(j.TITLE, j.NAME) is not null
                           and regexp_like(j.POSTER, c_caminho_imagem)
                           and nvl(j.ADULTO, 'false') <> 'true'
                           and nvl(j.MIDIA, 'movie') in ('movie', 'tv')) x
                 where x.POS <= 20) r
         where r.ACUMULADO <= 3900;
        return nvl(l_saida, '[]');
    end ler_recomendacoes;

    procedure gravar_generos(p_id_titulo in number, p_tipo in varchar2, p_corpo in clob, p_agora in timestamp with time zone) is
    begin
        merge into MMM_GENERO g
        using (select jt.ID_TMDB, MMM_PKG_TMDB.nome_genero(jt.ID_TMDB, max(jt.NOME)) as NOME
                 from json_table(p_corpo, '$.genres[*]' columns (
                          ID_TMDB number       path '$.id',
                          NOME    varchar2(60) path '$.name')) jt
                where jt.ID_TMDB is not null
                  and jt.NOME is not null
                group by jt.ID_TMDB) s
           on (g.ID_TMDB = s.ID_TMDB)
         when matched then update
              set g.NOME            = s.NOME,
                  g.FL_FILME        = case when p_tipo = 'FILME' then 'S' else g.FL_FILME end,
                  g.FL_SERIE        = case when p_tipo = 'SERIE' then 'S' else g.FL_SERIE end,
                  g.SINCRONIZADO_EM = p_agora
         when not matched then insert (ID_TMDB, NOME, FL_FILME, FL_SERIE, SINCRONIZADO_EM)
              values (s.ID_TMDB, s.NOME,
                      case when p_tipo = 'FILME' then 'S' else 'N' end,
                      case when p_tipo = 'SERIE' then 'S' else 'N' end,
                      p_agora);

        delete from MMM_TITULO_GENERO
         where ID_TITULO = p_id_titulo;

        insert into MMM_TITULO_GENERO (ID_TITULO, ID_GENERO, SINCRONIZADO_EM)
        select distinct p_id_titulo, g.ID_GENERO, p_agora
          from json_table(p_corpo, '$.genres[*]' columns (ID_TMDB number path '$.id')) jt
          join MMM_GENERO g
            on g.ID_TMDB = jt.ID_TMDB;
    end gravar_generos;

    -- p_wp: documento com results.BR (resposta de /watch/providers ou o bloco "watch/providers" do append)
    procedure gravar_provedores(p_id_titulo in number, p_wp in clob, p_agora in timestamp with time zone) is
        l_ids    apex_t_number;
        l_tipos  apex_t_varchar2;
        l_nomes  apex_t_varchar2;
        l_logos  apex_t_varchar2;
        l_novos  pls_integer := 0;
    begin
        -- caminhos irmaos de NESTED PATH saem em linhas separadas: uma por provedor e tipo de oferta
        select coalesce(jt.ID_A, jt.ID_B, jt.ID_C, jt.ID_D, jt.ID_E),
               case
                   when jt.ID_A is not null then 'ASSINATURA'
                   when jt.ID_B is not null then 'ANUNCIOS'
                   when jt.ID_C is not null then 'GRATIS'
                   when jt.ID_D is not null then 'ALUGUEL'
                   else 'COMPRA'
               end,
               coalesce(jt.NOME_A, jt.NOME_B, jt.NOME_C, jt.NOME_D, jt.NOME_E),
               coalesce(jt.LOGO_A, jt.LOGO_B, jt.LOGO_C, jt.LOGO_D, jt.LOGO_E)
          bulk collect into l_ids, l_tipos, l_nomes, l_logos
          from json_table(p_wp, '$.results.BR' columns (
                   nested path '$.flatrate[*]' columns (ID_A number path '$.provider_id', NOME_A varchar2(100) path '$.provider_name', LOGO_A varchar2(200) path '$.logo_path'),
                   nested path '$.ads[*]'      columns (ID_B number path '$.provider_id', NOME_B varchar2(100) path '$.provider_name', LOGO_B varchar2(200) path '$.logo_path'),
                   nested path '$.free[*]'     columns (ID_C number path '$.provider_id', NOME_C varchar2(100) path '$.provider_name', LOGO_C varchar2(200) path '$.logo_path'),
                   nested path '$.rent[*]'     columns (ID_D number path '$.provider_id', NOME_D varchar2(100) path '$.provider_name', LOGO_D varchar2(200) path '$.logo_path'),
                   nested path '$.buy[*]'      columns (ID_E number path '$.provider_id', NOME_E varchar2(100) path '$.provider_name', LOGO_E varchar2(200) path '$.logo_path'))) jt
         where coalesce(jt.ID_A, jt.ID_B, jt.ID_C, jt.ID_D, jt.ID_E) is not null;

        for i in 1 .. l_ids.count loop
            update MMM_PROVEDOR
               set NOME            = nvl(l_nomes(i), NOME),
                   LOGO_PATH       = nvl(l_logos(i), LOGO_PATH),
                   SINCRONIZADO_EM = p_agora
             where ID_TMDB = l_ids(i);
            if sql%rowcount = 0 then
                begin
                    insert into MMM_PROVEDOR (ID_TMDB, NOME, LOGO_PATH, SINCRONIZADO_EM)
                    values (l_ids(i), nvl(l_nomes(i), 'Provedor ' || l_ids(i)), l_logos(i), p_agora);
                    l_novos := l_novos + 1;
                exception
                    when dup_val_on_index then
                        null;  -- outra sessao gravou o mesmo provedor
                end;
            end if;
        end loop;

        -- provedor novo entra sem familia; o mapeamento conhecido liga na hora, o resto fica para o mensal
        if l_novos > 0 then
            MMM_MAPEAR_PROVEDORES;
        end if;

        delete from MMM_DISPONIBILIDADE
         where ID_TITULO = p_id_titulo;

        for i in 1 .. l_ids.count loop
            insert into MMM_DISPONIBILIDADE (ID_TITULO, ID_PROVEDOR, TIPO_OFERTA, SINCRONIZADO_EM)
            select p_id_titulo, p.ID_PROVEDOR, l_tipos(i), p_agora
              from MMM_PROVEDOR p
             where p.ID_TMDB = l_ids(i)
               and not exists (select 1
                                 from MMM_DISPONIBILIDADE d
                                where d.ID_TITULO   = p_id_titulo
                                  and d.ID_PROVEDOR = p.ID_PROVEDOR
                                  and d.TIPO_OFERTA = l_tipos(i));
        end loop;

        update MMM_TITULO
           set PROVEDORES_EM      = p_agora,
               LINK_ONDE_ASSISTIR = nvl(substr(json_value(p_wp, '$.results.BR.link'), 1, 400), LINK_ONDE_ASSISTIR)
         where ID_TITULO = p_id_titulo;
    end gravar_provedores;

    function baixar_detalhes(p_tipo in varchar2, p_id_tmdb in number, p_interativo in boolean, p_id_titulo in number) return MMM_PKG_HTTP.t_resposta is
    begin
        -- uma chamada traz detalhes, trailer, classificacao, onde assistir, traducoes (para a sinopse vazia), o elenco
        -- (as pessoas da ficha; na serie o aggregate_credits, que soma as temporadas) e as recomendacoes (a primeira pagina)
        -- na tela, uma tentativa e sem espera: o pedido segura uma das poucas vagas HTTP da ATP; quem repete e o job
        return MMM_PKG_HTTP.chamar(
                   p_sistema    => 'TMDB',
                   p_operacao   => 'DETALHES',
                   p_caminho    => '/' || rota(p_tipo) || '/' || p_id_tmdb
                                   || '?language=pt-BR'
                                   || '&include_video_language=' || MMM_PKG_HTTP.escapar('pt,en')
                                   || '&append_to_response=' || MMM_PKG_HTTP.escapar(
                                          case p_tipo
                                              when 'FILME' then 'videos,release_dates,watch/providers,translations,credits,recommendations'
                                              else 'videos,content_ratings,watch/providers,translations,aggregate_credits,recommendations'
                                          end),
                   p_timeout    => case when p_interativo then 5 else 15 end,
                   p_tentativas => case when p_interativo then 1 else 2 end,
                   p_espera_max => case when p_interativo then 2 else 10 end,
                   p_id_titulo  => p_id_titulo);
    end baixar_detalhes;

    procedure aplicar_detalhes(p_id_titulo in number, p_tipo in varchar2, p_id_tmdb in number, p_corpo in clob, p_interativo in boolean) is
        l_agora       timestamp with time zone := systimestamp;
        l_titulo      varchar2(400);
        l_original    varchar2(400);
        l_idioma      varchar2(10);
        l_data_txt    varchar2(10);
        l_runtime     number;
        l_temporadas  number;
        l_episodios   number;
        l_ult_temp    number;
        l_ult_ep_dur  number;
        l_ep_run_time number;
        l_nota        number;
        l_votos       number;
        l_sinopse     clob;
        l_sin_idioma  varchar2(10) := 'pt-BR';
        l_poster      varchar2(200);
        l_fundo       varchar2(200);
        l_class       varchar2(10);
        l_trailer     varchar2(40);
        l_trailer_id  varchar2(8);
        l_duracao     number;
        l_resp_temp   MMM_PKG_HTTP.t_resposta;
        l_temp_corpo  clob;
        l_wp          clob;
        l_extras      clob;
        l_id_saga     number;
        l_saga_nome   varchar2(400);
        l_pessoas     varchar2(4000);
        l_recomendacoes varchar2(4000);
    begin
        select coalesce(jt.TITLE, jt.NAME),
               coalesce(jt.ORIGINAL_TITLE, jt.ORIGINAL_NAME),
               jt.ORIGINAL_LANGUAGE,
               coalesce(jt.RELEASE_DATE, jt.FIRST_AIR_DATE),
               jt.RUNTIME, jt.NUMBER_OF_SEASONS, jt.NUMBER_OF_EPISODES,
               jt.LAST_SEASON, jt.LAST_RUNTIME, jt.EPISODE_RUN_TIME,
               jt.VOTE_AVERAGE, jt.VOTE_COUNT,
               jt.OVERVIEW, jt.POSTER_PATH, jt.BACKDROP_PATH
          into l_titulo, l_original, l_idioma, l_data_txt,
               l_runtime, l_temporadas, l_episodios,
               l_ult_temp, l_ult_ep_dur, l_ep_run_time,
               l_nota, l_votos,
               l_sinopse, l_poster, l_fundo
          from json_table(p_corpo, '$' columns (
                   TITLE              varchar2(400) path '$.title',
                   NAME               varchar2(400) path '$.name',
                   ORIGINAL_TITLE     varchar2(400) path '$.original_title',
                   ORIGINAL_NAME      varchar2(400) path '$.original_name',
                   ORIGINAL_LANGUAGE  varchar2(10)  path '$.original_language',
                   RELEASE_DATE       varchar2(10)  path '$.release_date',
                   FIRST_AIR_DATE     varchar2(10)  path '$.first_air_date',
                   RUNTIME            number        path '$.runtime',
                   NUMBER_OF_SEASONS  number        path '$.number_of_seasons',
                   NUMBER_OF_EPISODES number        path '$.number_of_episodes',
                   LAST_SEASON        number        path '$.last_episode_to_air.season_number',
                   LAST_RUNTIME       number        path '$.last_episode_to_air.runtime',
                   EPISODE_RUN_TIME   number        path '$.episode_run_time[0]',
                   VOTE_AVERAGE       number        path '$.vote_average',
                   VOTE_COUNT         number        path '$.vote_count',
                   OVERVIEW           clob          path '$.overview',
                   POSTER_PATH        varchar2(200) path '$.poster_path',
                   BACKDROP_PATH      varchar2(200) path '$.backdrop_path')) jt;

        -- sinopse pt-BR vazia: a API nao faz fallback, entao escolhe entre as traducoes ja recebidas
        if nvl(dbms_lob.getlength(l_sinopse), 0) = 0 then
            begin
                select x.OVERVIEW, x.IDIOMA
                  into l_sinopse, l_sin_idioma
                  from (select jt.OVERVIEW,
                               case when jt.PAIS is not null then jt.LINGUA || '-' || jt.PAIS else jt.LINGUA end as IDIOMA,
                               case
                                   when jt.LINGUA = 'pt' and jt.PAIS = 'BR' then 1
                                   when jt.LINGUA = 'pt'                    then 2
                                   when jt.LINGUA = 'en' and jt.PAIS = 'US' then 3
                                   when jt.LINGUA = 'en'                    then 4
                                   when jt.LINGUA = l_idioma                then 5
                                   else 9
                               end as PRIORIDADE
                          from json_table(p_corpo, '$.translations.translations[*]' columns (
                                   LINGUA   varchar2(5) path '$.iso_639_1',
                                   PAIS     varchar2(5) path '$.iso_3166_1',
                                   OVERVIEW clob        path '$.data.overview')) jt
                         where dbms_lob.getlength(jt.OVERVIEW) > 0) x
                 where x.PRIORIDADE < 9
                 order by x.PRIORIDADE
                 fetch first 1 row only;
            exception
                when no_data_found then
                    l_sinopse    := null;
                    l_sin_idioma := null;
            end;
        end if;

        -- o TMDB traz mais de uma classificacao BR por titulo: fica a mais restritiva, com L, AL e LIVRE
        -- valendo 0 e valor fora da lista sem concorrer. Com max de texto, L vencia 14 e a serie passava no Tem crianca
        if p_tipo = 'FILME' then
            select max(jt.CERTIFICACAO) keep (dense_rank last order by
                       case when upper(trim(jt.CERTIFICACAO)) in ('L', 'AL', 'LIVRE') then 0
                            else to_number(jt.CERTIFICACAO default null on conversion error) end nulls first)
              into l_class
              from json_table(p_corpo, '$.release_dates.results[*]' columns (
                       PAIS varchar2(5) path '$.iso_3166_1',
                       nested path '$.release_dates[*]' columns (
                           CERTIFICACAO varchar2(10) path '$.certification'))) jt
             where jt.PAIS = 'BR'
               and jt.CERTIFICACAO is not null;
        else
            select max(jt.RATING) keep (dense_rank last order by
                       case when upper(trim(jt.RATING)) in ('L', 'AL', 'LIVRE') then 0
                            else to_number(jt.RATING default null on conversion error) end nulls first)
              into l_class
              from json_table(p_corpo, '$.content_ratings.results[*]' columns (
                       PAIS   varchar2(5)  path '$.iso_3166_1',
                       RATING varchar2(10) path '$.rating')) jt
             where jt.PAIS = 'BR'
               and jt.RATING is not null;
        end if;

        -- ordem: Trailer, Teaser; pt antes de en; oficial desempata
        begin
            select x.CHAVE, x.LINGUA
              into l_trailer, l_trailer_id
              from (select jt.CHAVE,
                           jt.LINGUA,
                           case jt.TIPO_VIDEO when 'Trailer' then 0 when 'Teaser' then 1 else 2 end
                           + case jt.LINGUA when 'pt' then 0 else 10 end
                           - case jt.OFICIAL when 'true' then 0.5 else 0 end as ORDEM
                      from json_table(p_corpo, '$.videos.results[*]' columns (
                               CHAVE      varchar2(40) path '$.key',
                               SITE       varchar2(20) path '$.site',
                               TIPO_VIDEO varchar2(20) path '$.type',
                               LINGUA     varchar2(5)  path '$.iso_639_1',
                               OFICIAL    varchar2(5)  path '$.official')) jt
                     where jt.SITE = 'YouTube') x
             order by x.ORDEM
             fetch first 1 row only;
        exception
            when no_data_found then
                l_trailer    := null;
                l_trailer_id := null;
        end;

        l_duracao := nullif(l_runtime, 0);
        if p_tipo = 'SERIE' then
            -- a duracao do ultimo episodio engana (final de temporada longo): mediana da ultima temporada
            l_duracao := null;
            if l_ult_temp is not null then
                l_resp_temp := MMM_PKG_HTTP.chamar(
                                   p_sistema    => 'TMDB',
                                   p_operacao   => 'TEMPORADA',
                                   p_caminho    => '/tv/' || p_id_tmdb || '/season/' || l_ult_temp || '?language=pt-BR',
                                   p_timeout    => case when p_interativo then 5 else 15 end,
                                   p_tentativas => 1,
                                   p_id_titulo  => p_id_titulo);
                if l_resp_temp.resultado = 'OK' then
                    l_temp_corpo := l_resp_temp.corpo;
                    select round(median(jt.RUNTIME))
                      into l_duracao
                      from json_table(l_temp_corpo, '$.episodes[*]' columns (RUNTIME number path '$.runtime')) jt
                     where jt.RUNTIME > 0;
                end if;
            end if;
            l_duracao := coalesce(l_duracao, nullif(l_ult_ep_dur, 0), nullif(l_ep_run_time, 0));
        end if;

        -- classificacao_br e privada do body e nao pode ir dentro do update (PLS-00231)
        l_class := classificacao_br(l_class);

        -- Faz parte da saga e Mais com, na ficha: saga do filme e pessoas, da mesma resposta. [] = lido e sem ninguem
        -- (o job de reposicao so procura quem ficou nulo)
        l_extras := ler_extras(p_corpo, p_tipo);
        select json_value(l_extras, '$.saga.id' returning number),
               json_value(l_extras, '$.saga.nome' returning varchar2(400)),
               nvl(json_query(l_extras, '$.pessoas' returning varchar2(4000)), '[]')
          into l_id_saga, l_saga_nome, l_pessoas
          from dual;
        l_recomendacoes := ler_recomendacoes(p_corpo, p_tipo);

        update MMM_TITULO
           set SITUACAO           = 'OK',
               TITULO             = substr(nvl(l_titulo, TITULO), 1, 300),
               TITULO_ORIGINAL    = substr(l_original, 1, 300),
               ANO                = to_number(substr(l_data_txt, 1, 4) default null on conversion error),
               DURACAO_MIN        = l_duracao,
               TEMPORADAS         = case when p_tipo = 'SERIE' then l_temporadas end,
               EPISODIOS          = case when p_tipo = 'SERIE' then l_episodios end,
               IDIOMA_ORIGINAL    = substr(l_idioma, 1, 8),
               NOTA               = round(l_nota, 1),
               VOTOS              = l_votos,
               CLASSIFICACAO      = l_class,
               SINOPSE            = l_sinopse,
               SINOPSE_IDIOMA     = case when l_sinopse is not null then l_sin_idioma end,
               TRAILER_CHAVE      = l_trailer,
               TRAILER_IDIOMA     = l_trailer_id,
               POSTER_PATH        = l_poster,
               FUNDO_PATH         = l_fundo,
               ID_SAGA_TMDB       = l_id_saga,
               SAGA_NOME          = substr(l_saga_nome, 1, 300),
               PESSOAS_JSON       = l_pessoas,
               RECOMENDACOES_JSON = nvl(l_recomendacoes, RECOMENDACOES_JSON),
               SINCRONIZADO_EM    = l_agora,
               FALHAS_SEGUIDAS    = 0,
               ULTIMA_FALHA_EM    = null,
               ULTIMO_STATUS_HTTP = 200
         where ID_TITULO = p_id_titulo;

        gravar_generos(p_id_titulo, p_tipo, p_corpo, l_agora);

        select json_query(p_corpo, '$."watch/providers"' returning clob)
          into l_wp
          from dual;
        if l_wp is not null then
            gravar_provedores(p_id_titulo, l_wp, l_agora);
        end if;
    end aplicar_detalhes;

    procedure gravar_detalhes(p_id_titulo in number, p_corpo in clob) is
        l_tipo    MMM_TITULO.TIPO%type;
        l_id_tmdb MMM_TITULO.ID_TMDB%type;
    begin
        select TIPO, ID_TMDB
          into l_tipo, l_id_tmdb
          from MMM_TITULO
         where ID_TITULO = p_id_titulo;
        aplicar_detalhes(p_id_titulo, l_tipo, l_id_tmdb, p_corpo, p_interativo => false);
    end gravar_detalhes;

    function atualizar_titulo(p_id_titulo in number, p_interativo in boolean default false) return varchar2 is
        l_tipo    MMM_TITULO.TIPO%type;
        l_id_tmdb MMM_TITULO.ID_TMDB%type;
        l_ultimo  MMM_TITULO.ULTIMO_STATUS_HTTP%type;
        l_resp    MMM_PKG_HTTP.t_resposta;
    begin
        select TIPO, ID_TMDB, ULTIMO_STATUS_HTTP
          into l_tipo, l_id_tmdb, l_ultimo
          from MMM_TITULO
         where ID_TITULO = p_id_titulo;

        l_resp := baixar_detalhes(l_tipo, l_id_tmdb, p_interativo, p_id_titulo);

        if l_resp.status = 404 then
            -- dois 404 seguidos: o TMDB apagou ou fundiu o titulo; um so pode ser instabilidade
            if l_ultimo = 404 then
                delete from MMM_TITULO
                 where ID_TITULO = p_id_titulo;
                MMM_PKG_UTIL.log_app('TMDB_404_APAGADO', 1, l_tipo || ' ' || l_id_tmdb);
            else
                registrar_falha(p_id_titulo, 404);
            end if;
            return '404';
        elsif l_resp.status = 401 or l_resp.resultado in ('ACL', 'CERTIFICADO', 'CIRCUITO') then
            return 'PARAR';
        elsif l_resp.resultado <> 'OK' then
            registrar_falha(p_id_titulo, l_resp.status);
            return 'ERRO';
        end if;

        aplicar_detalhes(p_id_titulo, l_tipo, l_id_tmdb, l_resp.corpo, p_interativo);
        return 'OK';
    end atualizar_titulo;

    function atualizar_provedores(p_id_titulo in number, p_interativo in boolean default false) return varchar2 is
        l_tipo    MMM_TITULO.TIPO%type;
        l_id_tmdb MMM_TITULO.ID_TMDB%type;
        l_resp    MMM_PKG_HTTP.t_resposta;
    begin
        select TIPO, ID_TMDB
          into l_tipo, l_id_tmdb
          from MMM_TITULO
         where ID_TITULO = p_id_titulo;

        l_resp := MMM_PKG_HTTP.chamar(
                      p_sistema    => 'TMDB',
                      p_operacao   => 'PROVEDORES',
                      p_caminho    => '/' || rota(l_tipo) || '/' || l_id_tmdb || '/watch/providers',
                      p_timeout    => case when p_interativo then 4 else 15 end,
                      p_tentativas => case when p_interativo then 1 else 2 end,
                      p_espera_max => case when p_interativo then 2 else 10 end,
                      p_id_titulo  => p_id_titulo);

        if l_resp.status = 401 or l_resp.resultado in ('ACL', 'CERTIFICADO', 'CIRCUITO') then
            return 'PARAR';
        elsif l_resp.resultado <> 'OK' then
            return 'ERRO';
        end if;
        gravar_provedores(p_id_titulo, l_resp.corpo, systimestamp);
        return 'OK';
    end atualizar_provedores;

    procedure acordar_job_completar is
    begin
        -- roda o job em segundo plano agora; se ja estiver rodando, o ciclo de 10 minutos pega o resto.
        -- run_job com use_current_session => false faz commit implicito e desfaz savepoints: chamar so como
        -- ultimo passo do request, depois de o titulo entrar na lista
        dbms_scheduler.run_job(job_name => c_job_completar, use_current_session => false);
    exception
        when others then
            null;
    end acordar_job_completar;

    -- demo publica: o visitante anonimo nao usa a chave do TMDB nem enche o cache sem teto
    procedure conferir_teto_demo is
        l_hora number;
    begin
        if nvl(sys_context('APEX$SESSION', 'APP_USER'), '-') not like 'VISITANTE-%' then
            return;
        end if;
        -- a visita e a sessao APEX do visitante: sem senha, ele nao volta noutra sessao
        if MMM_PKG_HTTP.chamadas_da_sessao('TMDB', 1440) >= c_teto_visita_tmdb then
            raise_application_error(-20614, 'Na demonstração dá para buscar e adicionar até ' || c_teto_visita_tmdb || ' vezes.');
        end if;
        select count(*)
          into l_hora
          from MMM_INTEGRACAO_LOG
         where SISTEMA    = 'TMDB'
           and FL_ENVIADO = 'S'
           and CRIADO_POR like 'VISITANTE-%'
           and CRIADO_EM  > systimestamp - interval '1' hour;
        if l_hora >= c_teto_demo_hora then
            raise_application_error(-20614, 'A demonstração está cheia agora. Tente de novo em alguns minutos.');
        end if;
    end conferir_teto_demo;

    procedure reservar_demo(p_qtd in pls_integer) is
        l_sessao number := to_number(v('APP_SESSION'));
        l_hora   number;
    begin
        if nvl(p_qtd, 0) <= 0 or nvl(sys_context('APEX$SESSION', 'APP_USER'), '-') not like 'VISITANTE-%' then
            return;
        end if;
        if MMM_PKG_HTTP.chamadas_da_sessao('TMDB', 1440) + p_qtd > c_teto_visita_tmdb then
            raise_application_error(-20614, 'Na demonstração dá para buscar e adicionar até ' || c_teto_visita_tmdb || ' vezes.');
        end if;
        select count(*)
          into l_hora
          from MMM_INTEGRACAO_LOG
         where SISTEMA    = 'TMDB'
           and FL_ENVIADO = 'S'
           and CRIADO_POR like 'VISITANTE-%'
           and CRIADO_EM  > systimestamp - interval '1' hour;
        if l_hora + p_qtd > c_teto_demo_hora then
            raise_application_error(-20614, 'A demonstração está cheia agora. Tente de novo em alguns minutos.');
        end if;
        -- o job busca essas partes no TMDB fora da sessao: a visita paga por elas aqui, uma linha por chamada
        insert into MMM_INTEGRACAO_LOG (SISTEMA, OPERACAO, FL_ENVIADO, RESULTADO, SESSAO_APEX, MENSAGEM)
        select 'TMDB', 'RESERVA_DEMO', 'S', 'RESERVA', l_sessao, 'parte de saga que o MMM_JOB_COMPLETAR vai buscar'
          from dual
        connect by level <= p_qtd;
    end reservar_demo;

    -- a busca roda a cada letra: um laco no navegador nao gasta a cota do TMDB
    procedure conferir_ritmo is
    begin
        if MMM_PKG_HTTP.chamadas_da_sessao('TMDB', 1) >= c_teto_minuto_sessao then
            raise_application_error(-20613, 'Muitas buscas seguidas. Espere alguns segundos.');
        end if;
    end conferir_ritmo;

    -- a colecao pode nao existir ainda (saga aberta pela ficha, antes de qualquer busca)
    procedure limpar(p_origem in varchar2) is
    begin
        if not apex_collection.collection_exists(p_collection_name => c_colecao_busca) then
            apex_collection.create_collection(p_collection_name => c_colecao_busca);
        else
            apex_collection.delete_members(p_collection_name => c_colecao_busca, p_attr_number => 5, p_attr_value => p_origem);
        end if;
    end limpar;

    -- titulos lidos (busca, pessoa ou saga) na colecao da sessao, de uma vez:
    -- c001 tipo, c002 titulo, c003 original, c004 poster_path, c005 origem (BUSCA, PESSOA, SAGA), c006 papel,
    -- c007 estreia, c008 lancado (S/N), n001 id do TMDB, n002 ano, n003 pessoa ou saga, n004 ordem, d001 lancamento
    procedure guardar(p_itens in clob, p_origem in varchar2, p_id in number) is
        l_c001 dbms_sql.varchar2a;
        l_c002 dbms_sql.varchar2a;
        l_c003 dbms_sql.varchar2a;
        l_c004 dbms_sql.varchar2a;
        l_c005 dbms_sql.varchar2a;
        l_c006 dbms_sql.varchar2a;
        l_c007 dbms_sql.varchar2a;
        l_c008 dbms_sql.varchar2a;
        l_n001 apex_application_global.n_arr;
        l_n002 apex_application_global.n_arr;
        l_n003 apex_application_global.n_arr;
        l_n004 apex_application_global.n_arr;
        l_d001 apex_application_global.d_arr;
    begin
        if p_itens is null then
            return;
        end if;
        select jt.TIPO,
               jt.TITULO,
               jt.ORIGINAL,
               jt.POSTER_PATH,
               p_origem,
               jt.PAPEL,
               jt.ESTREIA,
               case jt.LANCADO when 'true' then 'S' when 'false' then 'N' end,
               jt.ID_TMDB,
               jt.ANO,
               p_id,
               jt.ORDEM,
               to_date(jt.DATA default null on conversion error, 'YYYY-MM-DD')
          bulk collect into l_c001, l_c002, l_c003, l_c004, l_c005, l_c006, l_c007, l_c008, l_n001, l_n002, l_n003, l_n004, l_d001
          from json_table(p_itens, '$[*]' columns (
                   ORDEM       for ordinality,
                   TIPO        varchar2(5)   path '$.tipo',
                   ID_TMDB     number        path '$.idTmdb',
                   TITULO      varchar2(400) path '$.titulo',
                   ORIGINAL    varchar2(400) path '$.original',
                   ANO         number        path '$.ano',
                   DATA        varchar2(10)  path '$.data',
                   POSTER_PATH varchar2(200) path '$.posterPath',
                   PAPEL       varchar2(400) path '$.papel',
                   ESTREIA     varchar2(60)  path '$.estreia',
                   LANCADO     varchar2(5)   path '$.lancado')) jt
         where jt.TIPO in ('FILME', 'SERIE')
           and jt.ID_TMDB is not null
           and jt.TITULO is not null;
        if l_c001.count > 0 then
            apex_collection.add_members(
                p_collection_name => c_colecao_busca,
                p_c001            => l_c001,
                p_c002            => l_c002,
                p_c003            => l_c003,
                p_c004            => l_c004,
                p_c005            => l_c005,
                p_c006            => l_c006,
                p_c007            => l_c007,
                p_c008            => l_c008,
                p_n001            => l_n001,
                p_n002            => l_n002,
                p_n003            => l_n003,
                p_n004            => l_n004,
                p_d001            => l_d001);
        end if;
    end guardar;

    -- o que a colecao da sessao tem de uma origem, com as marcas do grupo ativo (MMM_V_BUSCA_SESSAO passa pelo VPD)
    function itens_marcados(p_origem in varchar2, p_id in number, p_tipo in varchar2 default null) return clob is
        l_json clob;
    begin
        select json_arrayagg(
                   json_object(
                       'tipo'       value v.TIPO,
                       'idTmdb'     value v.ID_TMDB,
                       'titulo'     value v.TITULO,
                       'ano'        value v.ANO,
                       'posterPath' value v.POSTER_PATH,
                       'papel'      value v.PAPEL,
                       'estreia'    value v.ESTREIA,
                       'lancado'    value case v.FL_LANCADO when 'S' then 'true' when 'N' then 'false' end format json,
                       'naLista'    value case v.FL_NA_LISTA when 'S' then 'true' else 'false' end format json,
                       'jaVisto'    value case v.FL_JA_VISTO when 'S' then 'true' else 'false' end format json
                       absent on null returning clob)
                   order by v.ORDEM returning clob)
          into l_json
          from MMM_V_BUSCA_SESSAO v
         where v.ORIGEM = p_origem
           and (p_id is null or v.ID_ORIGEM = p_id)
           and (p_tipo is null or v.TIPO = p_tipo);
        return nvl(l_json, to_clob('[]'));
    end itens_marcados;

    -- usa o que a busca desta sessao trouxe, quando os detalhes nao vieram na hora
    function criar_da_busca(p_tipo in varchar2, p_id_tmdb in number) return number is
        l_id     number;
        l_titulo varchar2(400);
        l_orig   varchar2(400);
        l_ano    number;
        l_poster varchar2(200);
    begin
        select max(c.C002), max(c.C003), max(c.N002), max(c.C004)
          into l_titulo, l_orig, l_ano, l_poster
          from APEX_COLLECTIONS c
         where c.COLLECTION_NAME = c_colecao_busca
           and c.C001            = p_tipo
           and c.N001            = p_id_tmdb;
        if l_titulo is null then
            return null;
        end if;

        insert into MMM_TITULO (TIPO, ID_TMDB, SITUACAO, TITULO, TITULO_ORIGINAL, ANO, POSTER_PATH, SINCRONIZADO_EM)
        values (p_tipo, p_id_tmdb, 'PENDENTE', substr(l_titulo, 1, 300), substr(l_orig, 1, 300), l_ano, l_poster, systimestamp)
        returning ID_TITULO into l_id;
        -- o job e acordado por MMM_PKG_LISTA.adicionar no fim do request: o run_job comita
        return l_id;
    end criar_da_busca;

    function garantir_titulo(p_tipo in varchar2, p_id_tmdb in number) return number is
        l_id       MMM_TITULO.ID_TITULO%type;
        l_situacao MMM_TITULO.SITUACAO%type;
        l_resp     MMM_PKG_HTTP.t_resposta;
        l_titulo   varchar2(400);
        l_res      varchar2(10);
    begin
        if p_tipo is null or p_tipo not in ('FILME', 'SERIE') or p_id_tmdb is null then
            raise_application_error(-20610, 'Título inválido.');
        end if;

        begin
            select ID_TITULO, SITUACAO
              into l_id, l_situacao
              from MMM_TITULO
             where TIPO    = p_tipo
               and ID_TMDB = p_id_tmdb;
            if l_situacao = 'PENDENTE' then
                conferir_teto_demo;
                l_res := atualizar_titulo(l_id, p_interativo => true);  -- melhor esforco; o job completa depois
            end if;
            return l_id;
        exception
            when no_data_found then
                null;
        end;

        conferir_teto_demo;
        l_resp := baixar_detalhes(p_tipo, p_id_tmdb, true, null);
        if l_resp.status = 404 then
            raise_application_error(-20611, 'Esse título não existe mais no TMDB.');
        elsif l_resp.resultado = 'OK' then
            select coalesce(json_value(l_resp.corpo, '$.title'), json_value(l_resp.corpo, '$.name'))
              into l_titulo
              from dual;
            begin
                insert into MMM_TITULO (TIPO, ID_TMDB, SITUACAO, TITULO, SINCRONIZADO_EM)
                values (p_tipo, p_id_tmdb, 'PENDENTE', substr(nvl(l_titulo, '?'), 1, 300), systimestamp)
                returning ID_TITULO into l_id;
            exception
                when dup_val_on_index then
                    -- outra pessoa adicionou o mesmo titulo no mesmo instante
                    select ID_TITULO
                      into l_id
                      from MMM_TITULO
                     where TIPO    = p_tipo
                       and ID_TMDB = p_id_tmdb;
                    return l_id;
            end;
            aplicar_detalhes(l_id, p_tipo, p_id_tmdb, l_resp.corpo, true);
            return l_id;
        end if;

        l_id := criar_da_busca(p_tipo, p_id_tmdb);
        if l_id is null then
            raise_application_error(-20612, 'O TMDB não respondeu agora. Tente de novo em instantes.');
        end if;
        return l_id;
    end garantir_titulo;

    function titulo_da_ficha(p_tipo in varchar2, p_id_tmdb in number) return number is
        l_situacao MMM_TITULO.SITUACAO%type;
    begin
        if p_tipo is null or p_tipo not in ('FILME', 'SERIE') or p_id_tmdb is null then
            raise_application_error(-20610, 'Título inválido.');
        end if;
        -- so o titulo que vai ao TMDB conta no limite da sessao: os que o catalogo ja tem abrem sem rede
        select max(SITUACAO)
          into l_situacao
          from MMM_TITULO
         where TIPO    = p_tipo
           and ID_TMDB = p_id_tmdb;
        if nvl(l_situacao, 'PENDENTE') = 'PENDENTE' then
            conferir_ritmo;
        end if;
        return garantir_titulo(p_tipo, p_id_tmdb);
    end titulo_da_ficha;

    function titulo_da_sessao(p_tipo in varchar2, p_id_tmdb in number) return number is
        l_id MMM_TITULO.ID_TITULO%type;
    begin
        if p_tipo is null or p_tipo not in ('FILME', 'SERIE') or p_id_tmdb is null then
            raise_application_error(-20610, 'Título inválido.');
        end if;
        begin
            select ID_TITULO
              into l_id
              from MMM_TITULO
             where TIPO    = p_tipo
               and ID_TMDB = p_id_tmdb;
            return l_id;
        exception
            when no_data_found then
                null;
        end;
        begin
            l_id := criar_da_busca(p_tipo, p_id_tmdb);
        exception
            when dup_val_on_index then
                -- outra pessoa adicionou o mesmo titulo no mesmo instante
                select ID_TITULO
                  into l_id
                  from MMM_TITULO
                 where TIPO    = p_tipo
                   and ID_TMDB = p_id_tmdb;
        end;
        if l_id is null then
            raise_application_error(-20613, 'Busque o título de novo para adicionar.');
        end if;
        return l_id;
    end titulo_da_sessao;

    function montar_busca(p_multi in clob, p_colecoes in clob, p_ano in number default null, p_termo in varchar2 default null) return clob is
        l_lido    clob := ler_busca(p_multi, p_colecoes, p_ano, p_termo => p_termo);
        l_itens   clob;
        l_pessoas clob;
        l_sagas   clob;
        l_ano     number;
        l_filtrou varchar2(5);
        l_json    clob;
    begin
        select json_query(l_lido, '$.itens' returning clob),
               json_query(l_lido, '$.pessoas' returning clob),
               json_query(l_lido, '$.sagas' returning clob),
               json_value(l_lido, '$.ano' returning number),
               json_value(l_lido, '$.filtrouAno')
          into l_itens, l_pessoas, l_sagas, l_ano, l_filtrou
          from dual;

        -- guarda o resultado na sessao: se os detalhes falharem ao adicionar, o titulo nasce com estes dados. A busca nova
        -- troca so os titulos da busca; a pessoa e a saga abertas continuam valendo
        limpar('BUSCA');
        guardar(l_itens, 'BUSCA', null);
        l_itens := itens_marcados('BUSCA', null);

        select json_object(
                   'ok'         value 'true' format json,
                   'itens'      value l_itens format json,
                   'pessoas'    value l_pessoas format json,
                   'sagas'      value l_sagas format json,
                   'ano'        value l_ano,
                   'filtrouAno' value l_filtrou format json
                   absent on null returning clob)
          into l_json
          from dual;
        return l_json;
    end montar_busca;

    function montar_pessoa(p_id_pessoa in number, p_creditos in clob) return clob is
        l_lido   clob := ler_pessoa(p_creditos);
        l_filmes clob;
        l_series clob;
        l_tf     number;
        l_ts     number;
        l_json   clob;
    begin
        select json_query(l_lido, '$.filmes' returning clob),
               json_query(l_lido, '$.series' returning clob),
               json_value(l_lido, '$.totalFilmes' returning number),
               json_value(l_lido, '$.totalSeries' returning number)
          into l_filmes, l_series, l_tf, l_ts
          from dual;

        -- a pessoa nova toma o lugar da anterior; a busca e a saga continuam na sessao
        limpar('PESSOA');
        guardar(l_filmes, 'PESSOA', p_id_pessoa);
        guardar(l_series, 'PESSOA', p_id_pessoa);
        l_filmes := itens_marcados('PESSOA', p_id_pessoa, 'FILME');
        l_series := itens_marcados('PESSOA', p_id_pessoa, 'SERIE');

        select json_object(
                   'ok'          value 'true' format json,
                   'id'          value p_id_pessoa,
                   'filmes'      value l_filmes format json,
                   'series'      value l_series format json,
                   'totalFilmes' value l_tf,
                   'totalSeries' value l_ts
                   returning clob)
          into l_json
          from dual;
        return l_json;
    end montar_pessoa;

    function saga_da_sessao_json(p_id_saga in number) return clob is
        l_partes clob := itens_marcados('SAGA', p_id_saga);
        l_qtd    number;
        l_json   clob;
    begin
        -- quantas entram no Adicionar a saga inteira: ja lancadas, fora da lista e nunca vistas
        select count(*)
          into l_qtd
          from MMM_V_BUSCA_SESSAO v
         where v.ORIGEM         = 'SAGA'
           and v.ID_ORIGEM      = p_id_saga
           and v.FL_ADICIONAVEL = 'S';
        select json_object(
                   'ok'           value 'true' format json,
                   'id'           value p_id_saga,
                   'partes'       value l_partes format json,
                   'adicionaveis' value l_qtd
                   returning clob)
          into l_json
          from dual;
        return l_json;
    end saga_da_sessao_json;

    function montar_saga(p_id_saga in number, p_colecao in clob) return clob is
        l_lido   clob := ler_saga(p_colecao);
        l_partes clob;
        l_nome   varchar2(400);
        l_poster varchar2(200);
        l_json   clob;
    begin
        select json_query(l_lido, '$.partes' returning clob),
               json_value(l_lido, '$.nome' returning varchar2(400)),
               json_value(l_lido, '$.posterPath' returning varchar2(200))
          into l_partes, l_nome, l_poster
          from dual;

        -- a saga nova toma o lugar da anterior; a busca e a pessoa continuam na sessao
        limpar('SAGA');
        guardar(l_partes, 'SAGA', p_id_saga);

        l_json := saga_da_sessao_json(p_id_saga);
        select json_mergepatch(l_json,
                               json_object('nome' value l_nome, 'posterPath' value l_poster absent on null)
                               returning clob)
          into l_json
          from dual;
        return l_json;
    end montar_saga;

    function buscar_json(p_termo in varchar2) return clob is
        l_ano      number;
        l_termo    varchar2(100);
        l_resp     MMM_PKG_HTTP.t_resposta;
        l_multi    clob;
        l_colecoes clob;

        -- a segunda chamada (sagas) tambem conta no teto: sem vaga, a busca segue sem as sagas
        function cabe_mais_uma return boolean is
        begin
            conferir_teto_demo;
            conferir_ritmo;
            return true;
        exception
            when others then
                if sqlcode in (-20613, -20614) then
                    return false;
                end if;
                raise;
        end cabe_mais_uma;
    begin
        -- "duna 2021" e "o rei leao (2019)": o ano sai da consulta e vira filtro dos titulos
        l_termo := substr(separar_ano(substr(trim(p_termo), 1, 100), l_ano), 1, 100);
        if l_termo is null or length(l_termo) < 2 then
            return to_clob('{"ok":true,"itens":[]}');
        end if;
        conferir_teto_demo;
        conferir_ritmo;

        -- uma tentativa de ate 4 s: a busca roda dentro do AJAX e segura uma vaga HTTP da ATP
        l_resp := MMM_PKG_HTTP.chamar(
                      p_sistema    => 'TMDB',
                      p_operacao   => 'BUSCA',
                      p_caminho    => '/search/multi?query=' || MMM_PKG_HTTP.escapar(l_termo)
                                      || '&language=pt-BR&include_adult=false&page=1',
                      p_timeout    => 4,
                      p_tentativas => 1);
        if l_resp.resultado <> 'OK' then
            raise_application_error(-20612, 'A busca no TMDB não respondeu. Tente de novo.');
        end if;
        l_multi := l_resp.corpo;

        -- sagas nao vem no multi: /search/collection, uma chamada a mais com a mesma regra; sem resposta, a busca segue
        -- sem elas
        if cabe_mais_uma then
            l_resp := MMM_PKG_HTTP.chamar(
                          p_sistema    => 'TMDB',
                          p_operacao   => 'BUSCA_SAGA',
                          p_caminho    => '/search/collection?query=' || MMM_PKG_HTTP.escapar(l_termo)
                                          || '&language=pt-BR&include_adult=false&page=1',
                          -- as sagas sao extra: com o TMDB lento a busca sai sem elas em vez de segurar a vaga HTTP
                          p_timeout    => 2,
                          p_tentativas => 1);
            if l_resp.resultado = 'OK' then
                l_colecoes := l_resp.corpo;
            end if;
        end if;

        return montar_busca(l_multi, l_colecoes, l_ano, l_termo);
    end buscar_json;

    function pessoa_json(p_id_pessoa in number) return clob is
        l_resp MMM_PKG_HTTP.t_resposta;
    begin
        if p_id_pessoa is null or p_id_pessoa <> trunc(p_id_pessoa) or p_id_pessoa not between 1 and 9999999999 then
            raise_application_error(-20610, 'Pessoa inválida.');
        end if;
        conferir_teto_demo;
        conferir_ritmo;
        -- atuou e dirigiu numa chamada so (o discover mistura todas as funcoes da equipe); a resposta pode passar de
        -- 100 KB, dai os 5 s, uma tentativa como o resto da tela
        l_resp := MMM_PKG_HTTP.chamar(
                      p_sistema    => 'TMDB',
                      p_operacao   => 'PESSOA',
                      p_caminho    => '/person/' || p_id_pessoa || '/combined_credits?language=pt-BR',
                      p_timeout    => 5,
                      p_tentativas => 1);
        if l_resp.status = 404 then
            raise_application_error(-20611, 'Essa pessoa não está mais no TMDB.');
        elsif l_resp.resultado <> 'OK' then
            raise_application_error(-20612, 'O TMDB não respondeu agora. Tente de novo em instantes.');
        end if;
        return montar_pessoa(p_id_pessoa, l_resp.corpo);
    end pessoa_json;

    function saga_json(p_id_saga in number) return clob is
        l_resp MMM_PKG_HTTP.t_resposta;
    begin
        if p_id_saga is null or p_id_saga <> trunc(p_id_saga) or p_id_saga not between 1 and 9999999999 then
            raise_application_error(-20610, 'Saga inválida.');
        end if;
        conferir_teto_demo;
        conferir_ritmo;
        l_resp := MMM_PKG_HTTP.chamar(
                      p_sistema    => 'TMDB',
                      p_operacao   => 'SAGA',
                      p_caminho    => '/collection/' || p_id_saga || '?language=pt-BR',
                      p_timeout    => 4,
                      p_tentativas => 1);
        if l_resp.status = 404 then
            raise_application_error(-20611, 'Essa saga não está mais no TMDB.');
        elsif l_resp.resultado <> 'OK' then
            raise_application_error(-20612, 'O TMDB não respondeu agora. Tente de novo em instantes.');
        end if;
        return montar_saga(p_id_saga, l_resp.corpo);
    end saga_json;

    function reconhecer_nota(p_texto in varchar2, p_continuar in varchar2 default 'N') return clob is
        c_max_linhas constant pls_integer := 30;
        l_linhas   apex_t_varchar2;
        l_vistas   apex_t_varchar2 := apex_t_varchar2();
        l_linha    varchar2(400);
        l_consulta varchar2(400);
        l_norm     varchar2(400);
        l_ano      number;
        l_dica     varchar2(5);
        l_resp     MMM_PKG_HTTP.t_resposta;
        l_corpo    clob;
        l_cand     clob;
        l_melhor   number;
        l_segundo  number;
        l_tipo1    varchar2(5);
        l_id1      number;
        l_status   varchar2(15);
        l_inicio   timestamp with time zone := systimestamp;
        l_qtd      pls_integer := 0;
        l_saida    clob;

        -- o teto da demo conta chamadas, nao notas: sem conferir a cada linha uma nota passaria do teto
        function cabe_no_teto_demo return boolean is
        begin
            conferir_teto_demo;
            return true;
        exception
            when others then
                if sqlcode = -20614 then
                    return false;
                end if;
                raise;
        end cabe_no_teto_demo;
    begin
        conferir_teto_demo;
        -- continuar: so as linhas que o corte deixou para tras (sempre o fim da nota). Recomecar da linha 1
        -- gastaria o mesmo tempo nas mesmas linhas e cortaria no mesmo ponto
        if p_continuar = 'S' then
            select c.C001
              bulk collect into l_linhas
              from APEX_COLLECTIONS c
             where c.COLLECTION_NAME = c_colecao_nota
               and c.C002            = 'NAO_PROCESSADA'
             order by c.SEQ_ID;
            if l_linhas.count > 0 then
                apex_collection.delete_members(
                    p_collection_name => c_colecao_nota,
                    p_attr_number     => 2,
                    p_attr_value      => 'NAO_PROCESSADA');
            end if;
        else
            apex_collection.create_or_truncate_collection(p_collection_name => c_colecao_nota);
            l_linhas := apex_string.split(p_texto);  -- sem separador: uma entrada por linha
        end if;

        for i in 1 .. l_linhas.count loop
            l_linha := substr(trim(replace(l_linhas(i), chr(13))), 1, 200);
            continue when l_linha is null;
            exit when l_qtd >= c_max_linhas;

            -- tira marcador de lista: "- ", "* ", "1. ", "[ ]", "[x]"
            l_consulta := regexp_replace(l_linha, '^\s*(\[[ xX]?\]|[-*>•·]+|[0-9]+[.)])\s*', '');

            -- ano so entre parenteses: "1917" e "2012" sao titulos
            l_ano      := to_number(regexp_substr(l_consulta, '\(((19|20)[0-9]{2})\)', 1, 1, null, 1));
            l_consulta := regexp_replace(l_consulta, '\(((19|20)[0-9]{2})\)', ' ');

            l_dica := null;
            if regexp_like(l_consulta, '\((s[ée]rie|filme)\)', 'i') then
                l_dica     := case when regexp_like(l_consulta, '\(filme\)', 'i') then 'FILME' else 'SERIE' end;
                l_consulta := regexp_replace(l_consulta, '\((s[ée]rie|filme)\)', ' ', 1, 0, 'i');
            end if;
            -- "Reacher T2", "The Bear S03", "Sintonia 2a temporada"
            if regexp_like(l_consulta, '\s(s[0-9]{1,2}(e[0-9]{1,2})?|t[0-9]{1,2}|[0-9]{1,2}[aª]? ?temporada|temporada ?[0-9]{0,2})\s*$', 'i') then
                l_dica     := 'SERIE';
                l_consulta := regexp_replace(l_consulta, '\s(s[0-9]{1,2}(e[0-9]{1,2})?|t[0-9]{1,2}|[0-9]{1,2}[aª]? ?temporada|temporada ?[0-9]{0,2})\s*$', '', 1, 0, 'i');
            end if;
            l_consulta := trim(l_consulta);
            l_norm     := normalizar(l_consulta);
            continue when l_norm is null or l_norm member of l_vistas;

            l_vistas.extend;
            l_vistas(l_vistas.count) := l_norm;
            l_qtd     := l_qtd + 1;
            l_cand    := null;
            l_melhor  := null;
            l_segundo := null;
            l_tipo1   := null;
            l_id1     := null;

            -- corte de 6 s: o pedido devolve logo a vaga HTTP e a tela pede a continuacao.
            -- Linha alem do teto da demo tambem fica para a continuacao, que recusa com a mensagem do teto
            if systimestamp - l_inicio > interval '6' second or not cabe_no_teto_demo then
                l_status := 'NAO_PROCESSADA';
            else
                l_resp := MMM_PKG_HTTP.chamar(
                              p_sistema    => 'TMDB',
                              p_operacao   => 'NOTA',
                              p_caminho    => '/search/multi?query=' || MMM_PKG_HTTP.escapar(l_consulta)
                                              || '&language=pt-BR&include_adult=false&page=1',
                              p_timeout    => 4,
                              p_tentativas => 1);
                if l_resp.resultado <> 'OK' then
                    l_status := 'ERRO';
                else
                    l_corpo := l_resp.corpo;
                    select json_arrayagg(
                               json_object(
                                   'tipo'       value x.TIPO,
                                   'idTmdb'     value x.ID_TMDB,
                                   'titulo'     value x.TITULO,
                                   'original'   value x.ORIGINAL,
                                   'ano'        value x.ANO,
                                   'posterPath' value x.POSTER_PATH)
                               order by x.RN returning clob),
                           max(case when x.RN = 1 then x.PONTOS end),
                           max(case when x.RN = 2 then x.PONTOS end),
                           max(case when x.RN = 1 then x.TIPO end),
                           max(case when x.RN = 1 then x.ID_TMDB end)
                      into l_cand, l_melhor, l_segundo, l_tipo1, l_id1
                      from (select y.*,
                                   row_number() over (order by y.PONTOS desc, y.POPULARIDADE desc) as RN
                              from (select z.*,
                                           case
                                               when normalizar(z.TITULO) = l_norm or normalizar(z.ORIGINAL) = l_norm then 100
                                               when normalizar(z.TITULO) like l_norm || '%'
                                                 or normalizar(z.ORIGINAL) like l_norm || '%' then 40
                                               else round(greatest(
                                                        utl_match.jaro_winkler_similarity(nvl(normalizar(z.TITULO), ' '), l_norm),
                                                        utl_match.jaro_winkler_similarity(nvl(normalizar(z.ORIGINAL), ' '), l_norm)) * 0.5)
                                           end
                                           + case
                                                 when l_ano is null          then 0
                                                 when z.ANO = l_ano          then 30
                                                 when abs(z.ANO - l_ano) = 1 then 10
                                                 else -20
                                             end
                                           + case
                                                 when l_dica is null  then 0
                                                 when z.TIPO = l_dica then 15
                                                 else -15
                                             end
                                           + least(20, round(ln(1 + nvl(z.POPULARIDADE, 0)) * 4)) as PONTOS
                                      from (select case jt.MEDIA_TYPE when 'movie' then 'FILME' else 'SERIE' end as TIPO,
                                                   jt.ID_TMDB,
                                                   coalesce(jt.TITLE, jt.NAME) as TITULO,
                                                   coalesce(jt.ORIGINAL_TITLE, jt.ORIGINAL_NAME) as ORIGINAL,
                                                   to_number(substr(coalesce(jt.RELEASE_DATE, jt.FIRST_AIR_DATE), 1, 4)
                                                             default null on conversion error) as ANO,
                                                   jt.POSTER_PATH,
                                                   jt.POPULARIDADE
                                              from json_table(l_corpo, '$.results[*]' columns (
                                                       MEDIA_TYPE     varchar2(10)  path '$.media_type',
                                                       ID_TMDB        number        path '$.id',
                                                       TITLE          varchar2(400) path '$.title',
                                                       NAME           varchar2(400) path '$.name',
                                                       ORIGINAL_TITLE varchar2(400) path '$.original_title',
                                                       ORIGINAL_NAME  varchar2(400) path '$.original_name',
                                                       RELEASE_DATE   varchar2(10)  path '$.release_date',
                                                       FIRST_AIR_DATE varchar2(10)  path '$.first_air_date',
                                                       POSTER_PATH    varchar2(200) path '$.poster_path',
                                                       POPULARIDADE   number        path '$.popularity')) jt
                                             where jt.MEDIA_TYPE in ('movie', 'tv')) z) y) x
                     where x.RN <= 5;

                    l_status := case
                                    when l_melhor is null then 'NAO_ACHEI'
                                    when l_melhor >= 100 and (l_segundo is null or l_segundo <= l_melhor - 25) then 'OK'
                                    when l_melhor >= 60 then 'AMBIGUO'
                                    else 'NAO_ACHEI'
                                end;

                    if l_status = 'OK' then
                        select case when count(*) > 0 then 'NA_LISTA' else 'OK' end
                          into l_status
                          from MMM_LISTA_ITEM li
                          join MMM_TITULO t
                            on t.ID_TITULO = li.ID_TITULO
                         where li.RETIRADO_EM is null
                           and t.TIPO    = l_tipo1
                           and t.ID_TMDB = l_id1;
                    end if;
                end if;
            end if;

            apex_collection.add_member(
                p_collection_name => c_colecao_nota,
                p_c001            => l_linha,   -- c001 = linha como veio
                p_c002            => l_status,  -- c002 = OK, AMBIGUO, NAO_ACHEI, NA_LISTA, ERRO, NAO_PROCESSADA
                p_clob001         => nvl(l_cand, to_clob('[]')));  -- clob001 = ate 5 candidatos
        end loop;

        select json_object(
                   'ok'     value 'true' format json,
                   'linhas' value nvl(json_arrayagg(
                                 json_object(
                                     'seq'        value c.SEQ_ID,
                                     'linha'      value c.C001,
                                     'status'     value c.C002,
                                     'candidatos' value c.CLOB001 format json
                                     returning clob)
                                 order by c.SEQ_ID returning clob), to_clob('[]')) format json
                   returning clob)
          into l_saida
          from APEX_COLLECTIONS c
         where c.COLLECTION_NAME = c_colecao_nota;

        return l_saida;
    end reconhecer_nota;

    function titulo_da_nota(p_seq in number, p_tipo in varchar2, p_id_tmdb in number) return number is
        l_cand     clob;
        l_titulo   varchar2(400);
        l_original varchar2(400);
        l_ano      number;
        l_poster   varchar2(200);
        l_id       MMM_TITULO.ID_TITULO%type;
    begin
        begin
            select c.CLOB001
              into l_cand
              from APEX_COLLECTIONS c
             where c.COLLECTION_NAME = c_colecao_nota
               and c.SEQ_ID          = p_seq;

            -- so aceita o que a busca do servidor devolveu para essa linha
            select jt.TITULO, jt.ORIGINAL, jt.ANO, jt.POSTER_PATH
              into l_titulo, l_original, l_ano, l_poster
              from json_table(l_cand, '$[*]' columns (
                       TIPO        varchar2(5)   path '$.tipo',
                       ID_TMDB     number        path '$.idTmdb',
                       TITULO      varchar2(400) path '$.titulo',
                       ORIGINAL    varchar2(400) path '$.original',
                       ANO         number        path '$.ano',
                       POSTER_PATH varchar2(200) path '$.posterPath')) jt
             where jt.TIPO    = p_tipo
               and jt.ID_TMDB = p_id_tmdb
             fetch first 1 row only;
        exception
            when no_data_found then
                raise_application_error(-20613, 'Escolha fora dos candidatos desta linha.');
        end;

        begin
            select ID_TITULO
              into l_id
              from MMM_TITULO
             where TIPO    = p_tipo
               and ID_TMDB = p_id_tmdb;
        exception
            when no_data_found then
                begin
                    insert into MMM_TITULO (TIPO, ID_TMDB, SITUACAO, TITULO, TITULO_ORIGINAL, ANO, POSTER_PATH, SINCRONIZADO_EM)
                    values (p_tipo, p_id_tmdb, 'PENDENTE', substr(l_titulo, 1, 300), substr(l_original, 1, 300),
                            l_ano, l_poster, systimestamp)
                    returning ID_TITULO into l_id;
                exception
                    when dup_val_on_index then
                        select ID_TITULO
                          into l_id
                          from MMM_TITULO
                         where TIPO    = p_tipo
                           and ID_TMDB = p_id_tmdb;
                end;
        end;
        return l_id;
    end titulo_da_nota;

    procedure resumo(p_operacao in varchar2, p_ok in number, p_falhas in number, p_extra in varchar2 default null) is
    begin
        MMM_PKG_UTIL.log_app(p_operacao, p_ok, 'ok ' || p_ok || ', falhas ' || p_falhas || nvl2(p_extra, ', ' || p_extra, null));
    end resumo;

    procedure job_completar_pendentes is
        l_ok    pls_integer := 0;
        l_falha pls_integer := 0;
        l_res   varchar2(10);
    begin
        for t in (select ID_TITULO
                    from MMM_TITULO
                   where SITUACAO = 'PENDENTE'
                     -- backoff de 2^n minutos depois de cada falha, teto de 256
                     and (ULTIMA_FALHA_EM is null
                          or ULTIMA_FALHA_EM + numtodsinterval(power(2, least(FALHAS_SEGUIDAS, 8)), 'MINUTE') <= systimestamp)
                   order by CRIADO_EM
                   fetch first 40 rows only) loop
            begin
                l_res := atualizar_titulo(t.ID_TITULO);
                commit;
                exit when l_res = 'PARAR';
                if l_res = 'OK' then
                    l_ok := l_ok + 1;
                else
                    l_falha := l_falha + 1;
                end if;
            exception
                when others then
                    rollback;
                    registrar_falha(t.ID_TITULO, null);
                    commit;
                    l_falha := l_falha + 1;
            end;
        end loop;
        if l_ok + l_falha > 0 then
            resumo('JOB_COMPLETAR', l_ok, l_falha);
        end if;
    end job_completar_pendentes;

    procedure job_noite is
        l_ok    pls_integer := 0;
        l_falha pls_integer := 0;
        l_prov  pls_integer := 0;
        l_res   varchar2(10);
        l_parar boolean := false;
    begin
        -- "em uso" sai de view com VPD: dentro do APEX so renovaria o grupo ativo
        MMM_PKG_UTIL.exigir_job_do_dono;
        -- 1) detalhes: em uso e com 30 dias; cada renovacao reinicia o prazo de 6 meses do TMDB
        for t in (select t.ID_TITULO
                    from MMM_TITULO t
                   where t.SINCRONIZADO_EM < systimestamp - interval '30' day
                     and exists (select 1 from MMM_V_TITULO_EM_USO u where u.ID_TITULO = t.ID_TITULO)
                   order by t.SINCRONIZADO_EM
                   fetch first 400 rows only) loop
            begin
                l_res := atualizar_titulo(t.ID_TITULO);
                commit;
                if l_res = 'PARAR' then
                    l_parar := true;
                    exit;
                elsif l_res = 'OK' then
                    l_ok := l_ok + 1;
                else
                    l_falha := l_falha + 1;
                end if;
            exception
                when others then
                    rollback;
                    l_falha := l_falha + 1;
            end;
        end loop;

        -- 2) onde assistir muda toda semana: renova o que esta numa lista ativa e passou de 20 horas
        if not l_parar then
            for t in (select t.ID_TITULO
                        from MMM_TITULO t
                       where t.SITUACAO = 'OK'
                         and (t.PROVEDORES_EM is null or t.PROVEDORES_EM < systimestamp - interval '20' hour)
                         and exists (select 1
                                       from MMM_LISTA_ITEM li
                                      where li.ID_TITULO   = t.ID_TITULO
                                        and li.RETIRADO_EM is null)
                       order by t.PROVEDORES_EM nulls first
                       fetch first 2000 rows only) loop
                begin
                    l_res := atualizar_provedores(t.ID_TITULO);
                    commit;
                    exit when l_res = 'PARAR';
                    if l_res = 'OK' then
                        l_prov := l_prov + 1;
                    end if;
                exception
                    when others then
                        rollback;
                end;
            end loop;
        end if;

        resumo('JOB_NOITE', l_ok, l_falha, l_prov || ' titulos com onde assistir renovado');
        job_completar_pendentes;
    end job_noite;

    procedure job_catalogo_mensal is
        l_resp  MMM_PKG_HTTP.t_resposta;
        l_corpo clob;
        l_agora timestamp with time zone := systimestamp;
        l_sem   number;
    begin
        for r in (select 'FILME' as TIPO from dual
                  union all
                  select 'SERIE' from dual) loop
            l_resp := MMM_PKG_HTTP.chamar(
                          p_sistema    => 'TMDB',
                          p_operacao   => 'GENEROS',
                          p_caminho    => '/genre/' || rota(r.TIPO) || '/list?language=pt-BR',
                          p_timeout    => 15,
                          p_espera_max => 10);
            if l_resp.resultado = 'OK' then
                l_corpo := l_resp.corpo;
                merge into MMM_GENERO g
                using (select jt.ID_TMDB, MMM_PKG_TMDB.nome_genero(jt.ID_TMDB, max(jt.NOME)) as NOME
                         from json_table(l_corpo, '$.genres[*]' columns (
                                  ID_TMDB number       path '$.id',
                                  NOME    varchar2(60) path '$.name')) jt
                        where jt.ID_TMDB is not null
                        group by jt.ID_TMDB) s
                   on (g.ID_TMDB = s.ID_TMDB)
                 when matched then update
                      set g.NOME            = s.NOME,
                          g.FL_FILME        = case when r.TIPO = 'FILME' then 'S' else g.FL_FILME end,
                          g.FL_SERIE        = case when r.TIPO = 'SERIE' then 'S' else g.FL_SERIE end,
                          g.SINCRONIZADO_EM = l_agora
                 when not matched then insert (ID_TMDB, NOME, FL_FILME, FL_SERIE, SINCRONIZADO_EM)
                      values (s.ID_TMDB, s.NOME,
                              case when r.TIPO = 'FILME' then 'S' else 'N' end,
                              case when r.TIPO = 'SERIE' then 'S' else 'N' end,
                              l_agora);
                commit;
            end if;

            l_resp := MMM_PKG_HTTP.chamar(
                          p_sistema    => 'TMDB',
                          p_operacao   => 'PROVEDORES_BR',
                          p_caminho    => '/watch/providers/' || rota(r.TIPO) || '?language=pt-BR&watch_region=BR',
                          p_timeout    => 15,
                          p_espera_max => 10);
            if l_resp.resultado = 'OK' then
                l_corpo := l_resp.corpo;
                merge into MMM_PROVEDOR p
                using (select jt.ID_TMDB, max(jt.NOME) as NOME, max(jt.LOGO) as LOGO
                         from json_table(l_corpo, '$.results[*]' columns (
                                  ID_TMDB number        path '$.provider_id',
                                  NOME    varchar2(100) path '$.provider_name',
                                  LOGO    varchar2(200) path '$.logo_path')) jt
                        where jt.ID_TMDB is not null
                        group by jt.ID_TMDB) s
                   on (p.ID_TMDB = s.ID_TMDB)
                 when matched then update
                      set p.NOME            = nvl(s.NOME, p.NOME),
                          p.LOGO_PATH       = s.LOGO,
                          p.SINCRONIZADO_EM = l_agora
                 when not matched then insert (ID_TMDB, NOME, LOGO_PATH, SINCRONIZADO_EM)
                      values (s.ID_TMDB, nvl(s.NOME, 'Provedor ' || s.ID_TMDB), s.LOGO, l_agora);
                commit;
            end if;
        end loop;

        MMM_MAPEAR_PROVEDORES;
        commit;

        -- provedor que aparece em alguma disponibilidade e nao tem familia: mapear em MMM_MAPEAR_PROVEDORES
        select count(distinct p.ID_PROVEDOR)
          into l_sem
          from MMM_PROVEDOR p
         where p.ID_SERVICO is null
           and exists (select 1 from MMM_DISPONIBILIDADE d where d.ID_PROVEDOR = p.ID_PROVEDOR);
        MMM_PKG_UTIL.log_app('JOB_CATALOGO', l_sem, 'provedores em uso sem familia: ' || l_sem);
    end job_catalogo_mensal;

    procedure job_repor_detalhes is
        l_ok    pls_integer := 0;
        l_falha pls_integer := 0;
        l_res   varchar2(10);
    begin
        -- "em uso" sai de view com VPD: dentro do APEX so renovaria o grupo ativo
        MMM_PKG_UTIL.exigir_job_do_dono;
        -- quem ainda nao foi lido com o elenco ou com as recomendacoes (PESSOAS_JSON ou RECOMENDACOES_JSON nulo), pela mesma
        -- rotina do job da noite: um de cada vez, devagar, parando no circuito ou na credencial. Cada renovacao reinicia o
        -- prazo de 6 meses do TMDB
        for t in (select t.ID_TITULO
                    from MMM_TITULO t
                   where t.SITUACAO     = 'OK'
                     and (t.PESSOAS_JSON is null or t.RECOMENDACOES_JSON is null)
                     and exists (select 1 from MMM_V_TITULO_EM_USO u where u.ID_TITULO = t.ID_TITULO)
                   order by t.SINCRONIZADO_EM
                   fetch first 1000 rows only) loop
            begin
                l_res := atualizar_titulo(t.ID_TITULO);
                commit;
                exit when l_res = 'PARAR';
                if l_res = 'OK' then
                    l_ok := l_ok + 1;
                else
                    l_falha := l_falha + 1;
                end if;
            exception
                when others then
                    rollback;
                    l_falha := l_falha + 1;
            end;
            -- uns 3 por segundo, como o job da noite: o Adicionar das pessoas continua com folga no TMDB
            dbms_session.sleep(0.3);
        end loop;
        resumo('JOB_REPOR_DETALHES', l_ok, l_falha, case when l_res = 'PARAR' then 'parou: credencial, rede ou circuito' end);
    end job_repor_detalhes;

end MMM_PKG_TMDB;
/
