create or replace package MMM_PKG_LEMBRAR authid definer as

    -- Lembrar de mim: o app abre na conta pelo aparelho lembrado, sem
    -- o Google, enquanto nao passarem 14 dias sem abrir nem 30 dias desde o ultimo Continuar com o Google com a caixa
    -- "Manter conectado neste aparelho" marcada. Unico pacote que le e grava MMM_LEMBRAR.

    -- Post-Authentication do GOOGLE, depois do registrar_login: o pedido da caixa (cookie curto) prepara a familia (1),
    -- esquece o aparelho (0) ou nao muda nada (sem pedido). Um erro aqui nao derruba o login
    procedure preparar;

    -- processo de aplicacao "Lembrar o aparelho" (On Load: Before Header, conta logada): emite, confirma, toca e re-envia
    procedure cuidar;

    -- processo Before Header da 9999 (sessao publica): entra na conta pelo aparelho lembrado
    procedure entrar_automatico;

    -- o pos_login_google pergunta se a Post-Authentication de agora e a da entrada automatica
    function entrada_em_curso return boolean;
    procedure pos_login;

    -- o aparelho tem uma familia viva (so le): a 9998 trata o aparelho lembrado como conectado
    function lembrado return boolean;

    -- todo Sair: este aparelho esquece a conta (a familia do cookie e as da sessao de agora) e o cookie sai apagado
    procedure esquecer_aparelho;

    -- o fim do Sair, depois do esquecer: a sessao acaba aqui e o navegador volta a entrada (o logout do esquema social do
    -- APEX responde em branco, sem o Location da Logout URL)
    procedure sair;

    -- Sair de todos os aparelhos (TODOS) e Excluir minha conta (EXCLUIR): as familias da conta logada e as outras sessoes
    -- dela no workspace
    procedure revogar_conta(p_motivo in varchar2);

    -- anonimizacao (MMM_PKG_RETENCAO, fora do APEX): as familias das contas que saem
    procedure apagar_contas(p_ids in apex_t_number);

    -- limpeza de hora em hora (MMM_PKG_RETENCAO, passo LEMBRAR)
    procedure expurgar(p_apagadas out pls_integer);

end MMM_PKG_LEMBRAR;
/

