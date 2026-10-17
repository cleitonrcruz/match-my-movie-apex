create or replace package MMM_PKG_JOGO authid definer as
    -- Regras da Hora do Cinema no servidor: baralho, votos, apuracao, final, placar e o estado que o
    -- polling le. Tudo age sobre o grupo ATIVO (o VPD esconde o resto). Toda rotina que muda a sessao
    -- trava a linha de MMM_SESSAO (FOR UPDATE WAIT 3) e sobe VERSAO. So AJAX faz COMMIT.

    c_err_acesso        constant pls_integer := -20301;
    c_err_estado        constant pls_integer := -20302;
    c_err_ordem         constant pls_integer := -20303;
    c_err_poder         constant pls_integer := -20304;
    c_err_ja_votou      constant pls_integer := -20305;
    c_err_incompleto    constant pls_integer := -20306;
    c_err_baralho       constant pls_integer := -20307;
    c_err_em_andamento  constant pls_integer := -20308;
    c_err_ocupado       constant pls_integer := -20309;
    c_err_carta_vez     constant pls_integer := -20310;
    c_err_aguarde       constant pls_integer := -20311;
    c_err_parametro     constant pls_integer := -20312;

    -- sessao aberta do grupo ativo, ou nulo
    function sessao_aberta return number;

    -- o que a pagina 30 mostra: a aberta, ou a ultima encerrada ha menos de 30 minutos com presenca minha
    function sessao_da_tela return number;

    function contagens(p_filtros in clob) return clob;
    function criar_sessao(p_filtros in clob) return number;
    procedure entrar(p_id_sessao in number);
    procedure votar(p_id_sessao in number, p_id_carta in number, p_voto in varchar2);
    procedure desfazer(p_id_sessao in number, p_id_carta in number);
    procedure concluir_baralho(p_id_sessao in number);
    procedure remover_presenca(p_id_sessao in number, p_id_membro_alvo in number);
    -- quem sai do grupo (ou e tirado pelo dono) sai tambem do sofa da sessao aberta; chamar antes do update de MMM_MEMBRO
    procedure tirar_do_sofa(p_id_membro in number);
    procedure avancar_final(p_id_sessao in number);
    procedure votar_duelo(p_id_sessao in number, p_id_duelo in number, p_lado in varchar2);
    procedure girar_roleta(p_id_sessao in number);
    procedure cancelar(p_id_sessao in number);
    procedure cutucar(p_id_sessao in number);
    function usar_minha_vez(p_id_titulo in number) return number;

    -- JSON do estado; com p_versao_cliente igual a versao atual devolve so {"mudou":false}
    function estado(p_id_sessao in number, p_versao_cliente in number default null) return clob;

    -- cartas com titulo, poster, sinopse e onde assistir: a pagina carrega uma vez
    function cartas_json(p_id_sessao in number) return clob;

    -- ponto de entrada do Application Process MMM_JOGO (x01 = acao)
    procedure ajax;

end MMM_PKG_JOGO;
/

