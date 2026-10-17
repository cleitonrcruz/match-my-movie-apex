create or replace package MMM_PKG_UTIL authid definer as

    -- id do app; fora de sessao APEX e o app dos jobs e do push
    c_app_id    constant number       := 103;
    c_workspace constant varchar2(30) := 'MMM';

    function app_id return number;
    function config(p_nome in varchar2, p_padrao in varchar2 default null) return varchar2;
    function url_publica(p_caminho in varchar2) return varchar2;
    procedure garantir_workspace;

    -- rotina de job (retencao, renovacao do TMDB): recusa rodar dentro do APEX ou por proxy
    procedure exigir_job_do_dono;

    function hoje_br return date;
    function iso(p_ts in timestamp with time zone) return varchar2;
    function de_unix(p_segundos in number) return date;
    function para_unix(p_data in date) return number;

    procedure enviar_push(
        p_id_usuario in number,
        p_titulo     in varchar2,
        p_corpo      in varchar2,
        p_caminho    in varchar2);

    procedure log_app(p_operacao in varchar2, p_quantidade in number default null, p_mensagem in varchar2 default null);

    -- resposta de Ajax Callback: JSON em pedacos de 8000 (htp.prn tem limite por chamada)
    procedure imprimir_json(p_json in clob);
    procedure responder_erro(p_sqlcode in number, p_sqlerrm in varchar2, p_pilha in varchar2);

end MMM_PKG_UTIL;
/