create or replace package body MMM_PKG_LEMBRAR as

    c_vida_seg      constant pls_integer := 2592000;  -- 30 dias desde o Continuar com o Google, fixos
    c_parado_seg    constant pls_integer := 1209600;  -- 14 dias sem abrir
    c_emissao_seg   constant pls_integer := 600;      -- a familia so e emitida nos 10 minutos depois do login
    c_voo_seg       constant pls_integer := 30;       -- emitida ha menos que isso, a emissao ainda esta a caminho
    c_folga_seg     constant pls_integer := 60;       -- o validador anterior vale 60 s depois da promocao
    c_toque_seg     constant pls_integer := 3600;     -- ULTIMO_USO_EM no maximo de hora em hora
    c_estado_seg    constant pls_integer := 10;       -- a entrada e a Post-Authentication dela, no mesmo pedido
    c_achar_seg     constant pls_integer := 120;      -- familia preparada noutra sessao (callback do Google)
    c_preparada_seg constant pls_integer := 86400;    -- preparada e nunca emitida: a limpeza apaga depois de um dia
    c_rotulo        constant varchar2(30) := 'MMM-LEMBRAR-CIFRA-1';
    c_formato       constant varchar2(40) := '^[0-9A-F]{32}\.[0-9A-F]{64}$';
    c_cifra         constant pls_integer := dbms_crypto.encrypt_aes256 + dbms_crypto.chain_cbc + dbms_crypto.pad_pkcs5;

    e_ocupado exception;
    pragma exception_init(e_ocupado, -30006);

    -- nomes dos cookies, do cookie do esquema do app (apex_custom_auth.get_cookie_props): MMM ou __Host-MMM
    g_aparelho varchar2(255);
    g_pedido   varchar2(255);
    g_sessao_c varchar2(255);
    g_seguro   boolean;

    -- estado da entrada automatica: preenchido e limpo no mesmo pedido
    g_id_lembrar number;
    g_id_usuario number;
    g_login      varchar2(255);
    g_sessao     number;
    g_hora       timestamp with time zone;
    g_vida_ate   timestamp with time zone;

    -- ---------- cookies ----------

    procedure nomes is
        l_nome   varchar2(255);
        l_path   varchar2(255);
        l_dom    varchar2(255);
        l_seguro boolean;
        l_base   varchar2(255);
    begin
        apex_custom_auth.get_cookie_props(p_app_id => MMM_PKG_UTIL.app_id, p_cookie_name => l_nome, p_cookie_path => l_path,
            p_cookie_domain => l_dom, p_secure => l_seguro);
        g_seguro   := nvl(l_seguro, false);
        g_sessao_c := l_nome;
        -- o nome nao comeca pelo do cookie da sessao nem usa o $P da autenticacao persistente do APEX
        l_base     := regexp_replace(l_nome, '^__Host-');
        g_aparelho := case when g_seguro then '__Host-' end || 'LEMBRAR_' || l_base;
        g_pedido   := case when g_seguro then '__Host-' end || 'LEMBRAR_PEDIDO_' || l_base;
    end nomes;

    function ler(p_nome in varchar2) return varchar2 is
        c owa_cookie.cookie;
    begin
        c := owa_cookie.get(p_nome);
        if c.num_vals = 0 then
            return null;
        end if;
        return c.vals(1);
    exception
        when others then
            return null;
    end ler;

    -- uma linha Set-Cookie crua, como o owa_cookie.send faz: o send nao tem SameSite nem Max-Age, converte o expires pelo
    -- fuso do OWA_CUSTOM (PST) e o remove nao apaga cookie __Host- (sem path nem secure)
    procedure escrever(p_nome in varchar2, p_valor in varchar2, p_segundos in number, p_http_only in boolean default true) is
    begin
        sys.htp.p('Set-Cookie: ' || p_nome || '=' || p_valor || '; Max-Age=' || greatest(nvl(trunc(p_segundos), 0), 0)
                  || '; Path=/' || case when p_http_only then '; HttpOnly' end || '; SameSite=Lax'
                  || case when g_seguro then '; Secure' end);
    end escrever;

    procedure apagar(p_nome in varchar2, p_http_only in boolean default true) is
    begin
        escrever(p_nome, '', 0, p_http_only);
    end apagar;

    -- ---------- validadores ----------

    function hash(p_valor in raw) return raw is
    begin
        return dbms_crypto.hash(p_valor, dbms_crypto.hash_sh256);
    end hash;

    -- a chave sai do validador que cifra; o banco guarda so o hash dele, entao quem le a tabela nao decifra
    function chave(p_validador in raw) return raw is
    begin
        return dbms_crypto.hash(utl_raw.concat(utl_raw.cast_to_raw(c_rotulo), p_validador), dbms_crypto.hash_sh256);
    end chave;

    function cifrar(p_valor in raw, p_com in raw) return raw is
        l_iv raw(16) := dbms_crypto.randombytes(16);
    begin
        return utl_raw.concat(l_iv, dbms_crypto.encrypt(src => p_valor, typ => c_cifra, key => chave(p_com), iv => l_iv));
    end cifrar;

    function decifrar(p_cifra in raw, p_com in raw) return raw is
    begin
        if p_cifra is null or p_com is null then
            return null;
        end if;
        return dbms_crypto.decrypt(src => utl_raw.substr(p_cifra, 17), typ => c_cifra, key => chave(p_com),
                                   iv => utl_raw.substr(p_cifra, 1, 16));
    exception
        when others then
            return null;
    end decifrar;

    -- qual validador da familia o navegador mandou
    function qual(r in MMM_LEMBRAR%rowtype, p_validador in raw) return varchar2 is
        l_h raw(32);
    begin
        if p_validador is null then
            return 'OUTRO';
        end if;
        l_h := hash(p_validador);
        if r.VALIDADOR_HASH = l_h then
            return 'ATUAL';
        elsif r.SUCESSOR_HASH = l_h then
            return 'SUCESSOR';
        elsif r.ANTERIOR_HASH = l_h and r.PROMOVIDO_EM > systimestamp - numtodsinterval(c_folga_seg, 'SECOND') then
            return 'ANTERIOR';
        end if;
        return 'OUTRO';
    end qual;

    function segundos_ate(p_ts in timestamp with time zone) return number is
        l_i interval day(9) to second(0) := p_ts - systimestamp;
    begin
        return extract(day from l_i) * 86400 + extract(hour from l_i) * 3600 + extract(minute from l_i) * 60
               + trunc(extract(second from l_i));
    end segundos_ate;

    -- o cookie do aparelho em seletor e validador; nulos fora do formato
    procedure partes(p_valor in varchar2, p_seletor out varchar2, p_validador out raw) is
    begin
        if p_valor is not null and regexp_like(p_valor, c_formato) then
            p_seletor   := substr(p_valor, 1, 32);
            p_validador := hextoraw(substr(p_valor, 34));
        end if;
    end partes;

    -- ---------- revogacao ----------

    -- numa transacao propria e so com a sessao ainda la: o delete_session de uma sessao que ja nao existe levanta o erro e
    -- desfaz a transacao de quem chamou, e a revogacao se perderia
    procedure encerrar(p_sessao in number) is
        pragma autonomous_transaction;
        l_existe pls_integer;
    begin
        if p_sessao is null or p_sessao = nvl(to_number(v('APP_SESSION')), -1) then
            return;
        end if;
        select count(*)
          into l_existe
          from APEX_WORKSPACE_SESSIONS
         where APEX_SESSION_ID = p_sessao;
        if l_existe > 0 then
            apex_session.delete_session(p_session_id => p_sessao);
        end if;
        commit;
    exception
        when others then
            -- a sessao acabou no meio; a que sobrar vai ao logout pelo cuidar na proxima pagina
            rollback;
    end encerrar;

    -- a linha fica ate o VIDA_ATE (o cuidar reconhece as sessoes dela), sem o login, os hashes e as cifras
    procedure revogar(p_id in number, p_motivo in varchar2, p_encerrar in boolean default false) is
        l_login_s  number;
        l_ultima_s number;
    begin
        update MMM_LEMBRAR
           set REVOGADO_EM      = systimestamp,
               MOTIVO           = p_motivo,
               LOGIN            = null,
               VALIDADOR_HASH   = null,
               SUCESSOR_HASH    = null,
               ANTERIOR_HASH    = null,
               SUCESSOR_CIFRADO = null,
               ANTERIOR_CIFRADO = null
         where ID_LEMBRAR  = p_id
           and REVOGADO_EM is null
        returning SESSAO_LOGIN, SESSAO_ULTIMA into l_login_s, l_ultima_s;
        if sql%rowcount = 1 and p_encerrar then
            encerrar(l_login_s);
            encerrar(l_ultima_s);
        end if;
    end revogar;

    -- a recusa da Post-Authentication vira pagina de erro do APEX, que limpa o pedido: a revogacao fica gravada
    procedure revogar_autonoma(p_id in number, p_motivo in varchar2) is
        pragma autonomous_transaction;
    begin
        revogar(p_id, p_motivo);
        commit;
    end revogar_autonoma;

    -- a familia do cookie do aparelho, com o validador conferido (atual, sucessor ou anterior), ou da propria conta logada
    procedure revogar_do_cookie(p_motivo in varchar2) is
        l_sel varchar2(32);
        l_v   raw(32);
        r     MMM_LEMBRAR%rowtype;
    begin
        partes(ler(g_aparelho), l_sel, l_v);
        if l_sel is null then
            return;
        end if;
        select * into r from MMM_LEMBRAR where SELETOR = l_sel and REVOGADO_EM is null;
        if qual(r, l_v) <> 'OUTRO' or r.ID_USUARIO = MMM_PKG_SEGURANCA.id_usuario_atual then
            revogar(r.ID_LEMBRAR, p_motivo);
        end if;
    exception
        when no_data_found then
            null;
    end revogar_do_cookie;

    procedure limpar_estado is
    begin
        g_id_lembrar := null;
        g_id_usuario := null;
        g_login      := null;
        g_sessao     := null;
        g_hora       := null;
        g_vida_ate   := null;
    end limpar_estado;

    -- ---------- nascimento ----------

    procedure preparar is
        l_id     number := MMM_PKG_SEGURANCA.id_usuario_atual;
        l_pedido varchar2(10);
        l_sel    varchar2(32);
        l_v      raw(32);
        r        MMM_LEMBRAR%rowtype;
    begin
        savepoint mmm_lembrar_preparar;
        if l_id is null or nvl(MMM_PKG_SEGURANCA.tipo_usuario_atual, '-') <> 'GOOGLE' then
            return;
        end if;
        nomes;
        l_pedido := ler(g_pedido);
        if l_pedido is not null then
            -- o cuidar apaga de novo na primeira pagina, se este Set-Cookie nao chegar
            apagar(g_pedido, p_http_only => false);
        end if;
        -- um aparelho tem uma familia: a de outra conta sai (TROCA); a desta conta sai com o pedido 0 (a caixa desmarcada
        -- esquece o aparelho) e com o 1 (a familia nova toma o lugar); sem pedido fica como esta
        partes(ler(g_aparelho), l_sel, l_v);
        if l_sel is not null then
            begin
                select * into r from MMM_LEMBRAR where SELETOR = l_sel and REVOGADO_EM is null for update wait 3;
                if qual(r, l_v) <> 'OUTRO' then
                    if r.ID_USUARIO <> l_id then
                        revogar(r.ID_LEMBRAR, 'TROCA');
                    elsif l_pedido = '0' then
                        revogar(r.ID_LEMBRAR, 'SAIR');
                    elsif l_pedido = '1' then
                        revogar(r.ID_LEMBRAR, 'TROCA');
                    end if;
                end if;
            exception
                when no_data_found then
                    null;
            end;
        end if;
        if l_pedido = '1' then
            insert into MMM_LEMBRAR (ID_USUARIO, LOGIN, SELETOR, SESSAO_LOGIN, LOGIN_GOOGLE_EM, VIDA_ATE, ULTIMO_USO_EM)
            values (l_id, sys_context('APEX$SESSION', 'APP_USER'), rawtohex(dbms_crypto.randombytes(16)),
                    to_number(v('APP_SESSION')), systimestamp, systimestamp + numtodsinterval(c_vida_seg, 'SECOND'), systimestamp);
        end if;
    exception
        when others then
            rollback to mmm_lembrar_preparar;
            MMM_PKG_UTIL.log_app('LEMBRAR_ERRO', l_id, substr('preparar: ' || sqlerrm, 1, 300));
    end preparar;

    -- ---------- com a sessao viva ----------

    -- a familia preparada no login desta sessao (ou, se o callback do Google gravou outra sessao, a mais nova da conta
    -- nos ultimos 2 minutos), nunca confirmada e ate 10 minutos depois do login
    function em_emissao(p_id_usuario in number, p_sessao in number) return number is
        l_id number;
    begin
        select max(ID_LEMBRAR) keep (dense_rank last order by LOGIN_GOOGLE_EM)
          into l_id
          from MMM_LEMBRAR
         where ID_USUARIO    = p_id_usuario
           and SESSAO_LOGIN  = p_sessao
           and REVOGADO_EM   is null
           and CONFIRMADO_EM is null
           and LOGIN_GOOGLE_EM > systimestamp - numtodsinterval(c_emissao_seg, 'SECOND');
        if l_id is null then
            select max(ID_LEMBRAR) keep (dense_rank last order by LOGIN_GOOGLE_EM)
              into l_id
              from MMM_LEMBRAR
             where ID_USUARIO    = p_id_usuario
               and EMITIDO_EM    is null
               and REVOGADO_EM   is null
               and LOGIN_GOOGLE_EM > systimestamp - numtodsinterval(c_achar_seg, 'SECOND');
        end if;
        return l_id;
    end em_emissao;

    -- o que o cuidar decide no banco, numa transacao propria: o pedido da pagina segue intacto. Devolve o valor do cookie
    -- a mandar (ou nulo) e se a sessao vai ao logout
    procedure cuidar_banco(p_id_usuario in number, p_sessao in number, p_cookie in varchar2,
                           p_mandar out varchar2, p_vida out timestamp with time zone, p_logout out boolean) is
        pragma autonomous_transaction;
        l_sel   varchar2(32);
        l_v     raw(32);
        l_manda raw(32);
        l_hash  raw(32);
        l_id    number;
        r       MMM_LEMBRAR%rowtype;
    begin
        p_logout := false;
        -- a sessao foi aberta por familia que caiu por roubo, Sair de todos, Excluir ou conta, ou pela entrada automatica
        -- depois do fim da vida
        for f in (select MOTIVO, VIDA_ATE, SESSAO_ULTIMA
                    from MMM_LEMBRAR
                   where ID_USUARIO = p_id_usuario
                     and (SESSAO_LOGIN = p_sessao or SESSAO_ULTIMA = p_sessao)) loop
            if f.MOTIVO in ('REUSO', 'TODOS', 'EXCLUIR', 'CONTA') or (f.SESSAO_ULTIMA = p_sessao and f.VIDA_ATE <= systimestamp) then
                p_logout := true;
            end if;
        end loop;
        if p_logout then
            rollback;
            return;
        end if;
        partes(p_cookie, l_sel, l_v);
        l_id := em_emissao(p_id_usuario, p_sessao);
        if l_id is not null then
            select * into r from MMM_LEMBRAR where ID_LEMBRAR = l_id for update wait 3;
            if l_sel = r.SELETOR and qual(r, l_v) = 'ATUAL' then
                update MMM_LEMBRAR set CONFIRMADO_EM = systimestamp where ID_LEMBRAR = l_id;
            else
                -- o navegador trouxe outra familia (um aparelho tem uma) ou nada: emite de novo, com o mesmo seletor
                if l_sel is not null and l_sel <> r.SELETOR then
                    for o in (select * from MMM_LEMBRAR where SELETOR = l_sel and REVOGADO_EM is null) loop
                        if qual(o, l_v) <> 'OUTRO' then
                            revogar(o.ID_LEMBRAR, 'TROCA');
                        end if;
                    end loop;
                end if;
                -- a emissao de ha pouco ainda esta a caminho: o service worker repete a navegacao e as duas chegam sem o
                -- cookie; emitir de novo trocaria o validador, e o navegador podia ficar com o de antes
                if r.EMITIDO_EM is null or r.EMITIDO_EM <= systimestamp - numtodsinterval(c_voo_seg, 'SECOND') then
                    l_manda := dbms_crypto.randombytes(32);
                    l_hash  := hash(l_manda);
                    update MMM_LEMBRAR
                       set VALIDADOR_HASH = l_hash,
                           EMITIDO_EM     = systimestamp,
                           SESSAO_LOGIN   = p_sessao
                     where ID_LEMBRAR = l_id;
                    p_mandar := r.SELETOR || '.' || rawtohex(l_manda);
                    p_vida   := r.VIDA_ATE;
                end if;
            end if;
            commit;
            return;
        end if;
        if l_sel is null then
            rollback;
            return;
        end if;
        begin
            select * into r from MMM_LEMBRAR where SELETOR = l_sel and REVOGADO_EM is null and ID_USUARIO = p_id_usuario for update wait 3;
        exception
            when no_data_found then
                rollback;
                return;
        end;
        case qual(r, l_v)
            when 'ATUAL' then
                if r.CONFIRMADO_EM is null or r.ULTIMO_USO_EM < systimestamp - numtodsinterval(c_toque_seg, 'SECOND') then
                    update MMM_LEMBRAR
                       set CONFIRMADO_EM    = nvl(CONFIRMADO_EM, systimestamp),
                           ULTIMO_USO_EM    = systimestamp,
                           ANTERIOR_CIFRADO = case when PROMOVIDO_EM > systimestamp - numtodsinterval(c_folga_seg, 'SECOND') then ANTERIOR_CIFRADO end
                     where ID_LEMBRAR = r.ID_LEMBRAR;
                end if;
                -- o sucessor que o navegador ainda nao viu vai de novo (o 302 da entrada pode ter perdido o cookie)
                if r.SUCESSOR_HASH is not null then
                    l_manda := decifrar(r.SUCESSOR_CIFRADO, l_v);
                end if;
            when 'SUCESSOR' then
                -- o atual vira o anterior por 60 s, com a cifra do novo atual feita com a chave dele
                update MMM_LEMBRAR
                   set ANTERIOR_HASH    = VALIDADOR_HASH,
                       ANTERIOR_CIFRADO = SUCESSOR_CIFRADO,
                       VALIDADOR_HASH   = SUCESSOR_HASH,
                       SUCESSOR_HASH    = null,
                       SUCESSOR_CIFRADO = null,
                       PROMOVIDO_EM     = systimestamp,
                       CONFIRMADO_EM    = nvl(CONFIRMADO_EM, systimestamp),
                       ULTIMO_USO_EM    = case when ULTIMO_USO_EM < systimestamp - numtodsinterval(c_toque_seg, 'SECOND')
                                               then systimestamp else ULTIMO_USO_EM end
                 where ID_LEMBRAR = r.ID_LEMBRAR;
            when 'ANTERIOR' then
                -- pedido que saiu antes de o cookie novo chegar: o atual vai de novo
                l_manda := decifrar(r.ANTERIOR_CIFRADO, l_v);
            else
                -- dentro da sessao nunca ha alarme: pedidos em voo trazem o cookie de antes
                null;
        end case;
        commit;
        if l_manda is not null then
            p_mandar := r.SELETOR || '.' || rawtohex(l_manda);
            p_vida   := r.VIDA_ATE;
        end if;
    exception
        when e_ocupado then
            -- outra pagina do mesmo aparelho segura a linha: fica para a proxima
            rollback;
        when others then
            rollback;
            MMM_PKG_UTIL.log_app('LEMBRAR_ERRO', p_id_usuario, substr('cuidar: ' || sqlerrm, 1, 300));
    end cuidar_banco;

    -- a sessao de familia que caiu acaba como no Sair (o logout do esquema social do APEX responde em branco)
    procedure ir_ao_logout is
    begin
        sair;
    end ir_ao_logout;

    procedure cuidar is
        l_id     number := MMM_PKG_SEGURANCA.id_usuario_atual;
        l_mandar varchar2(200);
        l_vida   timestamp with time zone;
        l_logout boolean;
    begin
        if l_id is null then
            return;
        end if;
        nomes;
        cuidar_banco(l_id, to_number(v('APP_SESSION')),
                     case when nvl(MMM_PKG_SEGURANCA.tipo_usuario_atual, '-') = 'GOOGLE' then ler(g_aparelho) end,
                     l_mandar, l_vida, l_logout);
        if l_logout then
            ir_ao_logout;
        end if;
        if nvl(MMM_PKG_SEGURANCA.tipo_usuario_atual, '-') <> 'GOOGLE' then
            return;
        end if;
        -- o pedido da caixa que sobrou da volta do Google
        if ler(g_pedido) is not null then
            apagar(g_pedido, p_http_only => false);
        end if;
        if l_mandar is not null then
            escrever(g_aparelho, l_mandar, segundos_ate(l_vida));
        end if;
    exception
        when apex_application.e_stop_apex_engine then
            raise;
        when others then
            MMM_PKG_UTIL.log_app('LEMBRAR_ERRO', l_id, substr('cuidar: ' || sqlerrm, 1, 300));
    end cuidar;

    -- ---------- sem sessao viva: a entrada automatica ----------

    -- so navegacao de pagina: o Sec-Fetch-Mode ausente ou navigate, e o destino nao declarado como moldura. A
    -- navegacao que o service worker do app repete chega com o destino empty
    function navegacao return boolean is
        l_modo varchar2(40) := lower(owa_util.get_cgi_env('Sec-Fetch-Mode'));
        l_dest varchar2(40) := lower(owa_util.get_cgi_env('Sec-Fetch-Dest'));
    begin
        if l_modo is not null and l_modo <> 'navigate' then
            return false;
        end if;
        return nvl(l_dest, '-') not in ('iframe', 'frame', 'embed', 'object');
    end navegacao;

    -- com o esquema VISITANTE, o post_login rodaria a pos_login_visitante com a conta Google
    function esquema_da_sessao return varchar2 is
        l_esquema varchar2(255);
    begin
        select max(s.SESSION_AUTHENTICATION_NAME)
          into l_esquema
          from APEX_WORKSPACE_SESSIONS s
         where s.APEX_SESSION_ID = to_number(v('APP_SESSION'));
        return l_esquema;
    end esquema_da_sessao;

    -- a decisao da entrada, numa transacao propria (a revogacao fica mesmo que a pagina caia depois). Devolve ENTRAR (com
    -- o validador a mandar, a conta e o fim da vida), APAGAR (a fachada, com o cookie apagado) ou FICAR (a fachada sem
    -- mexer em nada)
    procedure decidir_entrada(p_cookie in varchar2, p_decisao out varchar2, p_mandar out varchar2, p_id_lembrar out number,
                              p_id_usuario out number, p_login out varchar2, p_vida out timestamp with time zone) is
        pragma autonomous_transaction;
        l_sel   varchar2(32);
        l_v     raw(32);
        l_atual raw(32);
        l_manda raw(32);
        l_hash  raw(32);
        l_cifra raw(64);
        l_qual  varchar2(10);
        r       MMM_LEMBRAR%rowtype;
    begin
        partes(p_cookie, l_sel, l_v);
        begin
            select * into r from MMM_LEMBRAR where SELETOR = l_sel for update wait 3;
        exception
            when no_data_found then
                p_decisao := 'APAGAR';
                rollback;
                return;
        end;
        if r.REVOGADO_EM is not null then
            p_decisao := 'APAGAR';
            rollback;
            return;
        end if;
        if r.VIDA_ATE <= systimestamp or r.ULTIMO_USO_EM < systimestamp - numtodsinterval(c_parado_seg, 'SECOND') then
            revogar(r.ID_LEMBRAR, 'VENCIDO');
            commit;
            p_decisao := 'APAGAR';
            return;
        end if;
        l_qual := qual(r, l_v);
        if l_qual = 'ANTERIOR' then
            -- pedido que saiu antes de o cookie novo chegar: segue como se o atual tivesse vindo
            l_atual := decifrar(r.ANTERIOR_CIFRADO, l_v);
            if l_atual is not null and hash(l_atual) = r.VALIDADOR_HASH then
                l_qual := 'ATUAL';
                l_v    := l_atual;
            else
                l_qual := 'OUTRO';
            end if;
        end if;
        case l_qual
            when 'ATUAL' then
                -- troca idempotente: quem traz o atual recebe sempre o mesmo sucessor
                if r.SUCESSOR_HASH is null then
                    l_manda := dbms_crypto.randombytes(32);
                    l_hash  := hash(l_manda);
                    l_cifra := cifrar(l_manda, l_v);
                    update MMM_LEMBRAR
                       set SUCESSOR_HASH    = l_hash,
                           SUCESSOR_CIFRADO = l_cifra
                     where ID_LEMBRAR = r.ID_LEMBRAR;
                else
                    l_manda := decifrar(r.SUCESSOR_CIFRADO, l_v);
                end if;
            when 'SUCESSOR' then
                -- o aparelho recebeu o sucessor e nao abriu pagina desde entao: promove e sorteia o proximo
                l_manda := dbms_crypto.randombytes(32);
                l_hash  := hash(l_manda);
                l_cifra := cifrar(l_manda, l_v);
                update MMM_LEMBRAR
                   set ANTERIOR_HASH    = VALIDADOR_HASH,
                       ANTERIOR_CIFRADO = SUCESSOR_CIFRADO,
                       VALIDADOR_HASH   = SUCESSOR_HASH,
                       PROMOVIDO_EM     = systimestamp,
                       SUCESSOR_HASH    = l_hash,
                       SUCESSOR_CIFRADO = l_cifra
                 where ID_LEMBRAR = r.ID_LEMBRAR;
            else
                if r.CONFIRMADO_EM is not null then
                    -- copia do cookie usada noutro lugar: cai a familia copiada e as sessoes dela
                    revogar(r.ID_LEMBRAR, 'REUSO', p_encerrar => true);
                    MMM_PKG_UTIL.log_app('LEMBRAR_REUSO', r.ID_USUARIO, 'familia ' || r.ID_LEMBRAR);
                else
                    -- emissoes sobrepostas no comeco: sem alarme
                    revogar(r.ID_LEMBRAR, 'INVALIDO');
                    MMM_PKG_UTIL.log_app('LEMBRAR_INVALIDO', r.ID_USUARIO, 'familia ' || r.ID_LEMBRAR);
                end if;
                commit;
                p_decisao := 'APAGAR';
                return;
        end case;
        if l_manda is null then
            raise_application_error(-20108, 'A cifra do sucessor nao abriu.');
        end if;
        update MMM_LEMBRAR
           set ULTIMO_USO_EM    = systimestamp,
               CONFIRMADO_EM    = nvl(CONFIRMADO_EM, systimestamp),
               ANTERIOR_CIFRADO = case when PROMOVIDO_EM > systimestamp - numtodsinterval(c_folga_seg, 'SECOND') then ANTERIOR_CIFRADO end
         where ID_LEMBRAR = r.ID_LEMBRAR;
        commit;
        p_decisao    := 'ENTRAR';
        p_mandar     := l_sel || '.' || rawtohex(l_manda);
        p_id_lembrar := r.ID_LEMBRAR;
        p_id_usuario := r.ID_USUARIO;
        p_login      := r.LOGIN;
        p_vida       := r.VIDA_ATE;
    exception
        when e_ocupado then
            -- a fila passou de 3 s: outra entrada do mesmo aparelho segura a linha; desta vez fica a fachada
            rollback;
            p_decisao := 'FICAR';
        when others then
            rollback;
            if r.ID_LEMBRAR is not null then
                revogar(r.ID_LEMBRAR, 'ERRO');
                commit;
            end if;
            MMM_PKG_UTIL.log_app('LEMBRAR_ERRO', r.ID_USUARIO, substr('entrada: ' || sqlerrm, 1, 300));
            p_decisao := 'APAGAR';
    end decidir_entrada;

    procedure entrar_automatico is
        l_esquema    varchar2(255);
        l_cookie     varchar2(4000);
        l_decisao    varchar2(10);
        l_mandar     varchar2(200);
        l_id_lembrar number;
        l_id_usuario number;
        l_login      varchar2(255);
        l_vida       timestamp with time zone;
    begin
        nomes;
        -- 1. volta do logout (a rede do Sair): o APEX so manda o cookie da sessao com -1 no logout
        if ler(g_sessao_c) = '-1' then
            revogar_do_cookie('SAIR');
            commit;
            if ler(g_aparelho) is not null then
                apagar(g_aparelho);
            end if;
            return;
        end if;
        l_cookie := ler(g_aparelho);
        -- 2. sem cookie do aparelho; 3. fora do formato
        if l_cookie is null then
            return;
        elsif not regexp_like(l_cookie, c_formato) then
            apagar(g_aparelho);
            return;
        end if;
        -- 4. so navegacao de pagina; 5. so na sessao publica do esquema GOOGLE (ou nulo). Nos dois, nada muda
        if not navegacao then
            return;
        end if;
        -- o esquema da sessao publica e nulo (o GOOGLE, que e o atual) ou GOOGLE; outro (o VISITANTE) rodaria a
        -- Post-Authentication dele no post_login. A sessao aberta aqui fica sem esquema gravado: todo Sair do app acaba a
        -- sessao pelo MMM_PKG_LEMBRAR.sair, sem depender da Logout URL do esquema
        l_esquema := esquema_da_sessao;
        if nvl(l_esquema, 'GOOGLE') <> 'GOOGLE' then
            return;
        end if;
        -- 6 e 7. a familia e o validador
        decidir_entrada(l_cookie, l_decisao, l_mandar, l_id_lembrar, l_id_usuario, l_login, l_vida);
        if l_decisao = 'APAGAR' then
            apagar(g_aparelho);
            return;
        elsif l_decisao <> 'ENTRAR' then
            return;
        end if;
        -- 8. entrar: o cookie novo vai no 302 do post_login, e a Post-Authentication do GOOGLE desvia para o
        -- pos_login deste pacote enquanto o estado vale
        escrever(g_aparelho, l_mandar, segundos_ate(l_vida));
        g_id_lembrar := l_id_lembrar;
        g_id_usuario := l_id_usuario;
        g_login      := l_login;
        g_sessao     := to_number(v('APP_SESSION'));
        g_hora       := systimestamp;
        g_vida_ate   := l_vida;
        apex_authentication.post_login(p_username => l_login);
        limpar_estado;
        -- o post_login escreve o redirecionamento e volta: o pedido acaba aqui
        apex_application.stop_apex_engine;
    exception
        when apex_application.e_stop_apex_engine then
            limpar_estado;
            raise;
        when others then
            limpar_estado;
            if l_id_lembrar is not null then
                revogar_autonoma(l_id_lembrar, 'ERRO');
            end if;
            MMM_PKG_UTIL.log_app('LEMBRAR_ERRO', l_id_usuario, substr('entrada: ' || sqlerrm, 1, 300));
            apagar(g_aparelho);
    end entrar_automatico;

    function entrada_em_curso return boolean is
    begin
        return g_login is not null
           and sys_context('APEX$SESSION', 'APP_USER') = g_login
           and to_number(v('APP_SESSION')) = g_sessao
           and systimestamp - g_hora < numtodsinterval(c_estado_seg, 'SECOND');
    end entrada_em_curso;

    procedure pos_login is
        l_id         MMM_USUARIO.ID_USUARIO%type;
        l_tipo       MMM_USUARIO.TIPO%type;
        l_email      MMM_USUARIO.EMAIL%type;
        l_nome       MMM_USUARIO.NOME%type;
        l_sub        MMM_USUARIO.GOOGLE_SUB%type;
        l_exclusao   MMM_USUARIO.EXCLUSAO_PEDIDA_EM%type;
        l_id_lembrar number := g_id_lembrar;
        l_vida       timestamp with time zone := g_vida_ate;
    begin
        -- a propria linha, que o VPD deixa ler pelo APP_USER; nada do apex_json do Google
        begin
            select ID_USUARIO, TIPO, EMAIL, NOME, GOOGLE_SUB, EXCLUSAO_PEDIDA_EM
              into l_id, l_tipo, l_email, l_nome, l_sub, l_exclusao
              from MMM_USUARIO
             where LOGIN = g_login;
        exception
            when no_data_found then
                l_id := null;
        end;
        if l_id is null or l_id <> g_id_usuario or l_tipo <> 'GOOGLE' or l_exclusao is not null then
            -- conta que saiu do ar sem a familia cair antes (so por defesa): nenhuma entrada automatica desfaz o Excluir
            limpar_estado;
            revogar_autonoma(l_id_lembrar, 'CONTA');
            raise_application_error(-20108, 'Entre de novo com o Google.');
        end if;
        MMM_PKG_SEGURANCA.registrar_login(p_tipo => 'GOOGLE', p_email => l_email, p_nome => l_nome, p_google_sub => l_sub);
        -- a sessao aberta pelo aparelho acaba no fim da vida da familia
        apex_util.set_session_lifetime_seconds(p_seconds => greatest(segundos_ate(l_vida), 60));
        update MMM_LEMBRAR
           set SESSAO_ULTIMA = to_number(v('APP_SESSION'))
         where ID_LEMBRAR = l_id_lembrar;
        limpar_estado;
        commit;
    end pos_login;

    -- ---------- leitura, Sair, Sair de todos e Excluir ----------

    function lembrado return boolean is
        l_sel varchar2(32);
        l_v   raw(32);
        r     MMM_LEMBRAR%rowtype;
    begin
        nomes;
        partes(ler(g_aparelho), l_sel, l_v);
        if l_sel is null then
            return false;
        end if;
        select * into r from MMM_LEMBRAR
         where SELETOR = l_sel
           and REVOGADO_EM is null
           and VIDA_ATE > systimestamp
           and ULTIMO_USO_EM > systimestamp - numtodsinterval(c_parado_seg, 'SECOND');
        return qual(r, l_v) <> 'OUTRO';
    exception
        when no_data_found then
            return false;
    end lembrado;

    procedure esquecer_aparelho is
        l_sessao number := to_number(v('APP_SESSION'));
    begin
        nomes;
        revogar_do_cookie('SAIR');
        for f in (select ID_LEMBRAR
                    from MMM_LEMBRAR
                   where REVOGADO_EM is null
                     and (SESSAO_LOGIN = l_sessao or SESSAO_ULTIMA = l_sessao)) loop
            revogar(f.ID_LEMBRAR, 'SAIR');
        end loop;
        apagar(g_aparelho);
    end esquecer_aparelho;

    procedure sair is
        l_sessao  number := to_number(v('APP_SESSION'));
        l_entrada varchar2(4000) := apex_page.get_url(p_page => 9999);
    begin
        nomes;
        -- como o logout do APEX: o cookie da sessao com -1, que a entrada reconhece como a volta do Sair
        sys.htp.p('Set-Cookie: ' || g_sessao_c || '=-1; path=/; samesite=lax; HttpOnly' || case when g_seguro then '; Secure' end);
        apex_session.delete_session(p_session_id => l_sessao);
        -- sem o commit, o fim do pedido pelo stop_apex_engine desfaz o delete e a sessao continua viva no banco
        commit;
        apex_util.redirect_url(p_url => l_entrada, p_reset_htp_buffer => false);
        apex_application.stop_apex_engine;
    end sair;

    procedure revogar_conta(p_motivo in varchar2) is
        l_id     number := MMM_PKG_SEGURANCA.id_usuario_atual;
        l_login  varchar2(255) := sys_context('APEX$SESSION', 'APP_USER');
        l_sessao number := to_number(v('APP_SESSION'));
    begin
        if p_motivo not in ('TODOS', 'EXCLUIR') or l_id is null then
            raise_application_error(-20108, 'Saida de todos os aparelhos sem conta ou com motivo invalido.');
        end if;
        for f in (select ID_LEMBRAR from MMM_LEMBRAR where ID_USUARIO = l_id and REVOGADO_EM is null) loop
            revogar(f.ID_LEMBRAR, p_motivo, p_encerrar => true);
        end loop;
        -- tambem as sessoes que nao vieram do aparelho lembrado (a de agora sai pela porta de saida da 9999, no branch)
        for s in (select APEX_SESSION_ID
                    from APEX_WORKSPACE_SESSIONS
                   where USER_NAME         = l_login
                     and SESSION_TENANT_ID = to_char(l_id)
                     and APEX_SESSION_ID  <> l_sessao) loop
            encerrar(s.APEX_SESSION_ID);
        end loop;
        nomes;
        apagar(g_aparelho);
    end revogar_conta;

    procedure apagar_contas(p_ids in apex_t_number) is
    begin
        delete from MMM_LEMBRAR
         where ID_USUARIO in (select column_value from table(p_ids));
    end apagar_contas;

    procedure expurgar(p_apagadas out pls_integer) is
    begin
        delete from MMM_LEMBRAR
         where VIDA_ATE < systimestamp
            or ULTIMO_USO_EM < systimestamp - numtodsinterval(c_parado_seg, 'SECOND')
            or (EMITIDO_EM is null and LOGIN_GOOGLE_EM < systimestamp - numtodsinterval(c_preparada_seg, 'SECOND'));
        p_apagadas := sql%rowcount;
        -- a cifra do atual feita com a chave do anterior so vale 60 s depois da promocao
        update MMM_LEMBRAR
           set ANTERIOR_CIFRADO = null
         where ANTERIOR_CIFRADO is not null
           and PROMOVIDO_EM < systimestamp - numtodsinterval(c_folga_seg, 'SECOND');
    end expurgar;

end MMM_PKG_LEMBRAR;
/