create or replace package body MMM_PKG_JOGO as

    c_max_cartas     constant pls_integer := 15;
    c_max_finalistas constant pls_integer := 8;

    e_lock_timeout exception;
    pragma exception_init(e_lock_timeout, -30006);

    type t_filtros is record (
        tipo       varchar2(5),
        limite     number,
        episodios  number,
        crianca    varchar2(1),
        aluguel    varchar2(1),
        regra      varchar2(7),
        tipo_final varchar2(6),
        relogio    number,
        climas     apex_t_varchar2,
        recortes   apex_t_varchar2,
        servicos   apex_t_varchar2,
        presentes  apex_t_number);

    procedure abrir_proximo_duelo(p_id_sessao in number);

    procedure erro(p_codigo in pls_integer, p_mensagem in varchar2) is
    begin
        raise_application_error(p_codigo, p_mensagem);
    end erro;

    function numero(p_texto in varchar2) return number is
    begin
        return to_number(p_texto);
    exception
        when value_error or invalid_number then
            return null;
    end numero;

    function segundos_desde(p_ts in timestamp with time zone) return number is
        l_intervalo interval day(9) to second(6);
    begin
        if p_ts is null then
            return null;
        end if;
        l_intervalo := systimestamp - p_ts;
        return extract(day from l_intervalo) * 86400
             + extract(hour from l_intervalo) * 3600
             + extract(minute from l_intervalo) * 60
             + round(extract(second from l_intervalo));
    end segundos_desde;

    function segundos_entre(p_de in timestamp with time zone, p_ate in timestamp with time zone) return number is
        l_intervalo interval day(9) to second(6);
    begin
        if p_de is null or p_ate is null then
            return null;
        end if;
        l_intervalo := p_ate - p_de;
        return greatest(0, extract(day from l_intervalo) * 86400
                         + extract(hour from l_intervalo) * 3600
                         + extract(minute from l_intervalo) * 60
                         + round(extract(second from l_intervalo)));
    end segundos_entre;

    -- o relogio que a abertura gravou nos filtros da sessao (ler_filtros ja conferiu o valor); nulo = sem relogio
    function relogio_de(p_filtros in varchar2) return number is
        l_txt varchar2(4000);
    begin
        if p_filtros is null then
            return null;
        end if;
        select json_value(p_filtros, '$.relogio' returning varchar2(4000) null on error null on empty)
          into l_txt
          from dual;
        return numero(l_txt);
    end relogio_de;

    function eu return number is
        l_id number := MMM_PKG_SEGURANCA.id_membro_atual;
    begin
        if l_id is null then
            erro(c_err_acesso, 'Escolha um grupo antes.');
        end if;
        return l_id;
    end eu;

    function grupo_demo(p_id_grupo in number) return varchar2 is
        l_demo MMM_GRUPO.FL_DEMO%type;
    begin
        select FL_DEMO
          into l_demo
          from MMM_GRUPO
         where ID_GRUPO = p_id_grupo;
        return l_demo;
    end grupo_demo;

    function situacao_de(p_id_sessao in number, p_id_membro in number) return varchar2 is
        l_situacao MMM_SESSAO_PRESENCA.SITUACAO%type;
    begin
        select SITUACAO
          into l_situacao
          from MMM_SESSAO_PRESENCA
         where ID_SESSAO = p_id_sessao
           and ID_MEMBRO = p_id_membro;
        return l_situacao;
    exception
        when no_data_found then
            erro(c_err_acesso, 'Você não está nesta sessão.');
    end situacao_de;

    -- a trava vive so dentro da requisicao: nasce aqui e morre no COMMIT do callback.
    -- Sessao de outro grupo nao aparece (VPD): cai no no_data_found.
    function travar(p_id_sessao in number) return MMM_SESSAO%rowtype is
        s MMM_SESSAO%rowtype;
    begin
        select *
          into s
          from MMM_SESSAO
         where ID_SESSAO = p_id_sessao
           for update wait 3;
        return s;
    exception
        when no_data_found then
            erro(c_err_acesso, 'Sessão não encontrada.');
        when e_lock_timeout then
            erro(c_err_ocupado, 'A sessão está ocupada. Tente de novo.');
    end travar;

    -- toda mudanca que os outros aparelhos precisam ver passa por aqui
    procedure tocar(p_id_sessao in number) is
    begin
        update MMM_SESSAO
           set VERSAO = VERSAO + 1
         where ID_SESSAO = p_id_sessao;
    end tocar;

    function humanos_ativos(p_id_sessao in number) return pls_integer is
        l_qtd pls_integer;
    begin
        select count(*)
          into l_qtd
          from MMM_SESSAO_PRESENCA p
          join MMM_MEMBRO m
            on m.ID_GRUPO  = p.ID_GRUPO
           and m.ID_MEMBRO = p.ID_MEMBRO
          join MMM_USUARIO u
            on u.ID_USUARIO = m.ID_USUARIO
         where p.ID_SESSAO = p_id_sessao
           and p.SITUACAO <> 'SAIU'
           and u.TIPO     <> 'ROBO';
        return l_qtd;
    end humanos_ativos;

    procedure push_membro(p_id_membro in number, p_id_sessao in number, p_titulo in varchar2, p_corpo in varchar2) is
        l_id_usuario number;
        l_id_grupo   number;
    begin
        select ID_USUARIO, ID_GRUPO
          into l_id_usuario, l_id_grupo
          from MMM_MEMBRO
         where ID_MEMBRO = p_id_membro;
        -- a pagina 11 troca o grupo ativo antes de abrir a sessao: a pessoa pode estar vendo outro grupo
        MMM_PKG_UTIL.enviar_push(
            p_id_usuario => l_id_usuario,
            p_titulo     => p_titulo,
            p_corpo      => p_corpo,
            p_caminho    => 'abrir?p11_grupo=' || l_id_grupo || '&p11_tipo=SESSAO&p11_id=' || p_id_sessao);
    end push_membro;

    function ler_filtros(p_filtros in clob) return t_filtros is
        r           t_filtros;
        l_qtd       pls_integer;
        l_tempo     number;
        l_tempo_txt varchar2(4000);
        l_tipo      varchar2(4000);
        l_crianca   varchar2(4000);
        l_aluguel   varchar2(4000);
        l_regra     varchar2(4000);
        l_final     varchar2(4000);
        l_relogio   varchar2(4000);
        l_climas    apex_t_varchar2;
        l_recortes  apex_t_varchar2;
        l_servicos  apex_t_varchar2;
        l_presentes apex_t_number;
    begin
        if p_filtros is null or dbms_lob.getlength(p_filtros) > 4000 then
            erro(c_err_parametro, 'Filtro inválido.');
        end if;

        -- le cru e confere aqui: com NULL ON ERROR e nvl, valor fora do contrato virava o padrao em silencio
        -- (crianca: true desligava o Tem crianca). Chave ausente ou null continua valendo o padrao
        begin
            select json_value(p_filtros, '$.tipo'    returning varchar2(4000) error on error null on empty),
                   json_value(p_filtros, '$.tempo'   returning varchar2(4000) error on error null on empty),
                   json_value(p_filtros, '$.crianca' returning varchar2(4000) error on error null on empty),
                   json_value(p_filtros, '$.aluguel' returning varchar2(4000) error on error null on empty),
                   json_value(p_filtros, '$.regra'   returning varchar2(4000) error on error null on empty),
                   json_value(p_filtros, '$.final'   returning varchar2(4000) error on error null on empty),
                   json_value(p_filtros, '$.relogio' returning varchar2(4000) error on error null on empty)
              into l_tipo, l_tempo_txt, l_crianca, l_aluguel, l_regra, l_final, l_relogio
              from dual;
        exception
            when others then
                -- JSON invalido ou valor que nao e escalar (lista, objeto)
                erro(c_err_parametro, 'Filtro inválido.');
        end;

        if l_tipo is null or l_tipo not in ('FILME', 'SERIE') then
            erro(c_err_parametro, 'Escolha filme ou série.');
        end if;
        l_tempo := numero(l_tempo_txt);
        if l_tempo_txt is not null and l_tempo is null then
            erro(c_err_parametro, 'Tempo inválido.');
        end if;
        if (l_crianca is not null and l_crianca not in ('S', 'N', 'true', 'false'))
           or (l_aluguel is not null and l_aluguel not in ('S', 'N', 'true', 'false'))
           or nvl(l_regra, 'TODOS') not in ('TODOS', 'MAIORIA')
           or nvl(l_final, 'DUELOS') not in ('DUELOS', 'ROLETA') then
            erro(c_err_parametro, 'Filtro inválido.');
        end if;
        -- so depois de conferir: o registro tem tamanho curto e um valor longo daria ORA-06502
        r.tipo       := l_tipo;
        r.crianca    := case when l_crianca in ('S', 'true') then 'S' else 'N' end;
        r.aluguel    := case when l_aluguel in ('S', 'true') then 'S' else 'N' end;
        r.regra      := nvl(l_regra, 'TODOS');
        r.tipo_final := nvl(l_final, 'DUELOS');

        -- segundos por carta no baralho; nulo (ou chave ausente, como no app de antes) = sem relogio
        r.relogio := numero(l_relogio);
        if l_relogio is not null and (r.relogio is null or r.relogio not in (10, 20, 30)) then
            erro(c_err_parametro, 'Relógio inválido.');
        end if;

        -- BULK COLLECT sem linha devolve colecao vazia (nao nula): as consultas abaixo contam com isso
        select jt.VALOR bulk collect into l_climas
          from json_table(p_filtros, '$.climas[*]' columns (VALOR varchar2(30) path '$')) jt;
        select jt.VALOR bulk collect into l_recortes
          from json_table(p_filtros, '$.recortes[*]' columns (VALOR varchar2(20) path '$')) jt;
        select jt.VALOR bulk collect into l_servicos
          from json_table(p_filtros, '$.servicos[*]' columns (VALOR varchar2(30) path '$')) jt;
        select jt.VALOR bulk collect into l_presentes
          from json_table(p_filtros, '$.presentes[*]' columns (VALOR number path '$')) jt;
        r.climas    := l_climas;
        r.recortes  := l_recortes;
        r.servicos  := l_servicos;
        r.presentes := l_presentes;

        -- tempo nulo = sem pressa (filme) ou maratona (serie)
        if r.tipo = 'FILME' and l_tempo is not null and l_tempo not in (105, 150) then
            erro(c_err_parametro, 'Tempo inválido.');
        elsif r.tipo = 'SERIE' and l_tempo is not null and l_tempo not in (1, 3) then
            erro(c_err_parametro, 'Tempo inválido.');
        end if;
        r.limite    := case when r.tipo = 'FILME' then l_tempo end;
        r.episodios := case when r.tipo = 'SERIE' then l_tempo end;

        select count(*)
          into l_qtd
          from table(l_climas) c
         where not exists (select 1
                             from MMM_CLIMA cl
                            where cl.TIPO_TITULO = r.tipo
                              and cl.CODIGO      = c.column_value);
        if l_qtd > 0 then
            erro(c_err_parametro, 'Clima inválido.');
        end if;

        select count(*)
          into l_qtd
          from table(l_recortes) c
         where c.column_value not in ('nacional', 'aclamado', 'lancamento', 'classico');
        if l_qtd > 0 then
            erro(c_err_parametro, 'Recorte inválido.');
        end if;

        select count(*)
          into l_qtd
          from table(l_servicos) c
         where not exists (select 1
                             from MMM_SERVICO s
                            where s.CODIGO    = c.column_value
                              and s.CATEGORIA = 'ASSINATURA'
                              and s.FL_ATIVO  = 'S');
        if l_qtd > 0 then
            erro(c_err_parametro, 'Serviço inválido.');
        end if;
        return r;
    end ler_filtros;

    -- itens da lista que passam nos filtros, em tres camadas:
    -- base (tipo, tempo, crianca, onde), clima (um OU outro) e recorte (um OU outro, E com o clima)
    function candidatos(r in t_filtros) return apex_t_number is
        l_itens        apex_t_number;
        l_climas       apex_t_varchar2 := r.climas;
        l_servicos     apex_t_varchar2 := r.servicos;
        l_tipo         varchar2(5) := r.tipo;
        l_limite       number := r.limite;
        l_crianca      varchar2(1) := r.crianca;
        l_aluguel      varchar2(1) := r.aluguel;
        l_nacional     varchar2(1) := 'N';
        l_aclamado     varchar2(1) := 'N';
        l_lancamento   varchar2(1) := 'N';
        l_classico     varchar2(1) := 'N';
        l_qtd_climas   pls_integer := l_climas.count;
        l_qtd_servicos pls_integer := l_servicos.count;
        l_qtd_recortes pls_integer := 0;
        l_ano          pls_integer := extract(year from MMM_PKG_UTIL.hoje_br);
    begin
        if r.recortes is not null then
            for i in 1 .. r.recortes.count loop
                case r.recortes(i)
                    when 'nacional'   then l_nacional := 'S';
                    when 'aclamado'   then l_aclamado := 'S';
                    when 'lancamento' then l_lancamento := 'S';
                    when 'classico'   then l_classico := 'S';
                    else null;
                end case;
            end loop;
            l_qtd_recortes := r.recortes.count;
        end if;

        -- MMM_LISTA_ITEM passa pelo VPD: so a lista do grupo ativo
        select li.ID_LISTA_ITEM
          bulk collect into l_itens
          from MMM_LISTA_ITEM li
          join MMM_TITULO t
            on t.ID_TITULO = li.ID_TITULO
         where li.RETIRADO_EM is null
           and t.TIPO = l_tipo
           and (l_tipo = 'SERIE' or l_limite is null or nvl(t.DURACAO_MIN, 0) <= l_limite)
           and (l_crianca = 'N' or t.CLASSIFICACAO in ('L', '10', '12'))
           -- titulo sem lugar nenhum para ver fica fora, mesmo com Tanto faz e aluguel
           and (exists (select 1
                          from MMM_DISPONIBILIDADE d
                          join MMM_PROVEDOR p
                            on p.ID_PROVEDOR = d.ID_PROVEDOR
                          join MMM_SERVICO s
                            on s.ID_SERVICO = p.ID_SERVICO
                         where d.ID_TITULO   = t.ID_TITULO
                           and d.TIPO_OFERTA in ('ASSINATURA', 'ANUNCIOS', 'GRATIS')
                           and s.CATEGORIA   = 'ASSINATURA'
                           and s.FL_ATIVO    = 'S'
                           and (l_qtd_servicos = 0
                                or s.CODIGO in (select column_value from table(l_servicos))))
                or (l_aluguel = 'S'
                    and exists (select 1
                                  from MMM_DISPONIBILIDADE d
                                  join MMM_PROVEDOR p
                                    on p.ID_PROVEDOR = d.ID_PROVEDOR
                                  join MMM_SERVICO s
                                    on s.ID_SERVICO = p.ID_SERVICO
                                 where d.ID_TITULO   = t.ID_TITULO
                                   and d.TIPO_OFERTA in ('ALUGUEL', 'COMPRA')
                                   and s.FL_ATIVO    = 'S')))
           and (l_qtd_climas = 0
                or exists (select 1
                             from MMM_TITULO_GENERO tg
                             join MMM_CLIMA_GENERO cg
                               on cg.ID_GENERO = tg.ID_GENERO
                             join MMM_CLIMA c
                               on c.ID_CLIMA = cg.ID_CLIMA
                            where tg.ID_TITULO  = t.ID_TITULO
                              and c.TIPO_TITULO = l_tipo
                              and c.CODIGO in (select column_value from table(l_climas))))
           and (l_qtd_recortes = 0
                or (l_nacional = 'S' and t.IDIOMA_ORIGINAL = 'pt')
                or (l_aclamado = 'S' and t.NOTA >= 8)
                or (l_lancamento = 'S' and t.ANO >= l_ano - 1)
                or (l_classico = 'S' and t.ANO <= l_ano - 21));
        return l_itens;
    end candidatos;

    function qtd_candidatos(r in t_filtros) return pls_integer is
        l_itens apex_t_number;
    begin
        l_itens := candidatos(r);
        return l_itens.count;
    end qtd_candidatos;

    -- a conta usa a nota, os generos dos climas de que gosta ou evita,
    -- e a vontade de quem sugeriu; regra fixa, sem modelo de IA
    function preferencia(p_id_membro in number, p_id_carta in number) return number is
        l_nota      MMM_TITULO.NOTA%type;
        l_id_titulo MMM_TITULO.ID_TITULO%type;
        l_tipo      MMM_TITULO.TIPO%type;
        l_sugeriu   MMM_SESSAO_CARTA.ID_MEMBRO_SUGERIU%type;
        l_pipocas   MMM_SESSAO_CARTA.PIPOCAS%type;
        l_perfil    MMM_MEMBRO.PERFIL_SIMULADO%type;
        l_gosta     pls_integer;
        l_evita     pls_integer;
    begin
        select t.NOTA, t.ID_TITULO, t.TIPO, c.ID_MEMBRO_SUGERIU, c.PIPOCAS
          into l_nota, l_id_titulo, l_tipo, l_sugeriu, l_pipocas
          from MMM_SESSAO_CARTA c
          join MMM_TITULO t
            on t.ID_TITULO = c.ID_TITULO
         where c.ID_CARTA = p_id_carta;
        select PERFIL_SIMULADO
          into l_perfil
          from MMM_MEMBRO
         where ID_MEMBRO = p_id_membro;

        select count(distinct case when p.LADO = 'G' then tg.ID_GENERO end),
               count(distinct case when p.LADO = 'E' then tg.ID_GENERO end)
          into l_gosta, l_evita
          from (select 'G' as LADO, jt.CODIGO
                  from json_table(l_perfil, '$.gosta[*]' columns (CODIGO varchar2(30) path '$')) jt
                union all
                select 'E', jt.CODIGO
                  from json_table(l_perfil, '$.evita[*]' columns (CODIGO varchar2(30) path '$')) jt) p
          join MMM_CLIMA c
            on c.TIPO_TITULO = l_tipo
           and c.CODIGO      = p.CODIGO
          join MMM_CLIMA_GENERO cg
            on cg.ID_CLIMA = c.ID_CLIMA
          join MMM_TITULO_GENERO tg
            on tg.ID_GENERO = cg.ID_GENERO
           and tg.ID_TITULO = l_id_titulo;

        return (nvl(l_nota, 6.8) - 6.8) * 0.3
             + 0.4 * l_gosta
             - 0.75 * l_evita
             + case when l_sugeriu = p_id_membro then 0.25 * l_pipocas else 0 end;
    end preferencia;

    -- os robos votam o baralho inteiro na criacao, antes do humano: nao da para "colar" do voto dele
    procedure votar_robos(p_id_sessao in number, p_id_grupo in number, p_relogio in number) is
        l_p        number;
        l_melhor   number;
        l_melhor_p number;
        l_pior     number;
        l_pior_p   number;
        l_seg      number;
        l_t        number;
        l_t_pior   number;
    begin
        for u in (select p.ID_MEMBRO
                    from MMM_SESSAO_PRESENCA p
                    join MMM_MEMBRO m
                      on m.ID_GRUPO  = p.ID_GRUPO
                     and m.ID_MEMBRO = p.ID_MEMBRO
                    join MMM_USUARIO us
                      on us.ID_USUARIO = m.ID_USUARIO
                   where p.ID_SESSAO = p_id_sessao
                     and us.TIPO     = 'ROBO') loop
            l_melhor   := null;
            l_melhor_p := null;
            l_pior     := null;
            l_pior_p   := null;
            l_t_pior   := null;
            -- o tempo do robo no baralho e simulado carta a carta, com as regras de quem joga: cada carta dentro do
            -- relogio, e a carta em que ele deixa o relogio zerar e um Nao; sem relogio, de 3 a 14 s, as vezes com a
            -- sinopse lida. As datas sao as de verdade (ele votou tudo agora); o tempo fica so em BARALHO_SEG. A conta
            -- e feita aqui, voto a voto: o sigilo (MMM_VOTO_SIGILO_VPD) nao deixa ler de volta o voto do robo
            l_seg      := 0;
            for c in (select ID_CARTA
                        from MMM_SESSAO_CARTA
                       where ID_SESSAO = p_id_sessao
                       order by ORDEM) loop
                l_p := preferencia(u.ID_MEMBRO, c.ID_CARTA) + (dbms_random.value - 0.5) * 0.7;
                insert into MMM_VOTO (ID_GRUPO, ID_SESSAO, ID_CARTA, ID_MEMBRO, VOTO)
                values (p_id_grupo, p_id_sessao, c.ID_CARTA, u.ID_MEMBRO, case when l_p > 0.35 then 'QUERO' else 'NAO' end);
                if p_relogio is null then
                    l_t := dbms_random.value(3, 14) + case when dbms_random.value < 0.2 then dbms_random.value(4, 12) else 0 end;
                elsif l_p <= 0.35 and dbms_random.value < 0.15 then
                    l_t := p_relogio;
                else
                    l_t := dbms_random.value(2, p_relogio - 1);
                end if;
                l_seg := l_seg + l_t;
                if l_melhor_p is null or l_p > l_melhor_p then
                    l_melhor   := c.ID_CARTA;
                    l_melhor_p := l_p;
                end if;
                if l_pior_p is null or l_p < l_pior_p then
                    l_pior   := c.ID_CARTA;
                    l_pior_p := l_p;
                    l_t_pior := l_t;
                end if;
            end loop;

            if l_melhor_p > 0.9 then
                update MMM_VOTO
                   set VOTO = 'SUPER'
                 where ID_SESSAO = p_id_sessao
                   and ID_MEMBRO = u.ID_MEMBRO
                   and ID_CARTA  = l_melhor;
            end if;
            if l_pior_p < -0.55 and l_pior <> l_melhor and dbms_random.value < 0.75 then
                update MMM_VOTO
                   set VOTO = 'VETO'
                 where ID_SESSAO = p_id_sessao
                   and ID_MEMBRO = u.ID_MEMBRO
                   and ID_CARTA  = l_pior;
                -- o veto e um toque: a carta dele nao pode ter sido a que o relogio zerou
                if l_t_pior = p_relogio then
                    l_seg := l_seg - l_t_pior + dbms_random.value(2, p_relogio - 1);
                end if;
            end if;

            update MMM_SESSAO_PRESENCA
               set SITUACAO          = 'PRONTO',
                   TERMINOU_EM       = systimestamp,
                   ULTIMO_SINAL_EM   = systimestamp,
                   BARALHO_INICIO_EM = systimestamp,
                   BARALHO_FIM_EM    = systimestamp,
                   BARALHO_SEG       = round(l_seg)
             where ID_SESSAO = p_id_sessao
               and ID_MEMBRO = u.ID_MEMBRO;
        end loop;
    end votar_robos;

    -- quem nao votou quero/super no vencedor cedeu; tres vezes seguidas da a carta Minha Vez
    procedure atualizar_placar(p_id_sessao in number, p_id_carta in number) is
    begin
        update MMM_SESSAO_PRESENCA p
           set p.FL_CEDEU = case
                                when exists (select 1
                                               from MMM_VOTO v
                                              where v.ID_SESSAO = p.ID_SESSAO
                                                and v.ID_MEMBRO = p.ID_MEMBRO
                                                and v.ID_CARTA  = p_id_carta
                                                and v.VOTO in ('QUERO', 'SUPER'))
                                then 'N'
                                else 'S'
                            end
         where p.ID_SESSAO   = p_id_sessao
           and p.TERMINOU_EM is not null
           and p.SITUACAO   <> 'SAIU';

        update MMM_SESSAO_PRESENCA p
           set p.FL_GANHOU_CARTA = case
                                       when p.FL_CEDEU = 'S'
                                        and (select m.CEDEU_SEGUIDAS
                                               from MMM_MEMBRO m
                                              where m.ID_MEMBRO = p.ID_MEMBRO) + 1 >= 3
                                       then 'S'
                                       else 'N'
                                   end
         where p.ID_SESSAO = p_id_sessao
           and p.FL_CEDEU is not null;

        -- uma carta por vez: quem ganha com a carta na mao so zera a sequencia
        merge into MMM_MEMBRO m
        using (select ID_MEMBRO, FL_CEDEU, FL_GANHOU_CARTA
                 from MMM_SESSAO_PRESENCA
                where ID_SESSAO = p_id_sessao
                  and FL_CEDEU is not null) x
           on (m.ID_MEMBRO = x.ID_MEMBRO)
         when matched then update
              set m.CEDEU_SEGUIDAS   = case when x.FL_CEDEU = 'N' or x.FL_GANHOU_CARTA = 'S' then 0 else m.CEDEU_SEGUIDAS + 1 end,
                  m.CARTAS_MINHA_VEZ = case when x.FL_GANHOU_CARTA = 'S' then 1 else m.CARTAS_MINHA_VEZ end;
    end atualizar_placar;

    procedure finalizar(p_id_sessao in number, p_id_carta in number, p_modo in varchar2, p_id_membro_vez in number default null) is
        s          MMM_SESSAO%rowtype;
        l_id_titulo MMM_TITULO.ID_TITULO%type;
        l_duracao  MMM_TITULO.DURACAO_MIN%type;
        l_agora    date;
        l_inicio   date;
        l_fim      date;
    begin
        select *
          into s
          from MMM_SESSAO
         where ID_SESSAO = p_id_sessao;
        select t.ID_TITULO, t.DURACAO_MIN
          into l_id_titulo, l_duracao
          from MMM_SESSAO_CARTA c
          join MMM_TITULO t
            on t.ID_TITULO = c.ID_TITULO
         where c.ID_CARTA = p_id_carta;

        -- comeca no proximo multiplo de 5 minutos com pelo menos 5 de folga; conta no fuso de Brasilia
        l_agora  := trunc(cast(systimestamp at time zone 'America/Sao_Paulo' as date), 'MI');
        l_inicio := trunc(l_agora, 'HH24') + ceil((to_number(to_char(l_agora, 'MI')) + 5) / 5) * 5 / 1440;
        l_fim    := case
                        when s.TIPO_TITULO = 'SERIE' and s.EPISODIOS is null then null
                        when s.TIPO_TITULO = 'SERIE' then l_inicio + s.EPISODIOS * nvl(l_duracao, 60) / 1440
                        else l_inicio + nvl(l_duracao, 60) / 1440
                    end;

        update MMM_SESSAO
           set SITUACAO            = 'ENCERRADA',
               ID_TITULO_VENCEDOR  = l_id_titulo,
               MODO_DESFECHO       = p_modo,
               ID_MEMBRO_MINHA_VEZ = p_id_membro_vez,
               INICIO_PREVISTO_EM  = from_tz(cast(l_inicio as timestamp), 'America/Sao_Paulo'),
               FIM_PREVISTO_EM     = case when l_fim is not null then from_tz(cast(l_fim as timestamp), 'America/Sao_Paulo') end,
               ENCERRADA_EM        = systimestamp
         where ID_SESSAO = p_id_sessao;

        merge into MMM_ASSISTIDO a
        using (select p_id_sessao as ID_SESSAO from dual) x
           on (a.ID_SESSAO = x.ID_SESSAO)
         when not matched then insert (ID_GRUPO, ID_TITULO, ID_SESSAO, DATA_ASSISTIDO)
              values (s.ID_GRUPO, l_id_titulo, x.ID_SESSAO, MMM_PKG_UTIL.hoje_br);

        -- filme visto sai da lista; serie continua (a turma volta a ela no proximo episodio)
        if s.TIPO_TITULO = 'FILME' then
            update MMM_LISTA_ITEM
               set RETIRADO_EM     = systimestamp,
                   MOTIVO_RETIRADA = 'ASSISTIDO'
             where ID_GRUPO    = s.ID_GRUPO
               and ID_TITULO   = l_id_titulo
               and RETIRADO_EM is null;
        end if;

        if p_modo <> 'MINHA_VEZ' then
            atualizar_placar(p_id_sessao, p_id_carta);
        end if;
        tocar(p_id_sessao);
    end finalizar;

    procedure encerrar(p_id_sessao in number, p_situacao in varchar2) is
    begin
        update MMM_SESSAO
           set SITUACAO     = p_situacao,
               ENCERRADA_EM = systimestamp
         where ID_SESSAO = p_id_sessao;
        tocar(p_id_sessao);
    end encerrar;

    procedure apurar(p_id_sessao in number) is
        l_regra     MMM_SESSAO.REGRA_MATCH%type;
        l_n         pls_integer;
        l_total     pls_integer;
        l_concordou pls_integer;
        l_qtd       pls_integer;
        l_motivo    MMM_SESSAO.MOTIVO_FINAL%type := 'NORMAL';
    begin
        -- sai de VOTANDO primeiro: so assim a politica MMM_VOTO_SIGILO_VPD deixa contar o voto dos outros
        update MMM_SESSAO
           set SITUACAO = 'REVELADA'
         where ID_SESSAO = p_id_sessao
        returning REGRA_MATCH into l_regra;

        select count(*)
          into l_n
          from MMM_SESSAO_PRESENCA
         where ID_SESSAO   = p_id_sessao
           and TERMINOU_EM is not null
           and SITUACAO   <> 'SAIU';

        -- carta sem voto de alguem conta como "nao"
        merge into MMM_SESSAO_CARTA c
        using (select sc.ID_CARTA,
                      count(case when v.VOTO in ('QUERO', 'SUPER') then 1 end) as SIM,
                      count(case when v.VOTO = 'SUPER' then 1 end) as SUPERS,
                      count(case when v.VOTO = 'VETO' then 1 end) as VETOS
                 from MMM_SESSAO_CARTA sc
                 join MMM_SESSAO_PRESENCA p
                   on p.ID_SESSAO   = sc.ID_SESSAO
                  and p.TERMINOU_EM is not null
                  and p.SITUACAO   <> 'SAIU'
                 left join MMM_VOTO v
                   on v.ID_SESSAO = sc.ID_SESSAO
                  and v.ID_CARTA  = sc.ID_CARTA
                  and v.ID_MEMBRO = p.ID_MEMBRO
                where sc.ID_SESSAO = p_id_sessao
                group by sc.ID_CARTA) x
           on (c.ID_CARTA = x.ID_CARTA)
         when matched then update
              set c.VOTOS_SIM     = x.SIM,
                  c.VOTOS_SUPER   = x.SUPERS,
                  c.VOTOS_VETO    = x.VETOS,
                  c.PONTOS        = x.SIM + x.SUPERS,
                  c.FL_VETADA     = case when x.VETOS > 0 then 'S' else 'N' end,
                  c.FL_MATCH      = case
                                        when x.VETOS = 0
                                         and ((l_regra = 'TODOS' and x.SIM = l_n)
                                              or (l_regra = 'MAIORIA' and x.SIM > l_n / 2))
                                        then 'S'
                                        else 'N'
                                    end,
                  c.FL_FINALISTA  = 'N',
                  c.POSICAO_FINAL = null,
                  c.PESO_ROLETA   = null;

        -- sintonia: cartas em que todo mundo concordou (todos sim ou todos nao)
        select count(*),
               count(case when VOTOS_SIM = l_n or VOTOS_SIM = 0 then 1 end)
          into l_total, l_concordou
          from MMM_SESSAO_CARTA
         where ID_SESSAO = p_id_sessao;

        -- match, ou super sem veto
        update MMM_SESSAO_CARTA
           set FL_FINALISTA = 'S'
         where ID_SESSAO = p_id_sessao
           and (FL_MATCH = 'S' or (VOTOS_SUPER > 0 and VOTOS_VETO = 0));
        l_qtd := sql%rowcount;

        -- ninguem deu match: os 3 mais votados sem veto
        if l_qtd = 0 then
            l_motivo := 'SEM_MATCH';
            update MMM_SESSAO_CARTA
               set FL_FINALISTA = 'S'
             where ID_SESSAO = p_id_sessao
               and ID_CARTA in (select ID_CARTA
                                  from MMM_SESSAO_CARTA
                                 where ID_SESSAO  = p_id_sessao
                                   and VOTOS_VETO = 0
                                   and PONTOS     > 0
                                 order by PONTOS desc, ORDEM
                                 fetch first 3 rows only);
        end if;

        -- no corte de 8 quem entrou por super vem antes (o super promete vaga); a chave segue os pontos
        merge into MMM_SESSAO_CARTA c
        using (select ID_CARTA,
                      PONTOS + PIPOCAS as PESO,
                      row_number() over (order by PONTOS desc, PIPOCAS desc, ORDEM) as POSICAO
                 from (select ID_CARTA, PONTOS, PIPOCAS, ORDEM
                         from MMM_SESSAO_CARTA
                        where ID_SESSAO    = p_id_sessao
                          and FL_FINALISTA = 'S'
                        order by case when VOTOS_SUPER > 0 and VOTOS_VETO = 0 then 0 else 1 end,
                                 PONTOS desc, PIPOCAS desc, ORDEM
                        fetch first c_max_finalistas rows only)) x
           on (c.ID_CARTA = x.ID_CARTA)
         when matched then update
              set c.POSICAO_FINAL = x.POSICAO,
                  c.PESO_ROLETA   = x.PESO;

        update MMM_SESSAO_CARTA
           set FL_FINALISTA = 'N'
         where ID_SESSAO     = p_id_sessao
           and FL_FINALISTA  = 'S'
           and POSICAO_FINAL is null;

        select count(*)
          into l_qtd
          from MMM_SESSAO_CARTA
         where ID_SESSAO    = p_id_sessao
           and FL_FINALISTA = 'S';

        update MMM_SESSAO
           set SITUACAO     = case when l_qtd = 0 then 'SEM_RESULTADO' else 'REVELADA' end,
               SINTONIA_PCT = case when l_total > 0 then round(l_concordou / l_total * 100) end,
               MOTIVO_FINAL = l_motivo,
               ENCERRADA_EM = case when l_qtd = 0 then systimestamp end
         where ID_SESSAO = p_id_sessao;
        tocar(p_id_sessao);
    end apurar;

    procedure verificar_fim_baralho(p_id_sessao in number) is
        l_faltam  pls_integer;
        l_prontos pls_integer;
    begin
        select count(case when SITUACAO in ('CONVIDADO', 'VOTANDO') then 1 end),
               count(case when SITUACAO = 'PRONTO' then 1 end)
          into l_faltam, l_prontos
          from MMM_SESSAO_PRESENCA
         where ID_SESSAO = p_id_sessao;
        if l_faltam = 0 then
            if l_prontos = 0 then
                encerrar(p_id_sessao, 'CANCELADA');
            else
                apurar(p_id_sessao);
            end if;
        end if;
    end verificar_fim_baralho;

    -- avisa uma vez quem esta segurando a mesa com o app fechado
    procedure lembrar_atrasados(p_id_sessao in number, p_id_grupo in number) is
        l_faltam pls_integer;
    begin
        if grupo_demo(p_id_grupo) = 'S' then
            return;
        end if;
        select count(*)
          into l_faltam
          from MMM_SESSAO_PRESENCA
         where ID_SESSAO = p_id_sessao
           and SITUACAO in ('CONVIDADO', 'VOTANDO');
        if l_faltam between 1 and 2 then
            for p in (select ID_MEMBRO
                        from MMM_SESSAO_PRESENCA
                       where ID_SESSAO   = p_id_sessao
                         and SITUACAO in ('CONVIDADO', 'VOTANDO')
                         and LEMBRADO_EM is null
                         -- 5 min: quem le uma sinopse com calma nao esta com o app fechado (o rotulo da espera usa o mesmo)
                         and (ULTIMO_SINAL_EM is null or ULTIMO_SINAL_EM < systimestamp - interval '5' minute)) loop
                push_membro(p.ID_MEMBRO, p_id_sessao, 'Só falta você', 'A turma já votou. Abra o Match My Movie para terminar.');
                update MMM_SESSAO_PRESENCA
                   set LEMBRADO_EM = systimestamp
                 where ID_SESSAO = p_id_sessao
                   and ID_MEMBRO = p.ID_MEMBRO;
            end loop;
        end if;
    end lembrar_atrasados;

    procedure marcar_pronto(p_id_sessao in number, p_id_grupo in number, p_id_membro in number) is
        l_inicio MMM_SESSAO_PRESENCA.BARALHO_INICIO_EM%type;
        l_fim    MMM_SESSAO_PRESENCA.BARALHO_FIM_EM%type;
        l_seg    MMM_SESSAO_PRESENCA.BARALHO_SEG%type;
    begin
        select BARALHO_INICIO_EM, BARALHO_FIM_EM, BARALHO_SEG
          into l_inicio, l_fim, l_seg
          from MMM_SESSAO_PRESENCA
         where ID_SESSAO = p_id_sessao
           and ID_MEMBRO = p_id_membro;
        -- o fim do baralho e o da primeira vez que a pessoa votou tudo: quem sai e volta com tudo votado nao conta o
        -- tempo fora
        if l_fim is null then
            l_fim := systimestamp;
            l_seg := segundos_entre(l_inicio, l_fim);
        end if;
        update MMM_SESSAO_PRESENCA
           set SITUACAO        = 'PRONTO',
               TERMINOU_EM     = systimestamp,
               ULTIMO_SINAL_EM = systimestamp,
               BARALHO_FIM_EM  = l_fim,
               BARALHO_SEG     = l_seg
         where ID_SESSAO = p_id_sessao
           and ID_MEMBRO = p_id_membro;
        tocar(p_id_sessao);
        lembrar_atrasados(p_id_sessao, p_id_grupo);
        verificar_fim_baralho(p_id_sessao);
    end marcar_pronto;

    procedure abrir_rodada(p_id_sessao in number, p_id_grupo in number, p_rodada in pls_integer, p_cartas in apex_t_number) is
        l_ordem  pls_integer := 0;
        l_numero pls_integer;
        l_nome   MMM_DUELO.NOME_RODADA%type;
        i        pls_integer := 1;
    begin
        if p_cartas.count = 1 then
            finalizar(p_id_sessao, p_cartas(1), 'DUELOS');
            return;
        end if;
        l_nome := case
                      when p_cartas.count <= 2 then 'Final'
                      when p_cartas.count <= 4 then 'Semifinal'
                      else 'Quartas de final'
                  end;
        select count(NUMERO)
          into l_numero
          from MMM_DUELO
         where ID_SESSAO = p_id_sessao;

        -- numero impar: o mais bem colocado (primeiro da lista) passa direto
        if mod(p_cartas.count, 2) = 1 then
            l_ordem := l_ordem + 1;
            insert into MMM_DUELO (ID_GRUPO, ID_SESSAO, RODADA, ORDEM, NOME_RODADA, SITUACAO, ID_CARTA_A,
                                   ID_CARTA_VENCEDORA, DECIDIDO_POR, DECIDIDO_EM)
            values (p_id_grupo, p_id_sessao, p_rodada, l_ordem, l_nome, 'DECIDIDO', p_cartas(1),
                    p_cartas(1), 'BYE', systimestamp);
            i := 2;
        end if;

        while i < p_cartas.count loop
            l_ordem  := l_ordem + 1;
            l_numero := l_numero + 1;
            insert into MMM_DUELO (ID_GRUPO, ID_SESSAO, RODADA, ORDEM, NUMERO, NOME_RODADA, SITUACAO, ID_CARTA_A, ID_CARTA_B)
            values (p_id_grupo, p_id_sessao, p_rodada, l_ordem, l_numero, l_nome, 'PENDENTE', p_cartas(i), p_cartas(i + 1));
            i := i + 2;
        end loop;

        abrir_proximo_duelo(p_id_sessao);
    end abrir_rodada;

    procedure decidir_duelo(p_id_sessao in number, p_id_duelo in number) is
        d          MMM_DUELO%rowtype;
        l_a        pls_integer;
        l_b        pls_integer;
        l_pts_a    number;
        l_pts_b    number;
        l_chance_a number;
        l_sorteio  number;
        l_vencedor MMM_DUELO.ID_CARTA_VENCEDORA%type;
        l_decisao  MMM_DUELO.DECIDIDO_POR%type;
    begin
        select *
          into d
          from MMM_DUELO
         where ID_DUELO = p_id_duelo;

        select count(case when v.LADO = 'A' then 1 end),
               count(case when v.LADO = 'B' then 1 end)
          into l_a, l_b
          from MMM_DUELO_VOTO v
          join MMM_SESSAO_PRESENCA p
            on p.ID_SESSAO = v.ID_SESSAO
           and p.ID_MEMBRO = v.ID_MEMBRO
           and p.SITUACAO  = 'PRONTO'
         where v.ID_DUELO = p_id_duelo;

        if l_a <> l_b then
            l_vencedor := case when l_a > l_b then d.ID_CARTA_A else d.ID_CARTA_B end;
            l_decisao  := 'VOTOS';
        else
            -- empate: moeda com peso pelos pontos da revelacao, sorteada aqui para todo aparelho ver o mesmo
            select greatest(nvl(max(case when ID_CARTA = d.ID_CARTA_A then PONTOS end), 0), 1),
                   greatest(nvl(max(case when ID_CARTA = d.ID_CARTA_B then PONTOS end), 0), 1)
              into l_pts_a, l_pts_b
              from MMM_SESSAO_CARTA
             where ID_CARTA in (d.ID_CARTA_A, d.ID_CARTA_B);
            l_chance_a := l_pts_a / (l_pts_a + l_pts_b);
            l_sorteio  := dbms_random.value;
            l_vencedor := case when l_sorteio < l_chance_a then d.ID_CARTA_A else d.ID_CARTA_B end;
            l_decisao  := 'MOEDA';
        end if;

        update MMM_DUELO
           set SITUACAO           = 'DECIDIDO',
               DECIDIDO_POR       = l_decisao,
               ID_CARTA_VENCEDORA = l_vencedor,
               VOTOS_A            = l_a,
               VOTOS_B            = l_b,
               MOEDA_SORTEIO      = l_sorteio,
               MOEDA_CHANCE_A     = l_chance_a,
               DECIDIDO_EM        = systimestamp
         where ID_DUELO = p_id_duelo;
        tocar(p_id_sessao);
        abrir_proximo_duelo(p_id_sessao);
    end decidir_duelo;

    procedure verificar_duelo(p_id_sessao in number, p_id_duelo in number) is
        l_faltam pls_integer;
    begin
        select count(*)
          into l_faltam
          from MMM_SESSAO_PRESENCA p
         where p.ID_SESSAO = p_id_sessao
           and p.SITUACAO  = 'PRONTO'
           and not exists (select 1
                             from MMM_DUELO_VOTO v
                            where v.ID_DUELO  = p_id_duelo
                              and v.ID_MEMBRO = p.ID_MEMBRO);
        if l_faltam = 0 then
            decidir_duelo(p_id_sessao, p_id_duelo);
        end if;
    end verificar_duelo;

    procedure votar_duelo_robos(p_id_sessao in number, p_id_duelo in number) is
        d    MMM_DUELO%rowtype;
        l_pa number;
        l_pb number;
    begin
        select *
          into d
          from MMM_DUELO
         where ID_DUELO = p_id_duelo;
        for u in (select p.ID_MEMBRO
                    from MMM_SESSAO_PRESENCA p
                    join MMM_MEMBRO m
                      on m.ID_GRUPO  = p.ID_GRUPO
                     and m.ID_MEMBRO = p.ID_MEMBRO
                    join MMM_USUARIO us
                      on us.ID_USUARIO = m.ID_USUARIO
                   where p.ID_SESSAO = p_id_sessao
                     and p.SITUACAO  = 'PRONTO'
                     and us.TIPO     = 'ROBO') loop
            l_pa := preferencia(u.ID_MEMBRO, d.ID_CARTA_A) + dbms_random.value * 0.5;
            l_pb := preferencia(u.ID_MEMBRO, d.ID_CARTA_B) + dbms_random.value * 0.5;
            insert into MMM_DUELO_VOTO (ID_GRUPO, ID_SESSAO, ID_DUELO, ID_MEMBRO, LADO)
            values (d.ID_GRUPO, p_id_sessao, p_id_duelo, u.ID_MEMBRO, case when l_pa >= l_pb then 'A' else 'B' end);
        end loop;
    end votar_duelo_robos;

    procedure abrir_proximo_duelo(p_id_sessao in number) is
        l_id_duelo MMM_DUELO.ID_DUELO%type;
        l_rodada   MMM_DUELO.RODADA%type;
        l_id_grupo MMM_DUELO.ID_GRUPO%type;
        l_cartas   apex_t_number;
    begin
        select max(ID_DUELO) keep (dense_rank first order by RODADA, ORDEM),
               max(RODADA),
               max(ID_GRUPO)
          into l_id_duelo, l_rodada, l_id_grupo
          from MMM_DUELO
         where ID_SESSAO = p_id_sessao
           and SITUACAO  = 'PENDENTE';

        if l_id_duelo is null then
            -- rodada fechada: os vencedores, na ordem dos duelos (o bye vem primeiro), formam a proxima
            select max(RODADA), max(ID_GRUPO)
              into l_rodada, l_id_grupo
              from MMM_DUELO
             where ID_SESSAO = p_id_sessao;
            select ID_CARTA_VENCEDORA
              bulk collect into l_cartas
              from MMM_DUELO
             where ID_SESSAO = p_id_sessao
               and RODADA    = l_rodada
             order by ORDEM;
            abrir_rodada(p_id_sessao, l_id_grupo, l_rodada + 1, l_cartas);
            return;
        end if;

        update MMM_DUELO
           set SITUACAO = 'ABERTO'
         where ID_DUELO = l_id_duelo;
        votar_duelo_robos(p_id_sessao, l_id_duelo);
        verificar_duelo(p_id_sessao, l_id_duelo);
    end abrir_proximo_duelo;

    procedure sinal(p_id_sessao in number, p_id_membro in number) is
        l_antes MMM_SESSAO_PRESENCA.ULTIMO_SINAL_EM%type;
    begin
        select ULTIMO_SINAL_EM
          into l_antes
          from MMM_SESSAO_PRESENCA
         where ID_SESSAO = p_id_sessao
           and ID_MEMBRO = p_id_membro
           and SITUACAO <> 'SAIU';
        -- grava no maximo a cada 20 s, para o polling nao virar uma escrita por consulta
        if l_antes is null or l_antes < systimestamp - interval '20' second then
            update MMM_SESSAO_PRESENCA
               set ULTIMO_SINAL_EM = systimestamp
             where ID_SESSAO = p_id_sessao
               and ID_MEMBRO = p_id_membro;
            -- voltou depois de sumir: os outros aparelhos precisam tirar o "sem sinal"
            if l_antes < systimestamp - interval '90' second then
                tocar(p_id_sessao);
            end if;
        end if;
    exception
        when no_data_found then
            null;   -- membro do grupo so olhando
    end sinal;

    function sessao_aberta return number is
        l_id MMM_SESSAO.ID_SESSAO%type;
    begin
        select max(ID_SESSAO)
          into l_id
          from MMM_SESSAO
         where SITUACAO in ('VOTANDO', 'REVELADA', 'FINAL');
        return l_id;
    end sessao_aberta;

    function sessao_da_tela return number is
        l_id MMM_SESSAO.ID_SESSAO%type := sessao_aberta;
    begin
        if l_id is null then
            select max(s.ID_SESSAO)
              into l_id
              from MMM_SESSAO s
             where s.ENCERRADA_EM > systimestamp - interval '30' minute
               and exists (select 1
                             from MMM_SESSAO_PRESENCA p
                            where p.ID_SESSAO = s.ID_SESSAO
                              and p.ID_MEMBRO = MMM_PKG_SEGURANCA.id_membro_atual);
        end if;
        return l_id;
    end sessao_da_tela;

    function contagens(p_filtros in clob) return clob is
        r          t_filtros;
        r2         t_filtros;
        l_qtd      pls_integer;
        l_json     clob;
        l_aberto   boolean := false;
    begin
        r := ler_filtros(p_filtros);
        l_qtd := qtd_candidatos(r);

        apex_json.initialize_clob_output;
        l_aberto := true;
        apex_json.open_object;
        apex_json.write('ok', true);
        apex_json.write('candidatos', l_qtd);
        apex_json.write('cartas', least(l_qtd, c_max_cartas));

        -- cada clima com o que a tela desenha (MMM_CLIMA e configuracao nossa: clima novo aparece sem mexer no JS)
        -- e a contagem com os recortes atuais; cada recorte com os climas atuais
        apex_json.open_array('climas');
        for c in (select CODIGO, NOME, DICA, ICONE
                    from MMM_CLIMA
                   where TIPO_TITULO = r.tipo
                   order by ORDEM) loop
            r2 := r;
            r2.climas := apex_t_varchar2(c.CODIGO);
            apex_json.open_object;
            apex_json.write('codigo', c.CODIGO);
            apex_json.write('nome', c.NOME);
            apex_json.write('dica', c.DICA);
            apex_json.write('icone', c.ICONE);
            apex_json.write('qtd', qtd_candidatos(r2));
            apex_json.close_object;
        end loop;
        apex_json.close_array;

        apex_json.open_object('recortes');
        for c in (select column_value as CODIGO
                    from table(apex_t_varchar2('nacional', 'aclamado', 'lancamento', 'classico'))) loop
            r2 := r;
            r2.recortes := apex_t_varchar2(c.CODIGO);
            apex_json.write(c.CODIGO, qtd_candidatos(r2));
        end loop;
        apex_json.close_object;

        -- servicos: quantos titulos do tipo cada assinatura cobre na lista, sem os outros filtros
        apex_json.open_array('servicos');
        for s in (select sv.CODIGO,
                         sv.NOME,
                         (select max(pl.LOGO_PATH)
                            from MMM_PROVEDOR pl
                           where pl.ID_SERVICO      = sv.ID_SERVICO
                             and pl.FL_LOGO_SERVICO = 'S') as LOGO,
                         count(distinct li.ID_TITULO) as QTD
                    from MMM_LISTA_ITEM li
                    join MMM_TITULO t
                      on t.ID_TITULO = li.ID_TITULO
                    join MMM_DISPONIBILIDADE d
                      on d.ID_TITULO = t.ID_TITULO
                     and d.TIPO_OFERTA in ('ASSINATURA', 'ANUNCIOS', 'GRATIS')
                    join MMM_PROVEDOR p
                      on p.ID_PROVEDOR = d.ID_PROVEDOR
                    join MMM_SERVICO sv
                      on sv.ID_SERVICO = p.ID_SERVICO
                   where li.RETIRADO_EM is null
                     and t.TIPO        = r.tipo
                     and sv.CATEGORIA  = 'ASSINATURA'
                     and sv.FL_ATIVO   = 'S'
                   group by sv.ID_SERVICO, sv.CODIGO, sv.NOME, sv.ORDEM
                   order by QTD desc, sv.ORDEM) loop
            apex_json.open_object;
            apex_json.write('codigo', s.CODIGO);
            apex_json.write('nome', s.NOME);
            apex_json.write('logo', s.LOGO);
            apex_json.write('qtd', s.QTD);
            apex_json.close_object;
        end loop;
        apex_json.close_array;
        apex_json.close_object;

        l_json := apex_json.get_clob_output;
        apex_json.free_output;
        return l_json;
    exception
        when others then
            if l_aberto then
                apex_json.free_output;
            end if;
            raise;
    end contagens;

    function criar_sessao(p_filtros in clob) return number is
        r          t_filtros;
        l_me       number := eu;
        l_id_grupo number := MMM_PKG_SEGURANCA.id_grupo_ativo;
        l_itens    apex_t_number;
        l_presentes apex_t_number;
        l_id       MMM_SESSAO.ID_SESSAO%type;
        l_apelido  MMM_MEMBRO.APELIDO%type;
    begin
        r := ler_filtros(p_filtros);
        l_presentes := r.presentes;
        l_itens := candidatos(r);
        if l_itens.count < 2 then
            erro(c_err_baralho, 'Menos de dois títulos passam nesses filtros. Afrouxe algum para ter jogo.');
        end if;

        begin
            insert into MMM_SESSAO (ID_GRUPO, TIPO_TITULO, ID_MEMBRO_CRIADOR, LIMITE_MINUTOS, EPISODIOS,
                                    FL_ALUGUEL, FL_CRIANCA, REGRA_MATCH, TIPO_FINAL, FILTROS_JSON, SITUACAO)
            values (l_id_grupo, r.tipo, l_me, r.limite, r.episodios,
                    r.aluguel, r.crianca, r.regra, r.tipo_final, dbms_lob.substr(p_filtros, 4000, 1), 'VOTANDO')
            returning ID_SESSAO into l_id;
        exception
            when dup_val_on_index then
                erro(c_err_em_andamento, 'O grupo já tem uma sessão em andamento.');
        end;

        -- ate 15 cartas puxadas pela vontade (pipocas + sorte) e depois embaralhadas
        insert into MMM_SESSAO_CARTA (ID_GRUPO, ID_SESSAO, TIPO_TITULO, ID_TITULO, ORDEM, PIPOCAS, ID_MEMBRO_SUGERIU)
        select l_id_grupo,
               l_id,
               r.tipo,
               s.ID_TITULO,
               row_number() over (order by dbms_random.value),
               s.PIPOCAS,
               s.ID_MEMBRO_SUGERIU
          from (select li.ID_TITULO, li.PIPOCAS, li.ID_MEMBRO_SUGERIU
                  from MMM_LISTA_ITEM li
                 where li.ID_LISTA_ITEM in (select column_value from table(l_itens))
                 order by li.PIPOCAS + dbms_random.value(0, 1.5) desc
                 fetch first c_max_cartas rows only) s;

        insert into MMM_SESSAO_PRESENCA (ID_GRUPO, ID_SESSAO, ID_MEMBRO, SITUACAO, ULTIMO_SINAL_EM)
        select l_id_grupo,
               l_id,
               m.ID_MEMBRO,
               case when m.ID_MEMBRO = l_me then 'VOTANDO' else 'CONVIDADO' end,
               case when m.ID_MEMBRO = l_me then systimestamp end
          from MMM_MEMBRO m
         where m.ID_GRUPO = l_id_grupo
           and m.SITUACAO = 'ATIVO'
           and (m.ID_MEMBRO = l_me
                or m.ID_MEMBRO in (select column_value from table(l_presentes)));

        votar_robos(l_id, l_id_grupo, r.relogio);

        if grupo_demo(l_id_grupo) = 'N' then
            select APELIDO
              into l_apelido
              from MMM_MEMBRO
             where ID_MEMBRO = l_me;
            for p in (select ID_MEMBRO
                        from MMM_SESSAO_PRESENCA
                       where ID_SESSAO = l_id
                         and SITUACAO  = 'CONVIDADO') loop
                push_membro(p.ID_MEMBRO, l_id, 'Hora do Cinema',
                            l_apelido || ' chamou para escolher ' || case r.tipo when 'FILME' then 'um filme.' else 'uma série.' end);
            end loop;
        end if;
        return l_id;
    end criar_sessao;

    procedure entrar(p_id_sessao in number) is
        s          MMM_SESSAO%rowtype;
        l_me       number := eu;
        l_situacao MMM_SESSAO_PRESENCA.SITUACAO%type;
        l_votadas  pls_integer;
        l_total    pls_integer;
    begin
        s := travar(p_id_sessao);
        select max(SITUACAO)
          into l_situacao
          from MMM_SESSAO_PRESENCA
         where ID_SESSAO = p_id_sessao
           and ID_MEMBRO = l_me;
        if l_situacao in ('VOTANDO', 'PRONTO') then
            -- quem convocou ja nasce VOTANDO: o baralho dele comeca quando a pagina 30 abre, como o de quem foi chamado.
            -- Reabrir o app nao muda mais nada
            if l_situacao = 'VOTANDO' and s.SITUACAO = 'VOTANDO' then
                update MMM_SESSAO_PRESENCA
                   set BARALHO_INICIO_EM = systimestamp
                 where ID_SESSAO = p_id_sessao
                   and ID_MEMBRO = l_me
                   and BARALHO_INICIO_EM is null;
                if sql%rowcount > 0 then
                    tocar(p_id_sessao);   -- a espera dos outros passa a contar o tempo dele
                end if;
            end if;
            return;
        end if;
        if s.SITUACAO <> 'VOTANDO' then
            erro(c_err_estado, 'A votação desta sessão já terminou.');
        end if;

        merge into MMM_SESSAO_PRESENCA p
        using (select s.ID_GRUPO as ID_GRUPO, p_id_sessao as ID_SESSAO, l_me as ID_MEMBRO from dual) x
           on (p.ID_GRUPO = x.ID_GRUPO and p.ID_SESSAO = x.ID_SESSAO and p.ID_MEMBRO = x.ID_MEMBRO)
         when matched then update
              set p.SITUACAO          = 'VOTANDO',
                  p.ULTIMO_SINAL_EM   = systimestamp,
                  p.TERMINOU_EM       = null,
                  -- o inicio e o da primeira vez que a pessoa abriu o baralho: sair e voltar nao zera o tempo
                  p.BARALHO_INICIO_EM = nvl(p.BARALHO_INICIO_EM, systimestamp)
         when not matched then insert (ID_GRUPO, ID_SESSAO, ID_MEMBRO, SITUACAO, ULTIMO_SINAL_EM, BARALHO_INICIO_EM)
              values (x.ID_GRUPO, x.ID_SESSAO, x.ID_MEMBRO, 'VOTANDO', systimestamp, systimestamp);
        tocar(p_id_sessao);

        -- voltou depois de sair com o baralho todo votado
        select count(*)
          into l_votadas
          from MMM_VOTO
         where ID_SESSAO = p_id_sessao
           and ID_MEMBRO = l_me;
        select count(*)
          into l_total
          from MMM_SESSAO_CARTA
         where ID_SESSAO = p_id_sessao;
        if l_votadas = l_total then
            marcar_pronto(p_id_sessao, s.ID_GRUPO, l_me);
        end if;
    end entrar;

    procedure votar(p_id_sessao in number, p_id_carta in number, p_voto in varchar2) is
        s          MMM_SESSAO%rowtype;
        l_me       number := eu;
        l_situacao MMM_SESSAO_PRESENCA.SITUACAO%type;
        l_ordem    MMM_SESSAO_CARTA.ORDEM%type;
        l_votadas  pls_integer;
        l_atual    MMM_VOTO.VOTO%type;
        l_total    pls_integer;
    begin
        if p_voto is null or p_voto not in ('QUERO', 'NAO', 'SUPER', 'VETO') then
            erro(c_err_parametro, 'Voto inválido.');
        end if;
        s := travar(p_id_sessao);
        if s.SITUACAO <> 'VOTANDO' then
            -- o reenvio do ultimo voto (a resposta se perdeu) chega depois de ele mesmo fechar a votacao: ja esta gravado
            select max(VOTO)
              into l_atual
              from MMM_VOTO
             where ID_SESSAO = p_id_sessao
               and ID_CARTA  = p_id_carta
               and ID_MEMBRO = l_me;
            if l_atual = p_voto then
                return;
            end if;
            erro(c_err_estado, 'A votação desta sessão já terminou.');
        end if;
        l_situacao := situacao_de(p_id_sessao, l_me);
        if l_situacao = 'SAIU' then
            erro(c_err_estado, 'Você saiu desta sessão. Entre de novo para votar.');
        end if;

        begin
            select ORDEM
              into l_ordem
              from MMM_SESSAO_CARTA
             where ID_SESSAO = p_id_sessao
               and ID_CARTA  = p_id_carta;
        exception
            when no_data_found then
                erro(c_err_parametro, 'Esta carta não é desta sessão.');
        end;

        select count(*),
               max(case when ID_CARTA = p_id_carta then VOTO end)
          into l_votadas, l_atual
          from MMM_VOTO
         where ID_SESSAO = p_id_sessao
           and ID_MEMBRO = l_me;

        if l_atual is not null then
            if l_atual = p_voto then
                return;   -- toque duplo ou reenvio da mesma jogada
            end if;
            erro(c_err_ja_votou, 'Esta carta já tem o seu voto. Use desfazer.');
        end if;
        -- as cartas sao votadas na ordem do baralho; e o que deixa retomar de outro aparelho
        if l_ordem <> l_votadas + 1 then
            erro(c_err_ordem, 'Carta fora de ordem.');
        end if;

        begin
            insert into MMM_VOTO (ID_GRUPO, ID_SESSAO, ID_CARTA, ID_MEMBRO, VOTO)
            values (s.ID_GRUPO, p_id_sessao, p_id_carta, l_me, p_voto);
        exception
            when dup_val_on_index then
                -- a carta ja foi conferida acima; quem dispara aqui e o indice de um super/veto por pessoa
                erro(c_err_poder, case p_voto when 'SUPER' then 'Você já usou o seu super.' else 'Você já usou o seu veto.' end);
        end;

        if l_situacao = 'CONVIDADO' then
            update MMM_SESSAO_PRESENCA
               set SITUACAO          = 'VOTANDO',
                   ULTIMO_SINAL_EM   = systimestamp,
                   BARALHO_INICIO_EM = nvl(BARALHO_INICIO_EM, systimestamp)
             where ID_SESSAO = p_id_sessao
               and ID_MEMBRO = l_me;
            tocar(p_id_sessao);
        elsif l_votadas = 0 then
            -- quem convocou e o ENTRAR nao chegou (rede, 429): o baralho comeca no primeiro voto
            update MMM_SESSAO_PRESENCA
               set BARALHO_INICIO_EM = systimestamp
             where ID_SESSAO = p_id_sessao
               and ID_MEMBRO = l_me
               and BARALHO_INICIO_EM is null;
            if sql%rowcount > 0 then
                tocar(p_id_sessao);
            end if;
        end if;

        select count(*)
          into l_total
          from MMM_SESSAO_CARTA
         where ID_SESSAO = p_id_sessao;
        if l_votadas + 1 = l_total then
            marcar_pronto(p_id_sessao, s.ID_GRUPO, l_me);
        end if;
    end votar;

    procedure desfazer(p_id_sessao in number, p_id_carta in number) is
        s         MMM_SESSAO%rowtype;
        l_me      number := eu;
        l_ultima  MMM_SESSAO_CARTA.ORDEM%type;
        l_ordem   MMM_SESSAO_CARTA.ORDEM%type;
    begin
        s := travar(p_id_sessao);
        if s.SITUACAO <> 'VOTANDO' or situacao_de(p_id_sessao, l_me) <> 'VOTANDO' then
            erro(c_err_estado, 'Não há voto para desfazer.');
        end if;

        select max(c.ORDEM),
               max(case when c.ID_CARTA = p_id_carta then c.ORDEM end)
          into l_ultima, l_ordem
          from MMM_VOTO v
          join MMM_SESSAO_CARTA c
            on c.ID_CARTA = v.ID_CARTA
         where v.ID_SESSAO = p_id_sessao
           and v.ID_MEMBRO = l_me;
        if l_ordem is null then
            return;   -- o mesmo desfazer chegou duas vezes
        end if;
        if l_ordem <> l_ultima then
            erro(c_err_ordem, 'Só dá para desfazer o último voto.');
        end if;

        -- apagar a linha devolve o super/veto, porque o indice unico so conta o que existe
        delete from MMM_VOTO
         where ID_SESSAO = p_id_sessao
           and ID_MEMBRO = l_me
           and ID_CARTA  = p_id_carta;
    end desfazer;

    procedure concluir_baralho(p_id_sessao in number) is
        s          MMM_SESSAO%rowtype;
        l_me       number := eu;
        l_situacao MMM_SESSAO_PRESENCA.SITUACAO%type;
        l_votadas  pls_integer;
        l_total    pls_integer;
    begin
        s := travar(p_id_sessao);
        l_situacao := situacao_de(p_id_sessao, l_me);
        if l_situacao = 'PRONTO' then
            return;
        end if;
        if s.SITUACAO <> 'VOTANDO' or l_situacao = 'SAIU' then
            erro(c_err_estado, 'A votação desta sessão já terminou.');
        end if;
        select count(*)
          into l_votadas
          from MMM_VOTO
         where ID_SESSAO = p_id_sessao
           and ID_MEMBRO = l_me;
        select count(*)
          into l_total
          from MMM_SESSAO_CARTA
         where ID_SESSAO = p_id_sessao;
        if l_votadas < l_total then
            erro(c_err_incompleto, 'Faltam ' || (l_total - l_votadas) || ' cartas.');
        end if;
        marcar_pronto(p_id_sessao, s.ID_GRUPO, l_me);
    end concluir_baralho;

    procedure remover_presenca(p_id_sessao in number, p_id_membro_alvo in number) is
        s          MMM_SESSAO%rowtype;
        l_me       number := eu;
        l_alvo     MMM_SESSAO_PRESENCA.SITUACAO%type;
        l_id_duelo MMM_DUELO.ID_DUELO%type;
        l_votou    pls_integer;
    begin
        s := travar(p_id_sessao);
        if s.SITUACAO not in ('VOTANDO', 'REVELADA', 'FINAL') then
            -- o reenvio de uma saida que fechou a sessao (a resposta se perdeu): a pessoa ja esta fora
            select max(SITUACAO)
              into l_alvo
              from MMM_SESSAO_PRESENCA
             where ID_SESSAO = p_id_sessao
               and ID_MEMBRO = p_id_membro_alvo;
            if l_alvo = 'SAIU' then
                return;
            end if;
            erro(c_err_estado, 'A sessão já terminou.');
        end if;
        if p_id_membro_alvo <> l_me and situacao_de(p_id_sessao, l_me) = 'SAIU' then
            erro(c_err_acesso, 'Só quem está na sessão tira alguém dela.');
        end if;
        l_alvo := situacao_de(p_id_sessao, p_id_membro_alvo);
        if l_alvo = 'SAIU' then
            return;
        end if;

        if s.SITUACAO = 'FINAL' then
            select max(ID_DUELO)
              into l_id_duelo
              from MMM_DUELO
             where ID_SESSAO = p_id_sessao
               and SITUACAO  = 'ABERTO';
        end if;

        -- tirar outra pessoa so serve para destravar a mesa: quem ainda deve voto
        if p_id_membro_alvo <> l_me then
            if s.SITUACAO = 'REVELADA' or (s.SITUACAO = 'FINAL' and l_id_duelo is null) then
                erro(c_err_estado, 'Nesta fase ninguém está esperando voto.');
            end if;
            if s.SITUACAO = 'VOTANDO' and l_alvo = 'PRONTO' then
                erro(c_err_estado, 'Essa pessoa já terminou de votar.');
            end if;
            if l_id_duelo is not null then
                select count(*)
                  into l_votou
                  from MMM_DUELO_VOTO
                 where ID_DUELO  = l_id_duelo
                   and ID_MEMBRO = p_id_membro_alvo;
                if l_votou > 0 then
                    erro(c_err_estado, 'Essa pessoa já votou neste duelo.');
                end if;
            end if;
        end if;

        -- quem sai durante a votacao fica fora da apuracao e da revelacao
        update MMM_SESSAO_PRESENCA
           set SITUACAO    = 'SAIU',
               TERMINOU_EM = case when s.SITUACAO = 'VOTANDO' then null else TERMINOU_EM end
         where ID_SESSAO = p_id_sessao
           and ID_MEMBRO = p_id_membro_alvo;
        tocar(p_id_sessao);

        if humanos_ativos(p_id_sessao) = 0 then
            encerrar(p_id_sessao, 'CANCELADA');
        elsif s.SITUACAO = 'VOTANDO' then
            verificar_fim_baralho(p_id_sessao);
        elsif l_id_duelo is not null then
            verificar_duelo(p_id_sessao, l_id_duelo);
        end if;
    end remover_presenca;

    -- quem sai do grupo sai tambem do sofa: depois do update de MMM_MEMBRO o VPD de MMM_USUARIO esconde a
    -- pessoa, ninguem consegue seguir sem ela e, se ja estava PRONTO, o voto dela contaria na apuracao
    procedure tirar_do_sofa(p_id_membro in number) is
        l_id    MMM_SESSAO.ID_SESSAO%type := sessao_aberta;
        s       MMM_SESSAO%rowtype;
        l_duelo MMM_DUELO.ID_DUELO%type;
    begin
        if l_id is null then
            return;
        end if;
        s := travar(l_id);
        update MMM_SESSAO_PRESENCA
           set SITUACAO    = 'SAIU',
               TERMINOU_EM = case when s.SITUACAO = 'VOTANDO' then null else TERMINOU_EM end
         where ID_SESSAO = l_id
           and ID_MEMBRO = p_id_membro
           and SITUACAO <> 'SAIU';
        if sql%rowcount = 0 then
            return;
        end if;
        tocar(l_id);
        if humanos_ativos(l_id) = 0 then
            encerrar(l_id, 'CANCELADA');
        elsif s.SITUACAO = 'VOTANDO' then
            verificar_fim_baralho(l_id);
        elsif s.SITUACAO = 'FINAL' then
            select max(ID_DUELO)
              into l_duelo
              from MMM_DUELO
             where ID_SESSAO = l_id
               and SITUACAO  = 'ABERTO';
            if l_duelo is not null then
                verificar_duelo(l_id, l_duelo);
            end if;
        end if;
    end tirar_do_sofa;

    procedure avancar_final(p_id_sessao in number) is
        s       MMM_SESSAO%rowtype;
        l_me    number := eu;
        l_qtd   pls_integer;
        l_unica MMM_SESSAO_CARTA.ID_CARTA%type;
        l_lista apex_t_number;
    begin
        s := travar(p_id_sessao);
        if s.SITUACAO in ('FINAL', 'ENCERRADA') then
            return;   -- outro aparelho ja avancou
        end if;
        if s.SITUACAO <> 'REVELADA' then
            erro(c_err_estado, 'Ainda não é hora da final.');
        end if;
        if situacao_de(p_id_sessao, l_me) <> 'PRONTO' then
            erro(c_err_acesso, 'Só quem votou leva a sessão para a final.');
        end if;

        select count(*), max(ID_CARTA)
          into l_qtd, l_unica
          from MMM_SESSAO_CARTA
         where ID_SESSAO    = p_id_sessao
           and FL_FINALISTA = 'S';

        if l_qtd = 1 then
            finalizar(p_id_sessao, l_unica, 'UNICO');
            return;
        end if;

        update MMM_SESSAO
           set SITUACAO = 'FINAL'
         where ID_SESSAO = p_id_sessao;
        tocar(p_id_sessao);

        if s.TIPO_FINAL = 'DUELOS' then
            select ID_CARTA
              bulk collect into l_lista
              from MMM_SESSAO_CARTA
             where ID_SESSAO    = p_id_sessao
               and FL_FINALISTA = 'S'
             order by POSICAO_FINAL;
            abrir_rodada(p_id_sessao, s.ID_GRUPO, 1, l_lista);
        end if;
    end avancar_final;

    procedure votar_duelo(p_id_sessao in number, p_id_duelo in number, p_lado in varchar2) is
        s     MMM_SESSAO%rowtype;
        d     MMM_DUELO%rowtype;
        l_me  number := eu;
        l_meu MMM_DUELO_VOTO.LADO%type;
    begin
        if p_lado is null or p_lado not in ('A', 'B') then
            erro(c_err_parametro, 'Escolha um dos dois.');
        end if;
        s := travar(p_id_sessao);
        if situacao_de(p_id_sessao, l_me) <> 'PRONTO' then
            erro(c_err_acesso, 'Só quem está na sessão vota nos duelos.');
        end if;
        begin
            select *
              into d
              from MMM_DUELO
             where ID_DUELO  = p_id_duelo
               and ID_SESSAO = p_id_sessao;
        exception
            when no_data_found then
                erro(c_err_parametro, 'Duelo não encontrado.');
        end;
        select max(LADO)
          into l_meu
          from MMM_DUELO_VOTO
         where ID_DUELO  = p_id_duelo
           and ID_MEMBRO = l_me;

        if d.SITUACAO <> 'ABERTO' or s.SITUACAO <> 'FINAL' then
            if l_meu = p_lado then
                return;   -- o reenvio chegou depois de o proprio voto fechar o duelo
            end if;
            erro(c_err_estado, 'Este duelo já foi decidido.');
        end if;
        if l_meu = p_lado then
            return;   -- toque duplo
        end if;

        -- enquanto o duelo esta aberto da para trocar de lado
        merge into MMM_DUELO_VOTO v
        using (select d.ID_GRUPO as ID_GRUPO, p_id_sessao as ID_SESSAO, p_id_duelo as ID_DUELO, l_me as ID_MEMBRO from dual) x
           on (v.ID_GRUPO = x.ID_GRUPO and v.ID_SESSAO = x.ID_SESSAO and v.ID_DUELO = x.ID_DUELO and v.ID_MEMBRO = x.ID_MEMBRO)
         when matched then update
              set v.LADO = p_lado
         when not matched then insert (ID_GRUPO, ID_SESSAO, ID_DUELO, ID_MEMBRO, LADO)
              values (x.ID_GRUPO, x.ID_SESSAO, x.ID_DUELO, x.ID_MEMBRO, p_lado);
        tocar(p_id_sessao);
        verificar_duelo(p_id_sessao, p_id_duelo);
    end votar_duelo;

    procedure girar_roleta(p_id_sessao in number) is
        s          MMM_SESSAO%rowtype;
        l_me       number := eu;
        l_total    number;
        l_alvo     number;
        l_acum     number := 0;
        l_vencedor MMM_SESSAO_CARTA.ID_CARTA%type;
    begin
        s := travar(p_id_sessao);
        if s.SITUACAO = 'ENCERRADA' and s.MODO_DESFECHO = 'ROLETA' then
            return;   -- outro aparelho girou primeiro; todos recebem o mesmo resultado
        end if;
        if s.SITUACAO <> 'FINAL' or s.TIPO_FINAL <> 'ROLETA' then
            erro(c_err_estado, 'A roleta não está na mesa.');
        end if;
        if situacao_de(p_id_sessao, l_me) <> 'PRONTO' then
            erro(c_err_acesso, 'Só quem votou gira a roleta.');
        end if;

        -- fatia proporcional a pontos + pipocas; o sorteio e daqui, o aparelho so anima ate ele
        select sum(PESO_ROLETA)
          into l_total
          from MMM_SESSAO_CARTA
         where ID_SESSAO    = p_id_sessao
           and FL_FINALISTA = 'S';
        l_alvo := dbms_random.value(0, l_total);
        for f in (select ID_CARTA, PESO_ROLETA
                    from MMM_SESSAO_CARTA
                   where ID_SESSAO    = p_id_sessao
                     and FL_FINALISTA = 'S'
                   order by POSICAO_FINAL) loop
            l_acum     := l_acum + f.PESO_ROLETA;
            l_vencedor := f.ID_CARTA;
            exit when l_alvo < l_acum;
        end loop;

        -- onde o ponteiro para dentro da fatia (20% a 80%), igual para todos os aparelhos
        update MMM_SESSAO
           set ROLETA_FRACAO = dbms_random.value(0.2, 0.8)
         where ID_SESSAO = p_id_sessao;
        finalizar(p_id_sessao, l_vencedor, 'ROLETA');
    end girar_roleta;

    procedure cancelar(p_id_sessao in number) is
        s          MMM_SESSAO%rowtype;
        l_me       number := eu;
        l_criador  MMM_SESSAO_PRESENCA.SITUACAO%type;
    begin
        s := travar(p_id_sessao);
        if s.SITUACAO not in ('VOTANDO', 'REVELADA', 'FINAL') then
            return;
        end if;
        if s.ID_MEMBRO_CRIADOR <> l_me then
            -- se quem convocou saiu, qualquer um que ficou pode encerrar
            select max(SITUACAO)
              into l_criador
              from MMM_SESSAO_PRESENCA
             where ID_SESSAO = p_id_sessao
               and ID_MEMBRO = s.ID_MEMBRO_CRIADOR;
            if nvl(l_criador, 'SAIU') <> 'SAIU' or situacao_de(p_id_sessao, l_me) = 'SAIU' then
                erro(c_err_acesso, 'Só quem convocou encerra a sessão.');
            end if;
        end if;
        encerrar(p_id_sessao, 'CANCELADA');
    end cancelar;

    procedure cutucar(p_id_sessao in number) is
        s          MMM_SESSAO%rowtype;
        l_me       number := eu;
        l_id_duelo MMM_DUELO.ID_DUELO%type;
        l_apelido  MMM_MEMBRO.APELIDO%type;
    begin
        s := travar(p_id_sessao);
        if s.SITUACAO not in ('VOTANDO', 'FINAL') then
            erro(c_err_estado, 'Ninguém está devendo voto agora.');
        end if;
        if situacao_de(p_id_sessao, l_me) = 'SAIU' then
            erro(c_err_acesso, 'Você saiu desta sessão.');
        end if;
        if grupo_demo(s.ID_GRUPO) = 'S' then
            return;   -- a demo nao manda push
        end if;

        update MMM_SESSAO
           set CUTUCADA_EM = systimestamp
         where ID_SESSAO = p_id_sessao
           and (CUTUCADA_EM is null or CUTUCADA_EM < systimestamp - interval '1' minute);
        if sql%rowcount = 0 then
            erro(c_err_aguarde, 'Espere um minuto para cutucar de novo.');
        end if;

        select APELIDO
          into l_apelido
          from MMM_MEMBRO
         where ID_MEMBRO = l_me;
        if s.SITUACAO = 'FINAL' then
            select max(ID_DUELO)
              into l_id_duelo
              from MMM_DUELO
             where ID_SESSAO = p_id_sessao
               and SITUACAO  = 'ABERTO';
        end if;

        for p in (select pr.ID_MEMBRO
                    from MMM_SESSAO_PRESENCA pr
                   where pr.ID_SESSAO  = p_id_sessao
                     and pr.ID_MEMBRO <> l_me
                     and ((s.SITUACAO = 'VOTANDO' and pr.SITUACAO in ('CONVIDADO', 'VOTANDO'))
                          or (l_id_duelo is not null
                              and pr.SITUACAO = 'PRONTO'
                              and not exists (select 1
                                                from MMM_DUELO_VOTO v
                                               where v.ID_DUELO  = l_id_duelo
                                                 and v.ID_MEMBRO = pr.ID_MEMBRO)))) loop
            push_membro(p.ID_MEMBRO, p_id_sessao, 'Falta você votar', l_apelido || ' está esperando no Match My Movie.');
        end loop;
    end cutucar;

    function usar_minha_vez(p_id_titulo in number) return number is
        l_me       number := eu;
        l_id_grupo number := MMM_PKG_SEGURANCA.id_grupo_ativo;
        l_id       MMM_SESSAO.ID_SESSAO%type;
        l_id_carta MMM_SESSAO_CARTA.ID_CARTA%type;
        l_tipo     MMM_TITULO.TIPO%type;
        l_pipocas  MMM_LISTA_ITEM.PIPOCAS%type;
        l_sugeriu  MMM_LISTA_ITEM.ID_MEMBRO_SUGERIU%type;
    begin
        begin
            select t.TIPO, li.PIPOCAS, li.ID_MEMBRO_SUGERIU
              into l_tipo, l_pipocas, l_sugeriu
              from MMM_LISTA_ITEM li
              join MMM_TITULO t
                on t.ID_TITULO = li.ID_TITULO
             where li.ID_TITULO   = p_id_titulo
               and li.RETIRADO_EM is null;
        exception
            when no_data_found then
                erro(c_err_parametro, 'Esse título não está na lista do grupo.');
        end;

        update MMM_MEMBRO
           set CARTAS_MINHA_VEZ = 0
         where ID_MEMBRO        = l_me
           and CARTAS_MINHA_VEZ = 1;
        if sql%rowcount = 0 then
            erro(c_err_carta_vez, 'Você não tem a carta Minha Vez.');
        end if;

        begin
            insert into MMM_SESSAO (ID_GRUPO, TIPO_TITULO, ID_MEMBRO_CRIADOR, SITUACAO)
            values (l_id_grupo, l_tipo, l_me, 'VOTANDO')
            returning ID_SESSAO into l_id;
        exception
            when dup_val_on_index then
                erro(c_err_em_andamento, 'Termine a sessão em andamento antes de usar a carta.');
        end;
        insert into MMM_SESSAO_CARTA (ID_GRUPO, ID_SESSAO, TIPO_TITULO, ID_TITULO, ORDEM, PIPOCAS, ID_MEMBRO_SUGERIU)
        values (l_id_grupo, l_id, l_tipo, p_id_titulo, 1, l_pipocas, l_sugeriu)
        returning ID_CARTA into l_id_carta;
        insert into MMM_SESSAO_PRESENCA (ID_GRUPO, ID_SESSAO, ID_MEMBRO, SITUACAO, ULTIMO_SINAL_EM, TERMINOU_EM)
        values (l_id_grupo, l_id, l_me, 'PRONTO', systimestamp, systimestamp);
        finalizar(l_id, l_id_carta, 'MINHA_VEZ', l_me);
        return l_id;
    end usar_minha_vez;

    procedure escrever_presencas(s in MMM_SESSAO%rowtype) is
    begin
        apex_json.open_array('presencas');
        for p in (select p.ID_MEMBRO, m.APELIDO, m.COR, u.TIPO, p.SITUACAO, p.ULTIMO_SINAL_EM, p.TERMINOU_EM,
                         p.BARALHO_INICIO_EM, p.BARALHO_SEG
                    from MMM_SESSAO_PRESENCA p
                    join MMM_MEMBRO m
                      on m.ID_GRUPO  = p.ID_GRUPO
                     and m.ID_MEMBRO = p.ID_MEMBRO
                    join MMM_USUARIO u
                      on u.ID_USUARIO = m.ID_USUARIO
                   where p.ID_SESSAO = s.ID_SESSAO
                   order by m.APELIDO) loop
            apex_json.open_object;
            apex_json.write('id', p.ID_MEMBRO);
            apex_json.write('apelido', p.APELIDO);
            apex_json.write('cor', p.COR);
            apex_json.write('robo', p.TIPO = 'ROBO');
            apex_json.write('situacao', p.SITUACAO);
            apex_json.write('votouBaralho', p.TERMINOU_EM is not null);
            apex_json.write('segSemSinal', segundos_desde(p.ULTIMO_SINAL_EM));
            -- na votacao, ha quanto tempo quem ainda vota abriu o baralho (a espera conta sozinha entre um estado e outro);
            -- o tempo de quem terminou so sai depois dela, na revelacao
            if s.SITUACAO = 'VOTANDO' then
                if p.SITUACAO in ('CONVIDADO', 'VOTANDO') then
                    apex_json.write('segBaralho', segundos_desde(p.BARALHO_INICIO_EM));
                end if;
            elsif p.TERMINOU_EM is not null then
                apex_json.write('tempoBaralho', p.BARALHO_SEG);
            end if;
            apex_json.close_object;
        end loop;
        apex_json.close_array;
    end escrever_presencas;

    procedure escrever_eu(p_id_sessao in number, p_id_membro in number) is
        l_situacao MMM_SESSAO_PRESENCA.SITUACAO%type;
        l_votadas  pls_integer;
        l_supers   pls_integer;
        l_vetos    pls_integer;
    begin
        select max(SITUACAO)
          into l_situacao
          from MMM_SESSAO_PRESENCA
         where ID_SESSAO = p_id_sessao
           and ID_MEMBRO = p_id_membro;
        select count(*),
               count(case when VOTO = 'SUPER' then 1 end),
               count(case when VOTO = 'VETO' then 1 end)
          into l_votadas, l_supers, l_vetos
          from MMM_VOTO
         where ID_SESSAO = p_id_sessao
           and ID_MEMBRO = p_id_membro;
        apex_json.open_object('eu');
        apex_json.write('id', p_id_membro);
        apex_json.write('situacao', nvl(l_situacao, 'ESPECTADOR'));
        apex_json.write('votadas', l_votadas);
        apex_json.write('super', 1 - l_supers);
        apex_json.write('veto', 1 - l_vetos);
        apex_json.close_object;
    end escrever_eu;

    -- os votos dos outros so saem depois da votacao; o VPD de sigilo garante isso no banco tambem
    procedure escrever_cartas(s in MMM_SESSAO%rowtype) is
        l_revelar boolean := s.SITUACAO not in ('VOTANDO', 'CANCELADA', 'ABANDONADA');
    begin
        if l_revelar then
            apex_json.write('sintonia', s.SINTONIA_PCT);
            apex_json.write('motivo', s.MOTIVO_FINAL);
        end if;
        apex_json.open_array('cartas');
        for c in (select ID_CARTA, ID_TITULO, ORDEM, PIPOCAS, ID_MEMBRO_SUGERIU, PONTOS, VOTOS_SIM, VOTOS_SUPER,
                         VOTOS_VETO, FL_MATCH, FL_FINALISTA, POSICAO_FINAL
                    from MMM_SESSAO_CARTA
                   where ID_SESSAO = s.ID_SESSAO
                   order by ORDEM) loop
            apex_json.open_object;
            apex_json.write('id', c.ID_CARTA);
            apex_json.write('titulo', c.ID_TITULO);
            apex_json.write('ordem', c.ORDEM);
            apex_json.write('pipocas', c.PIPOCAS);
            apex_json.write('sugeriu', c.ID_MEMBRO_SUGERIU);
            if l_revelar then
                apex_json.write('pontos', c.PONTOS);
                apex_json.write('sim', c.VOTOS_SIM);
                apex_json.write('super', c.VOTOS_SUPER);
                apex_json.write('veto', c.VOTOS_VETO);
                apex_json.write('match', c.FL_MATCH = 'S');
                apex_json.write('finalista', c.FL_FINALISTA = 'S');
                apex_json.write('posicaoFinal', c.POSICAO_FINAL);
                apex_json.open_object('votos');
                for v in (select p.ID_MEMBRO, nvl(v.VOTO, 'NAO') as VOTO
                            from MMM_SESSAO_PRESENCA p
                            left join MMM_VOTO v
                              on v.ID_SESSAO = p.ID_SESSAO
                             and v.ID_MEMBRO = p.ID_MEMBRO
                             and v.ID_CARTA  = c.ID_CARTA
                           where p.ID_SESSAO   = s.ID_SESSAO
                             and p.TERMINOU_EM is not null
                           order by p.ID_MEMBRO) loop
                    apex_json.write(to_char(v.ID_MEMBRO), v.VOTO);
                end loop;
                apex_json.close_object;
            end if;
            apex_json.close_object;
        end loop;
        apex_json.close_array;
    end escrever_cartas;

    procedure escrever_duelos(p_id_sessao in number, p_id_membro in number) is
        l_total  pls_integer;
        l_feitos pls_integer;
        l_meu    MMM_DUELO_VOTO.LADO%type;
        l_bye    MMM_DUELO.ID_CARTA_A%type;
    begin
        select count(*) - 1
          into l_total
          from MMM_SESSAO_CARTA
         where ID_SESSAO    = p_id_sessao
           and FL_FINALISTA = 'S';
        select count(*)
          into l_feitos
          from MMM_DUELO
         where ID_SESSAO = p_id_sessao
           and SITUACAO  = 'DECIDIDO'
           and NUMERO is not null;

        apex_json.open_object('duelos');
        apex_json.write('total', l_total);
        apex_json.write('feitos', l_feitos);

        for d in (select ID_DUELO, NUMERO, NOME_RODADA, ID_CARTA_A, ID_CARTA_B, RODADA
                    from MMM_DUELO
                   where ID_SESSAO = p_id_sessao
                     and SITUACAO  = 'ABERTO') loop
            select max(LADO)
              into l_meu
              from MMM_DUELO_VOTO
             where ID_DUELO  = d.ID_DUELO
               and ID_MEMBRO = p_id_membro;
            apex_json.open_object('atual');
            apex_json.write('id', d.ID_DUELO);
            apex_json.write('numero', d.NUMERO);
            apex_json.write('rodada', d.NOME_RODADA);
            apex_json.write('a', d.ID_CARTA_A);
            apex_json.write('b', d.ID_CARTA_B);
            apex_json.write('meuVoto', l_meu);
            -- quem passou direto nesta rodada (numero impar de finalistas): sem isso a tela nao tem como contar
            select max(ID_CARTA_A)
              into l_bye
              from MMM_DUELO
             where ID_SESSAO    = p_id_sessao
               and RODADA       = d.RODADA
               and DECIDIDO_POR = 'BYE';
            apex_json.write('bye', l_bye);
            -- quem ja votou, nao em quem: a escolha de cada um aparece quando o duelo fecha
            apex_json.open_array('jaVotaram');
            for v in (select ID_MEMBRO
                        from MMM_DUELO_VOTO
                       where ID_DUELO = d.ID_DUELO
                       order by ID_MEMBRO) loop
                apex_json.write(v.ID_MEMBRO);
            end loop;
            apex_json.close_array;
            apex_json.close_object;
        end loop;

        -- ultimo duelo decidido, para o aparelho animar o resultado antes de mostrar o proximo
        for d in (select ID_DUELO, NUMERO, ID_CARTA_A, ID_CARTA_B, ID_CARTA_VENCEDORA, DECIDIDO_POR, MOEDA_CHANCE_A
                    from MMM_DUELO
                   where ID_SESSAO = p_id_sessao
                     and SITUACAO  = 'DECIDIDO'
                     and NUMERO is not null
                   order by RODADA desc, ORDEM desc
                   fetch first 1 row only) loop
            apex_json.open_object('ultimo');
            apex_json.write('id', d.ID_DUELO);
            apex_json.write('numero', d.NUMERO);
            apex_json.write('a', d.ID_CARTA_A);
            apex_json.write('b', d.ID_CARTA_B);
            apex_json.write('vencedor', d.ID_CARTA_VENCEDORA);
            apex_json.write('decisao', d.DECIDIDO_POR);
            apex_json.write('chanceA', d.MOEDA_CHANCE_A);
            apex_json.open_object('votos');
            for v in (select ID_MEMBRO, LADO
                        from MMM_DUELO_VOTO
                       where ID_DUELO = d.ID_DUELO) loop
                apex_json.write(to_char(v.ID_MEMBRO), v.LADO);
            end loop;
            apex_json.close_object;
            apex_json.close_object;
        end loop;
        apex_json.close_object;
    end escrever_duelos;

    -- o vencedor so sai depois do giro; antes, o aparelho recebe so as fatias
    procedure escrever_roleta(s in MMM_SESSAO%rowtype) is
        l_carta MMM_SESSAO_CARTA.ID_CARTA%type;
    begin
        apex_json.open_object('roleta');
        apex_json.open_array('fatias');
        for f in (select ID_CARTA, PESO_ROLETA
                    from MMM_SESSAO_CARTA
                   where ID_SESSAO    = s.ID_SESSAO
                     and FL_FINALISTA = 'S'
                   order by POSICAO_FINAL) loop
            apex_json.open_object;
            apex_json.write('carta', f.ID_CARTA);
            apex_json.write('peso', f.PESO_ROLETA);
            apex_json.close_object;
        end loop;
        apex_json.close_array;
        if s.SITUACAO = 'ENCERRADA' then
            select max(ID_CARTA)
              into l_carta
              from MMM_SESSAO_CARTA
             where ID_SESSAO = s.ID_SESSAO
               and ID_TITULO = s.ID_TITULO_VENCEDOR;
            apex_json.write('vencedora', l_carta);
            apex_json.write('fracao', s.ROLETA_FRACAO);
        end if;
        apex_json.close_object;
    end escrever_roleta;

    procedure escrever_resultado(s in MMM_SESSAO%rowtype) is
    begin
        apex_json.open_object('resultado');
        apex_json.write('titulo', s.ID_TITULO_VENCEDOR);
        apex_json.write('modo', s.MODO_DESFECHO);
        apex_json.write('inicio', MMM_PKG_UTIL.iso(s.INICIO_PREVISTO_EM));
        apex_json.write('fim', MMM_PKG_UTIL.iso(s.FIM_PREVISTO_EM));   -- sem "fim" = maratona
        apex_json.open_array('placar');
        for p in (select p.ID_MEMBRO, m.APELIDO, m.COR, p.FL_CEDEU, p.FL_GANHOU_CARTA, m.CEDEU_SEGUIDAS
                    from MMM_SESSAO_PRESENCA p
                    join MMM_MEMBRO m
                      on m.ID_GRUPO  = p.ID_GRUPO
                     and m.ID_MEMBRO = p.ID_MEMBRO
                   where p.ID_SESSAO = s.ID_SESSAO
                     and p.FL_CEDEU is not null
                   order by m.APELIDO) loop
            apex_json.open_object;
            apex_json.write('id', p.ID_MEMBRO);
            apex_json.write('apelido', p.APELIDO);
            apex_json.write('cor', p.COR);
            apex_json.write('cedeu', p.FL_CEDEU = 'S');
            -- quem ganhou a carta teve a sequencia zerada; no ingresso ela aparece cheia
            apex_json.write('seguidas', case when p.FL_GANHOU_CARTA = 'S' then 3 else p.CEDEU_SEGUIDAS end);
            apex_json.write('ganhouCarta', p.FL_GANHOU_CARTA = 'S');
            apex_json.close_object;
        end loop;
        apex_json.close_array;
        apex_json.close_object;
    end escrever_resultado;

    function estado(p_id_sessao in number, p_versao_cliente in number default null) return clob is
        s        MMM_SESSAO%rowtype;
        l_me     number := MMM_PKG_SEGURANCA.id_membro_atual;
        l_json   clob;
        l_aberto boolean := false;
    begin
        sinal(p_id_sessao, l_me);
        begin
            select *
              into s
              from MMM_SESSAO
             where ID_SESSAO = p_id_sessao;
        exception
            when no_data_found then
                erro(c_err_acesso, 'Sessão não encontrada.');
        end;

        apex_json.initialize_clob_output;
        l_aberto := true;
        apex_json.open_object;
        apex_json.write('ok', true);
        apex_json.write('sessao', s.ID_SESSAO);
        apex_json.write('v', s.VERSAO);
        if p_versao_cliente = s.VERSAO then
            apex_json.write('mudou', false);
        else
            apex_json.write('mudou', true);
            apex_json.write('status', s.SITUACAO);
            apex_json.write('tipo', s.TIPO_TITULO);
            apex_json.write('regra', s.REGRA_MATCH);
            apex_json.write('final', s.TIPO_FINAL);
            -- segundos por carta no baralho (sem a chave: sem relogio)
            apex_json.write('relogio', relogio_de(s.FILTROS_JSON));
            apex_json.write('criador', s.ID_MEMBRO_CRIADOR);
            apex_json.write('demo', grupo_demo(s.ID_GRUPO) = 'S');
            -- a pagina 30 nao recebe nada da abertura: episodios, aluguel e servicos saem da sessao gravada
            apex_json.write('episodios', s.EPISODIOS);
            apex_json.write('aluguel', s.FL_ALUGUEL = 'S');
            apex_json.open_array('servicosSessao');
            for sv in (select jt.CODIGO
                         from json_table(s.FILTROS_JSON, '$.servicos[*]' columns (CODIGO varchar2(30) path '$')) jt) loop
                apex_json.write(sv.CODIGO);
            end loop;
            apex_json.close_array;
            escrever_presencas(s);
            escrever_eu(p_id_sessao, l_me);
            escrever_cartas(s);
            if s.TIPO_FINAL = 'DUELOS' and (s.SITUACAO = 'FINAL' or s.MODO_DESFECHO = 'DUELOS') then
                escrever_duelos(p_id_sessao, l_me);
            end if;
            if s.TIPO_FINAL = 'ROLETA' and (s.SITUACAO = 'FINAL' or s.MODO_DESFECHO = 'ROLETA') then
                escrever_roleta(s);
            end if;
            if s.SITUACAO = 'ENCERRADA' then
                escrever_resultado(s);
            end if;
        end if;
        apex_json.close_object;

        l_json := apex_json.get_clob_output;
        apex_json.free_output;
        return l_json;
    exception
        when others then
            if l_aberto then
                apex_json.free_output;
            end if;
            raise;
    end estado;

    function cartas_json(p_id_sessao in number) return clob is
        l_json   clob;
        l_aberto boolean := false;
        l_qtd    pls_integer;
    begin
        -- sessao de outro grupo (o VPD esconde) ou apagada: recusa como o ESTADO, em vez de devolver a lista vazia
        select count(*)
          into l_qtd
          from MMM_SESSAO
         where ID_SESSAO = p_id_sessao;
        if l_qtd = 0 then
            erro(c_err_acesso, 'Sessão não encontrada.');
        end if;
        apex_json.initialize_clob_output;
        l_aberto := true;
        apex_json.open_object;
        apex_json.write('ok', true);
        apex_json.open_array('cartas');
        for c in (select c.ID_CARTA, c.PIPOCAS, t.ID_TITULO, t.TITULO, t.TIPO, t.ANO, t.DURACAO_MIN, t.TEMPORADAS,
                         t.CLASSIFICACAO, t.NOTA, t.POSTER_PATH, t.FUNDO_PATH, t.SINOPSE_IDIOMA, t.TRAILER_CHAVE,
                         dbms_lob.substr(t.SINOPSE, 1500, 1) as SINOPSE,
                         m.APELIDO, m.COR
                    from MMM_SESSAO_CARTA c
                    join MMM_TITULO t
                      on t.ID_TITULO = c.ID_TITULO
                    left join MMM_MEMBRO m
                      on m.ID_GRUPO  = c.ID_GRUPO
                     and m.ID_MEMBRO = c.ID_MEMBRO_SUGERIU
                   where c.ID_SESSAO = p_id_sessao
                   order by c.ORDEM) loop
            apex_json.open_object;
            apex_json.write('id', c.ID_CARTA);
            apex_json.write('titulo', c.ID_TITULO);
            apex_json.write('nome', c.TITULO);
            apex_json.write('tipo', c.TIPO);
            apex_json.write('ano', c.ANO);
            apex_json.write('duracao', c.DURACAO_MIN);
            apex_json.write('temporadas', c.TEMPORADAS);
            apex_json.write('cls', c.CLASSIFICACAO);
            apex_json.write('nota', c.NOTA);
            apex_json.write('poster', c.POSTER_PATH);
            apex_json.write('fundo', c.FUNDO_PATH);
            apex_json.write('sinopse', c.SINOPSE);
            apex_json.write('sinopseIdioma', c.SINOPSE_IDIOMA);
            apex_json.write('trailer', c.TRAILER_CHAVE);
            apex_json.write('pipocas', c.PIPOCAS);
            apex_json.write('sugeriu', c.APELIDO);
            apex_json.write('cor', c.COR);
            -- nome, logo e categoria: a carta desenha os logos e separa o "so aluguel"
            apex_json.open_array('servicos');
            for s in (select sv.CODIGO,
                             sv.NOME,
                             sv.CATEGORIA,
                             (select max(pl.LOGO_PATH)
                                from MMM_PROVEDOR pl
                               where pl.ID_SERVICO      = sv.ID_SERVICO
                                 and pl.FL_LOGO_SERVICO = 'S') as LOGO
                        from MMM_SERVICO sv
                       where sv.FL_ATIVO = 'S'
                         and exists (select 1
                                       from MMM_DISPONIBILIDADE d
                                       join MMM_PROVEDOR p
                                         on p.ID_PROVEDOR = d.ID_PROVEDOR
                                      where d.ID_TITULO  = c.ID_TITULO
                                        and p.ID_SERVICO = sv.ID_SERVICO
                                        and ((sv.CATEGORIA = 'ASSINATURA' and d.TIPO_OFERTA in ('ASSINATURA', 'ANUNCIOS', 'GRATIS'))
                                          or (sv.CATEGORIA = 'LOJA' and d.TIPO_OFERTA in ('ALUGUEL', 'COMPRA'))))
                       order by sv.ORDEM) loop
                apex_json.open_object;
                apex_json.write('codigo', s.CODIGO);
                apex_json.write('nome', s.NOME);
                apex_json.write('logo', s.LOGO);
                apex_json.write('categoria', s.CATEGORIA);
                apex_json.close_object;
            end loop;
            apex_json.close_array;
            apex_json.close_object;
        end loop;
        apex_json.close_array;
        apex_json.close_object;

        l_json := apex_json.get_clob_output;
        apex_json.free_output;
        return l_json;
    exception
        when others then
            if l_aberto then
                apex_json.free_output;
            end if;
            raise;
    end cartas_json;

    procedure ajax is
        l_acao     varchar2(30);
        l_id       number;
        l_arg      number;
        l_texto    varchar2(32767);
        l_versao   number;
        l_json     clob;
        l_codigo   pls_integer;
        l_mensagem varchar2(4000);
        l_pilha    varchar2(4000);
        l_ativa    number;
    begin
        l_acao   := upper(substr(apex_application.g_x01, 1, 30));
        l_id     := numero(apex_application.g_x02);
        l_arg    := numero(apex_application.g_x03);
        l_texto  := apex_application.g_x04;
        l_versao := numero(apex_application.g_x05);

        -- jogada com id de sessao ja fica presa ao grupo pelo VPD; as que leem ou criam algo no grupo sem
        -- sessao conferem o grupo que a tela mostrou. As de sessao tambem, quando a tela manda o grupo: com o
        -- grupo trocado noutro aparelho o VPD esconde a sessao, e a mensagem certa e a de recarregar
        if l_acao in ('CONTAGENS', 'CRIAR', 'MINHA_VEZ')
           or (l_acao <> 'PUSH' and apex_application.g_x10 is not null) then
            MMM_PKG_SEGURANCA.exigir_grupo_da_tela(apex_application.g_x10);
        end if;

        case l_acao
            when 'ESTADO'    then null;
            when 'CARTAS'    then l_json := cartas_json(l_id);
            when 'CONTAGENS' then l_json := contagens(l_texto);
            when 'CRIAR'     then l_id := criar_sessao(l_texto);
            when 'MINHA_VEZ' then l_id := usar_minha_vez(l_arg);
            when 'ENTRAR'    then entrar(l_id);
            when 'VOTAR'     then votar(l_id, l_arg, upper(l_texto));
            when 'DESFAZER'  then desfazer(l_id, l_arg);
            when 'CONCLUIR'  then concluir_baralho(l_id);
            when 'SAIR'      then remover_presenca(l_id, eu);
            when 'REMOVER'   then remover_presenca(l_id, l_arg);
            when 'AVANCAR'   then avancar_final(l_id);
            when 'DUELO'     then votar_duelo(l_id, l_arg, upper(l_texto));
            when 'GIRAR'     then girar_roleta(l_id);
            when 'CANCELAR'  then cancelar(l_id);
            when 'CUTUCAR'   then cutucar(l_id);
            when 'PUSH'      then
                -- entrega ja o que CRIAR/CUTUCAR enfileiraram, sem esperar o job do APEX (~2 min)
                apex_pwa.push_queue;
                l_json := to_clob('{"ok":true}');
            else
                erro(c_err_parametro, 'Ação desconhecida.');
        end case;

        if l_json is null then
            -- depois de uma acao vai o estado inteiro; no polling, so se a versao do cliente ficou para tras
            l_json := estado(l_id, case when l_acao = 'ESTADO' then l_versao end);
        end if;
        commit;
        MMM_PKG_UTIL.imprimir_json(l_json);
    exception
        when others then
            l_codigo   := sqlcode;
            l_mensagem := sqlerrm;
            l_pilha    := substr(dbms_utility.format_error_stack || dbms_utility.format_error_backtrace, 1, 4000);
            rollback;
            if l_codigo = c_err_em_andamento then
                begin
                    l_ativa := sessao_aberta;
                exception
                    when others then
                        l_ativa := null;
                end;
            end if;
            apex_json.initialize_clob_output;
            apex_json.open_object;
            apex_json.write('ok', false);
            if l_codigo between -20999 and -20100 then
                apex_json.write('erro', case l_codigo
                                            when c_err_acesso       then 'acesso'
                                            when c_err_estado       then 'estado'
                                            when c_err_ordem        then 'ordem'
                                            when c_err_poder        then 'poder'
                                            when c_err_ja_votou     then 'ja_votou'
                                            when c_err_incompleto   then 'incompleto'
                                            when c_err_baralho      then 'baralho'
                                            when c_err_em_andamento then 'em_andamento'
                                            when c_err_ocupado      then 'ocupado'
                                            when c_err_carta_vez    then 'carta_vez'
                                            when c_err_aguarde      then 'aguarde'
                                            when c_err_parametro    then 'parametro'
                                            -- MMM_PKG_SEGURANCA.exigir_grupo_da_tela
                                            when -20107             then 'grupo'
                                            else 'negocio'
                                        end);
                apex_json.write('mensagem', regexp_substr(l_mensagem, 'ORA-20\d{3}: ([^' || chr(10) || ']*)', 1, 1, null, 1));
                apex_json.write('sessao', l_ativa);
            else
                -- o texto do Oracle fica no debug, nao na tela
                apex_debug.error('MMM_PKG_JOGO.ajax %s: %s', l_acao, l_pilha);
                apex_json.write('erro', 'interno');
                apex_json.write('mensagem', 'Não deu certo. Tente de novo.');
            end if;
            apex_json.close_object;
            l_json := apex_json.get_clob_output;
            apex_json.free_output;
            MMM_PKG_UTIL.imprimir_json(l_json);
    end ajax;

end MMM_PKG_JOGO;
/