create or replace package body MMM_PKG_UTIL as

    function app_id return number is
        l_app number := to_number(v('APP_ID'));
    begin
        l_app := nvl(l_app, c_app_id);
        if l_app is null then
            raise_application_error(-20600, 'MMM_PKG_UTIL.c_app_id nao foi preenchido com o id do app.');
        end if;
        return l_app;
    end app_id;

    -- V() fora de sessao devolve nulo em silencio: a view funciona dentro e fora
    function config(p_nome in varchar2, p_padrao in varchar2 default null) return varchar2 is
        l_app   number := app_id;
        l_valor varchar2(4000);
    begin
        select max(SUBSTITUTION_VALUE)
          into l_valor
          from APEX_APPLICATION_SUBSTITUTIONS
         where APPLICATION_ID      = l_app
           and SUBSTITUTION_STRING = p_nome;
        return nvl(l_valor, p_padrao);
    end config;

    -- MMM_URL_PUBLICA termina em barra: https://<host>/ords/r/<workspace>/match-my-movie/
    -- Sem id de sessao: URL com sessao antiga troca o cookie e derruba a sessao viva; o Deep Linking leva a pagina
    function url_publica(p_caminho in varchar2) return varchar2 is
        l_base varchar2(400) := config('MMM_URL_PUBLICA');
    begin
        if l_base is null then
            raise_application_error(-20600, 'Substitution MMM_URL_PUBLICA nao configurada.');
        end if;
        return l_base || p_caminho;
    end url_publica;

    procedure garantir_workspace is
    begin
        apex_util.set_security_group_id(apex_util.find_security_group_id(p_workspace => c_workspace));
    end garantir_workspace;

    -- "em uso" sai de view com VPD: so vale como dono conectado direto ou job do scheduler, sem APEX e sem proxy.
    -- As tres condicoes sao necessarias: no run_job com use_current_session o scheduler troca o SESSION_USER
    -- para o dono. O job em segundo plano roda com o SESSION_USER de quem o criou (o ADMIN, na ATP)
    procedure exigir_job_do_dono is
    begin
        if sys_context('APEX$SESSION', 'APP_ID') is not null
           or sys_context('USERENV', 'PROXY_USER') is not null
           or (sys_context('USERENV', 'SESSION_USER') <> sys_context('USERENV', 'CURRENT_USER')
               and sys_context('USERENV', 'BG_JOB_ID') is null) then
            raise_application_error(-20620, 'Rotina de job: rode pelo DBMS_SCHEDULER, nunca no SQL Workshop.');
        end if;
    end exigir_job_do_dono;

    -- a ATP roda em UTC; o "hoje" das pessoas e o de Brasilia
    function hoje_br return date is
    begin
        return trunc(cast(systimestamp at time zone 'America/Sao_Paulo' as date));
    end hoje_br;

    -- o celular formata no fuso dele
    function iso(p_ts in timestamp with time zone) return varchar2 is
    begin
        return case when p_ts is not null then to_char(sys_extract_utc(p_ts), 'YYYY-MM-DD"T"HH24:MI:SS"Z"') end;
    end iso;

    -- o SA trata data de saida como dia de calendario em segundos Unix (UTC)
    function de_unix(p_segundos in number) return date is
    begin
        return trunc(date '1970-01-01' + p_segundos / 86400);
    end de_unix;

    function para_unix(p_data in date) return number is
    begin
        return round((trunc(p_data) - date '1970-01-01') * 86400);
    end para_unix;

    procedure enviar_push(
        p_id_usuario in number,
        p_titulo     in varchar2,
        p_corpo      in varchar2,
        p_caminho    in varchar2) is
        l_login  MMM_USUARIO.LOGIN%type;
        l_tipo   MMM_USUARIO.TIPO%type;
        l_app    number;
        l_versao varchar2(30);
    begin
        select LOGIN, TIPO
          into l_login, l_tipo
          from MMM_USUARIO
         where ID_USUARIO = p_id_usuario;
        -- robo e visitante nao tem push: o push e por usuario
        if l_tipo <> 'GOOGLE' then
            return;
        end if;
        l_app := app_id;
        -- fora de pagina o APEX_PWA exige o workspace; dentro da pagina a linha nao muda nada
        garantir_workspace;
        if apex_pwa.has_push_subscription(p_application_id => l_app, p_user_name => l_login) then
            -- sem p_icon_url o job do APEX monta o icone sem o /ords (404 na 26.1.0): vai o 192 pelo endereco publico,
            -- com a versao dos arquivos do app no caminho (o ORDS serve como imutavel)
            select to_char(max(FILES_VERSION))
              into l_versao
              from APEX_APPLICATIONS
             where APPLICATION_ID = l_app;
            -- URL absoluta: o sw.js do APEX nao abre caminho relativo. O aviso abre a
            -- entrada com o destino no fragmento: endereco com itens nunca reaproveita a sessao (Rejoin Sessions), e a
            -- entrada leva quem esta logado a pagina 1, que segue para o destino com a sessao de agora (mmm-inicio.js)
            apex_pwa.send_push_notification(
                p_application_id => l_app,
                p_user_name      => l_login,
                p_title          => substr(p_titulo, 1, 100),
                p_body           => substr(p_corpo, 1, 250),
                p_icon_url       => url_publica('files/static/v' || nvl(l_versao, '1') || '/icons/app-icon-192.png'),
                p_target_url     => url_publica('entrar#ir=' || utl_url.escape(p_caminho, true, 'UTF-8')));
        end if;
    exception
        when others then
            -- push nunca derruba a jogada; fora de pagina o erro aparece em APEX_DEBUG_MESSAGES com APPLICATION_ID nulo
            apex_debug.error('MMM_PKG_UTIL.enviar_push usuario %s: %s', p_id_usuario, sqlerrm);
            log_app('PUSH_ERRO', null, 'usuario ' || p_id_usuario || ': ' || sqlerrm);
    end enviar_push;

    procedure log_app(p_operacao in varchar2, p_quantidade in number default null, p_mensagem in varchar2 default null) is
        pragma autonomous_transaction;
    begin
        insert into MMM_INTEGRACAO_LOG (SISTEMA, OPERACAO, FL_ENVIADO, QUANTIDADE, MENSAGEM, SESSAO_APEX)
        values ('APP', substr(p_operacao, 1, 40), 'N', p_quantidade, substr(p_mensagem, 1, 2000), to_number(v('APP_SESSION')));
        commit;
    exception
        when others then
            rollback;
    end log_app;

    procedure imprimir_json(p_json in clob) is
        l_pos     pls_integer := 1;
        l_tamanho pls_integer := nvl(dbms_lob.getlength(p_json), 0);
    begin
        while l_pos <= l_tamanho loop
            sys.htp.prn(dbms_lob.substr(p_json, 8000, l_pos));
            l_pos := l_pos + 8000;
        end loop;
    end imprimir_json;

    procedure responder_erro(p_sqlcode in number, p_sqlerrm in varchar2, p_pilha in varchar2) is
        l_mensagem varchar2(4000);
    begin
        rollback;
        if p_sqlcode between -20999 and -20100 then
            l_mensagem := regexp_substr(p_sqlerrm, 'ORA-20\d{3}: ([^' || chr(10) || ']*)', 1, 1, null, 1);
        else
            -- o texto do Oracle fica no debug, nao na tela
            apex_debug.error('MMM callback: %s', p_pilha);
            l_mensagem := 'Não deu certo. Tente de novo.';
        end if;
        apex_json.initialize_clob_output;
        apex_json.open_object;
        apex_json.write('ok', false);
        apex_json.write('erro', case when p_sqlcode between -20999 and -20100 then 'negocio' else 'interno' end);
        apex_json.write('mensagem', l_mensagem);
        apex_json.close_object;
        imprimir_json(apex_json.get_clob_output);
        apex_json.free_output;
    end responder_erro;

end MMM_PKG_UTIL;
/

create or replace package MMM_PKG_HTTP authid definer as

    c_tmdb_base constant varchar2(100) := 'https://api.themoviedb.org/3';
    c_sa_base   constant varchar2(100) := 'https://api.movieofthenight.com/v4';
    c_cred_tmdb constant varchar2(60)  := 'mmm-tmdb';
    c_cred_sa   constant varchar2(60)  := 'mmm-sa';

    type t_resposta is record (
        status       number,
        corpo        clob,
        resultado    varchar2(12),
        retry_after  number);

    function escapar(p_valor in varchar2) return varchar2;

    -- resultado: OK, 4XX, 429, 5XX, TIMEOUT, REDE, ACL, CERTIFICADO, CIRCUITO (nao enviada), COTA (nao enviada)
    function chamar(
        p_sistema     in varchar2,
        p_operacao    in varchar2,
        p_caminho     in varchar2,
        p_timeout     in number      default 8,
        p_tentativas  in pls_integer default 2,
        p_espera_max  in number      default 2,
        p_id_titulo   in number      default null) return t_resposta;

    function requisicoes_sa_no_ciclo return number;
    function cota_sa_disponivel(p_reserva in number default 0) return boolean;
    function chamadas_da_sessao(p_sistema in varchar2, p_minutos in number) return number;
    -- consultas ao SA da pessoa logada no ciclo; 0 fora de sessao APEX (o job tem reserva propria)
    function chamadas_sa_da_pessoa return number;

end MMM_PKG_HTTP;
/

create or replace package body MMM_PKG_HTTP as

    function escapar(p_valor in varchar2) return varchar2 is
    begin
        return utl_url.escape(p_valor, true, 'UTF-8');
    end escapar;

    procedure registrar(
        p_sistema    in varchar2,
        p_operacao   in varchar2,
        p_url        in varchar2,
        p_enviado    in varchar2,
        p_tentativa  in number,
        p_status     in number,
        p_resultado  in varchar2,
        p_ms         in number,
        p_retry      in number,
        p_mensagem   in varchar2,
        p_id_titulo  in number) is
        pragma autonomous_transaction;
    begin
        insert into MMM_INTEGRACAO_LOG (
            SISTEMA, OPERACAO, URL, FL_ENVIADO, TENTATIVA, STATUS_HTTP, RESULTADO,
            DURACAO_MS, RETRY_AFTER, MENSAGEM, ID_TITULO, SESSAO_APEX)
        values (
            p_sistema, p_operacao, substr(p_url, 1, 1000), p_enviado, p_tentativa, p_status, p_resultado,
            p_ms, p_retry, substr(p_mensagem, 1, 2000), p_id_titulo, to_number(v('APP_SESSION')));
        commit;
    exception
        when others then
            -- o log e melhor esforco: falha aqui nao pode derrubar a integracao
            rollback;
    end registrar;

    function retry_after_do_header return number is
    begin
        for i in 1 .. apex_web_service.g_headers.count loop
            if lower(apex_web_service.g_headers(i).name) = 'retry-after' then
                return to_number(regexp_substr(apex_web_service.g_headers(i).value, '^[0-9]+'));
            end if;
        end loop;
        return null;
    end retry_after_do_header;

    function ms_desde(p_inicio in timestamp with time zone) return number is
        l_d interval day(3) to second(3) := systimestamp - p_inicio;
    begin
        return round(extract(day from l_d) * 86400000 + extract(hour from l_d) * 3600000
                   + extract(minute from l_d) * 60000 + extract(second from l_d) * 1000);
    end ms_desde;

    -- 5 falhas de rede/5xx em 2 minutos sem nenhum OK no meio: para de chamar por um tempo
    function circuito_aberto(p_sistema in varchar2) return boolean is
        l_falhas number;
        l_bloq   number;
        l_janela number;
    begin
        select count(*)
          into l_falhas
          from MMM_INTEGRACAO_LOG l
         where l.SISTEMA    = p_sistema
           and l.FL_ENVIADO = 'S'
           and l.RESULTADO  in ('5XX', 'TIMEOUT', 'REDE')
           and l.CRIADO_EM  > systimestamp - interval '2' minute
           and l.ID_LOG     > (select nvl(max(o.ID_LOG), 0)
                                 from MMM_INTEGRACAO_LOG o
                                where o.SISTEMA   = p_sistema
                                  and o.RESULTADO = 'OK'
                                  and o.CRIADO_EM > systimestamp - interval '2' minute);
        if l_falhas >= 5 then
            return true;
        end if;

        if p_sistema = 'SA' then
            -- 429 sem Retry-After so conta como cota esgotada quando o nosso contador ja esta perto do limite
            -- (6 horas); longe dele espera 5 minutos. O formato do 429 do SA ainda nao foi medido
            l_janela := case when cota_sa_disponivel(p_reserva => 50) then 5 else 360 end;
            select count(*)
              into l_bloq
              from MMM_INTEGRACAO_LOG l
             where l.SISTEMA     = 'SA'
               and l.STATUS_HTTP = 429
               and l.RETRY_AFTER is null
               and l.CRIADO_EM   > systimestamp - numtodsinterval(l_janela, 'MINUTE');
            return l_bloq > 0;
        end if;
        return false;
    end circuito_aberto;

    function chamar(
        p_sistema     in varchar2,
        p_operacao    in varchar2,
        p_caminho     in varchar2,
        p_timeout     in number      default 8,
        p_tentativas  in pls_integer default 2,
        p_espera_max  in number      default 2,
        p_id_titulo   in number      default null) return t_resposta is
        l_url    varchar2(4000);
        l_cred   varchar2(60);
        l_wallet varchar2(400);
        l_resp   t_resposta;
        l_inicio timestamp with time zone;
        l_erro   varchar2(1000);
    begin
        MMM_PKG_UTIL.garantir_workspace;
        l_wallet := MMM_PKG_UTIL.config('MMM_WALLET_PATH');

        if p_sistema = 'TMDB' then
            l_url  := c_tmdb_base || p_caminho;
            l_cred := c_cred_tmdb;
        elsif p_sistema = 'SA' then
            l_url  := c_sa_base || p_caminho;
            l_cred := c_cred_sa;
        else
            raise_application_error(-20600, 'Sistema desconhecido: ' || p_sistema);
        end if;

        if circuito_aberto(p_sistema) then
            l_resp.resultado := 'CIRCUITO';
            registrar(p_sistema, p_operacao, l_url, 'N', 1, null, l_resp.resultado, null, null,
                      'falhas seguidas: chamada nao enviada', p_id_titulo);
            return l_resp;
        end if;

        if p_sistema = 'SA' and not cota_sa_disponivel then
            l_resp.resultado := 'COTA';
            registrar(p_sistema, p_operacao, l_url, 'N', 1, null, l_resp.resultado, null, null,
                      'cota do ciclo esgotada', p_id_titulo);
            return l_resp;
        end if;

        for i in 1 .. greatest(p_tentativas, 1) loop
            l_erro             := null;
            l_resp.status      := null;
            l_resp.corpo       := null;
            l_resp.retry_after := null;

            -- g_request_headers e variavel de pacote: sem o delete, header de outra integracao vaza para esta
            apex_web_service.g_request_headers.delete;
            apex_web_service.g_request_headers(1).name  := 'Accept';
            apex_web_service.g_request_headers(1).value := 'application/json';

            l_inicio := systimestamp;
            begin
                l_resp.corpo := apex_web_service.make_rest_request(
                                    p_url                  => l_url,
                                    p_http_method          => 'GET',
                                    p_transfer_timeout     => p_timeout,
                                    p_wallet_path          => l_wallet,
                                    p_credential_static_id => l_cred);
                l_resp.status := apex_web_service.g_status_code;
            exception
                when others then
                    l_erro := substr(dbms_utility.format_error_stack, 1, 1000);
            end;

            l_resp.resultado :=
                case
                    when l_erro is not null and instr(l_erro, 'ORA-29276') > 0 then 'TIMEOUT'
                    when l_erro is not null and instr(l_erro, 'ORA-24247') > 0 then 'ACL'
                    when l_erro is not null and instr(l_erro, 'ORA-29024') > 0 then 'CERTIFICADO'
                    when l_erro is not null                                    then 'REDE'
                    when l_resp.status between 200 and 299                     then 'OK'
                    when l_resp.status = 429                                   then '429'
                    when l_resp.status >= 500                                  then '5XX'
                    else '4XX'
                end;

            if l_resp.resultado = '429' then
                l_resp.retry_after := retry_after_do_header;
            end if;

            registrar(p_sistema, p_operacao, l_url, 'S', i, l_resp.status, l_resp.resultado, ms_desde(l_inicio),
                      l_resp.retry_after,
                      case when l_resp.resultado <> 'OK' then nvl(l_erro, dbms_lob.substr(l_resp.corpo, 500, 1)) end,
                      p_id_titulo);

            exit when l_resp.resultado in ('OK', '4XX', 'ACL', 'CERTIFICADO') or i >= p_tentativas;

            if l_resp.resultado = '429' then
                exit when nvl(l_resp.retry_after, 1) > p_espera_max;
                dbms_session.sleep(nvl(l_resp.retry_after, 1));
            else
                dbms_session.sleep(least(0.5 * i, p_espera_max));
            end if;
        end loop;

        return l_resp;
    end chamar;

    function inicio_ciclo_sa return timestamp with time zone is
        l_dia  pls_integer := to_number(MMM_PKG_UTIL.config('MMM_SA_DIA_CICLO', '1'));
        l_hoje date        := trunc(cast(sys_extract_utc(systimestamp) as date));
        l_ini  date;
    begin
        l_ini := trunc(l_hoje, 'MM') + (least(greatest(l_dia, 1), 28) - 1);
        if l_ini > l_hoje then
            l_ini := add_months(l_ini, -1);
        end if;
        return from_tz(cast(l_ini as timestamp), 'UTC');
    end inicio_ciclo_sa;

    function requisicoes_sa_no_ciclo return number is
        l_ini timestamp with time zone := inicio_ciclo_sa;
        l_qtd number;
    begin
        select count(*)
          into l_qtd
          from MMM_INTEGRACAO_LOG
         where SISTEMA    = 'SA'
           and FL_ENVIADO = 'S'
           and CRIADO_EM >= l_ini;
        return l_qtd;
    end requisicoes_sa_no_ciclo;

    -- qualquer conta Google entra no app e a cota do SA e uma so: cada pessoa tem a sua fatia no ciclo.
    -- Conta pelo log, que guarda o APP_USER em CRIADO_POR: sair e entrar de novo nao zera
    function chamadas_sa_da_pessoa return number is
        l_login varchar2(255) := sys_context('APEX$SESSION', 'APP_USER');
        l_ini   timestamp with time zone;
        l_qtd   number;
    begin
        if l_login is null then
            return 0;   -- job: ja tem a reserva propria
        end if;
        -- inicio_ciclo_sa e privada do body e nao pode ir dentro do SQL (PLS-00231)
        l_ini := inicio_ciclo_sa;
        select count(*)
          into l_qtd
          from MMM_INTEGRACAO_LOG
         where SISTEMA    = 'SA'
           and FL_ENVIADO = 'S'
           and CRIADO_POR = l_login
           and CRIADO_EM >= l_ini;
        return l_qtd;
    end chamadas_sa_da_pessoa;

    function cota_sa_disponivel(p_reserva in number default 0) return boolean is
        l_limite number := to_number(MMM_PKG_UTIL.config('MMM_SA_LIMITE_MES', '1000'));
    begin
        -- 20 de folga: o contador daqui pode estar atras do da Movie of the Night
        return requisicoes_sa_no_ciclo + nvl(p_reserva, 0) + 20 < l_limite;
    end cota_sa_disponivel;

    function chamadas_da_sessao(p_sistema in varchar2, p_minutos in number) return number is
        l_sessao number := to_number(v('APP_SESSION'));
        l_desde  timestamp with time zone := systimestamp - numtodsinterval(p_minutos, 'MINUTE');
        l_qtd    number;
    begin
        if l_sessao is null then
            return 0;
        end if;
        select count(*)
          into l_qtd
          from MMM_INTEGRACAO_LOG
         where SESSAO_APEX = l_sessao
           and SISTEMA     = p_sistema
           and CRIADO_EM   > l_desde;
        return l_qtd;
    end chamadas_da_sessao;

end MMM_PKG_HTTP;
/
