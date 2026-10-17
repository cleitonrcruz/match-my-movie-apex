create or replace package MMM_PKG_GRUPO authid definer as

    -- tudo aqui age sobre o grupo ATIVO de quem esta logado; o cliente nunca diz qual e o grupo

    function normalizar_codigo(p_codigo in varchar2) return varchar2;
    function link_convite(p_codigo in varchar2) return varchar2;

    function obter_convite return varchar2;
    function gerar_convite(p_dias in number default 7, p_usos_maximos in number default null) return varchar2;
    procedure revogar_convites;

    -- devolve o ID_GRUPO em que a pessoa entrou (e que vira o ativo)
    function aceitar_convite(p_codigo in varchar2) return number;

    procedure renomear(p_nome in varchar2);
    procedure transferir_dono(p_id_membro_novo in number);
    procedure remover_membro(p_id_membro in number);
    procedure sair_do_grupo(p_id_membro_novo_dono in number default null);

    -- so o dono de agora, fora da demo: o grupo acaba para todos com lista, sessoes e historico, e cada membro passa ao
    -- ultimo grupo em que entrou (ou a Meus grupos) na proxima pagina que abrir
    procedure excluir_grupo;

end MMM_PKG_GRUPO;
/

create or replace package body MMM_PKG_GRUPO as

    c_dias_convite  constant pls_integer := 7;
    c_max_dias      constant pls_integer := 30;
    c_max_membros   constant pls_integer := 20;
    c_alfabeto      constant varchar2(32 char) := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

    type t_membro is record (
        id_membro  MMM_MEMBRO.ID_MEMBRO%type,
        id_grupo   MMM_MEMBRO.ID_GRUPO%type,
        papel      MMM_MEMBRO.PAPEL%type,
        apelido    MMM_MEMBRO.APELIDO%type,
        fl_demo    MMM_GRUPO.FL_DEMO%type,
        nome_grupo MMM_GRUPO.NOME%type);

    function eu return t_membro is
        r t_membro;
    begin
        select m.ID_MEMBRO, m.ID_GRUPO, m.PAPEL, m.APELIDO, g.FL_DEMO, g.NOME
          into r.id_membro, r.id_grupo, r.papel, r.apelido, r.fl_demo, r.nome_grupo
          from MMM_MEMBRO m
          join MMM_GRUPO g
            on g.ID_GRUPO = m.ID_GRUPO
         where m.ID_MEMBRO = MMM_PKG_SEGURANCA.id_membro_atual;
        return r;
    exception
        when no_data_found then
            raise_application_error(-20201, 'Escolha um grupo antes.');
    end eu;

    procedure exigir_dono(r in t_membro) is
    begin
        if r.papel <> 'DONO' then
            raise_application_error(-20202, 'Só o dono do grupo pode fazer isso.');
        elsif r.fl_demo = 'S' then
            raise_application_error(-20203, 'O grupo da demonstração não aceita convites nem mudanças de membros.');
        end if;
    end exigir_dono;

    function novo_codigo return varchar2 is
        l_bytes  raw(8) := dbms_crypto.randombytes(8);
        l_codigo varchar2(8 char);
    begin
        -- 256 e multiplo de 32: cada byte vira um caractere sem vies
        for i in 1 .. 8 loop
            l_codigo := l_codigo
                     || substr(c_alfabeto, mod(to_number(rawtohex(utl_raw.substr(l_bytes, i, 1)), 'XX'), 32) + 1, 1);
        end loop;
        return l_codigo;
    end novo_codigo;

    function normalizar_codigo(p_codigo in varchar2) return varchar2 is
    begin
        -- aceita "k7q2-9fmx", com espaco, ou o link inteiro colado (o codigo e o fim do link)
        return regexp_substr(translate(upper(trim(p_codigo)), 'X- ', 'X'), '[A-HJ-NP-Z2-9]{8}$');
    end normalizar_codigo;

    -- MMM_URL_CONVITE: https://mmm.cleitonrcruz.com.br/c/ (atalho do Worker) ou a URL da pagina 50 com ?p50_codigo=
    -- Nunca com id de sessao: URL com sessao antiga troca o cookie e derruba a sessao viva do navegador
    function link_convite(p_codigo in varchar2) return varchar2 is
    begin
        return MMM_PKG_UTIL.config('MMM_URL_CONVITE') || p_codigo;
    end link_convite;

    procedure revogar_ativos(p_id_grupo in number) is
    begin
        update MMM_CONVITE
           set REVOGADO_EM = systimestamp
         where ID_GRUPO    = p_id_grupo
           and REVOGADO_EM is null
           and EXPIRA_EM   > systimestamp;
    end revogar_ativos;

    function gerar_convite(p_dias in number default 7, p_usos_maximos in number default null) return varchar2 is
        r        t_membro := eu;
        l_codigo MMM_CONVITE.CODIGO%type;
    begin
        exigir_dono(r);
        -- um link ativo por grupo: gerar outro invalida o anterior
        revogar_ativos(r.id_grupo);
        for i in 1 .. 5 loop
            begin
                l_codigo := novo_codigo;
                insert into MMM_CONVITE (ID_GRUPO, ID_MEMBRO_CRIADOR, CODIGO, TEXTO_CONVITE, EXPIRA_EM, USOS_MAXIMOS)
                values (r.id_grupo,
                        r.id_membro,
                        l_codigo,
                        substr(r.apelido || ' chamou você para o grupo ' || r.nome_grupo, 1, 200),
                        systimestamp + numtodsinterval(least(greatest(nvl(p_dias, c_dias_convite), 1), c_max_dias), 'DAY'),
                        p_usos_maximos);
                return l_codigo;
            exception
                when dup_val_on_index then
                    null;  -- codigo repetido: sorteia outro
            end;
        end loop;
        raise_application_error(-20204, 'Não foi possível gerar o convite. Tente de novo.');
    end gerar_convite;

    function obter_convite return varchar2 is
        r        t_membro := eu;
        l_codigo MMM_CONVITE.CODIGO%type;
    begin
        exigir_dono(r);
        select max(CODIGO) keep (dense_rank last order by CRIADO_EM, ID_CONVITE)
          into l_codigo
          from MMM_CONVITE
         where ID_GRUPO    = r.id_grupo
           and REVOGADO_EM is null
           and EXPIRA_EM   > systimestamp
           and (USOS_MAXIMOS is null or USOS < USOS_MAXIMOS);
        -- coalesce e nao nvl: o nvl calcula os dois lados, e o gerar_convite revogaria o link que ainda vale
        return coalesce(l_codigo, gerar_convite);
    end obter_convite;

    procedure revogar_convites is
        r t_membro := eu;
    begin
        exigir_dono(r);
        revogar_ativos(r.id_grupo);
    end revogar_convites;

    function aceitar_convite(p_codigo in varchar2) return number is
        l_id_usuario number := MMM_PKG_SEGURANCA.id_usuario_atual;
        l_codigo     MMM_CONVITE.CODIGO%type := normalizar_codigo(p_codigo);
        l_convite    MMM_CONVITE%rowtype;
        l_situacao   MMM_MEMBRO.SITUACAO%type;
        l_id_membro  MMM_MEMBRO.ID_MEMBRO%type;
        l_nome       MMM_USUARIO.NOME%type;
        l_qtd        pls_integer;
        l_cor        number;
    begin
        if MMM_PKG_SEGURANCA.tipo_usuario_atual <> 'GOOGLE' then
            raise_application_error(-20205, 'Na demonstração não dá para entrar em grupos de verdade. Entre com sua conta Google.');
        end if;

        begin
            select *
              into l_convite
              from MMM_CONVITE
             where CODIGO = l_codigo
               for update;
        exception
            when no_data_found then
                raise_application_error(-20206, 'Convite não encontrado. Confira o código.');
        end;

        -- a propria filiacao e visivel pela politica de MMM_MEMBRO mesmo com o grupo ainda nao ativo
        select max(SITUACAO), max(ID_MEMBRO)
          into l_situacao, l_id_membro
          from MMM_MEMBRO
         where ID_GRUPO   = l_convite.ID_GRUPO
           and ID_USUARIO = l_id_usuario;

        -- quem ja esta no grupo so passa a ve-lo, sem gastar uso do convite
        if l_situacao = 'ATIVO' then
            MMM_PKG_SEGURANCA.ativar_grupo(l_convite.ID_GRUPO);
            return l_convite.ID_GRUPO;
        end if;

        if l_convite.REVOGADO_EM is not null then
            raise_application_error(-20207, 'Este convite foi cancelado. Peça um link novo a quem te chamou.');
        elsif l_convite.EXPIRA_EM <= systimestamp then
            raise_application_error(-20208, 'Este convite expirou. Peça um link novo a quem te chamou.');
        elsif l_convite.USOS_MAXIMOS is not null and l_convite.USOS >= l_convite.USOS_MAXIMOS then
            raise_application_error(-20209, 'Este convite já foi usado o máximo de vezes.');
        end if;

        select NOME
          into l_nome
          from MMM_USUARIO
         where ID_USUARIO = l_id_usuario;

        savepoint antes_de_entrar;

        if l_situacao = 'SAIU' then
            update MMM_MEMBRO
               set SITUACAO = 'ATIVO',
                   SAIU_EM  = null,
                   PAPEL    = 'MEMBRO',
                   ENTROU_EM = systimestamp
             where ID_MEMBRO = l_id_membro;
        else
            insert into MMM_MEMBRO (ID_GRUPO, ID_USUARIO, APELIDO, PAPEL)
            values (l_convite.ID_GRUPO, l_id_usuario,
                    substr(coalesce(regexp_substr(l_nome, '^\S+'), 'Sem nome'), 1, 30), 'MEMBRO');
        end if;

        MMM_PKG_SEGURANCA.ativar_grupo(l_convite.ID_GRUPO);

        -- so agora o grupo e visivel: conta quem esta nele e escolhe uma cor livre
        select count(*)
          into l_qtd
          from MMM_MEMBRO
         where ID_GRUPO = l_convite.ID_GRUPO
           and SITUACAO = 'ATIVO';
        if l_qtd > c_max_membros then
            rollback to antes_de_entrar;
            raise_application_error(-20210, 'O grupo já está com ' || c_max_membros || ' pessoas.');
        end if;

        select nvl(min(n.COR), 1)
          into l_cor
          from (select level as COR from dual connect by level <= 8) n
         where n.COR not in (select m.COR
                               from MMM_MEMBRO m
                              where m.ID_GRUPO   = l_convite.ID_GRUPO
                                and m.SITUACAO   = 'ATIVO'
                                and m.ID_USUARIO <> l_id_usuario);

        update MMM_MEMBRO
           set COR = l_cor
         where ID_GRUPO   = l_convite.ID_GRUPO
           and ID_USUARIO = l_id_usuario;

        update MMM_CONVITE
           set USOS = USOS + 1
         where ID_CONVITE = l_convite.ID_CONVITE;

        return l_convite.ID_GRUPO;
    end aceitar_convite;

    procedure renomear(p_nome in varchar2) is
        r t_membro := eu;
    begin
        exigir_dono(r);
        if trim(p_nome) is null then
            raise_application_error(-20211, 'Dê um nome ao grupo.');
        end if;
        update MMM_GRUPO
           set NOME = substr(trim(p_nome), 1, 60)
         where ID_GRUPO = r.id_grupo;
    end renomear;

    procedure passar_dono(p_id_grupo in number, p_de in number, p_para in number) is
    begin
        -- nessa ordem: o indice unico aceita um dono ativo por grupo
        update MMM_MEMBRO
           set PAPEL = 'MEMBRO'
         where ID_GRUPO  = p_id_grupo
           and ID_MEMBRO = p_de;
        update MMM_MEMBRO
           set PAPEL = 'DONO'
         where ID_GRUPO  = p_id_grupo
           and ID_MEMBRO = p_para;
    end passar_dono;

    procedure exigir_membro_ativo(p_id_grupo in number, p_id_membro in number) is
        l_qtd pls_integer;
    begin
        select count(*)
          into l_qtd
          from MMM_MEMBRO m
          join MMM_USUARIO u
            on u.ID_USUARIO = m.ID_USUARIO
         where m.ID_GRUPO  = p_id_grupo
           and m.ID_MEMBRO = p_id_membro
           and m.SITUACAO  = 'ATIVO'
           and u.TIPO      = 'GOOGLE';
        if l_qtd = 0 then
            raise_application_error(-20212, 'A pessoa escolhida não está no grupo.');
        end if;
    end exigir_membro_ativo;

    procedure transferir_dono(p_id_membro_novo in number) is
        r t_membro := eu;
    begin
        exigir_dono(r);
        exigir_membro_ativo(r.id_grupo, p_id_membro_novo);
        passar_dono(r.id_grupo, r.id_membro, p_id_membro_novo);
    end transferir_dono;

    procedure remover_membro(p_id_membro in number) is
        r     t_membro := eu;
        l_qtd pls_integer;
    begin
        exigir_dono(r);
        if p_id_membro = r.id_membro then
            raise_application_error(-20213, 'Para sair do grupo, use Sair do grupo.');
        end if;
        -- antes do update, enquanto o grupo e o ativo de quem remove: depois dele o VPD esconde a pessoa
        -- e a mesa ficaria esperando o voto dela
        MMM_PKG_JOGO.tirar_do_sofa(p_id_membro);
        -- o gatilho MMM_MEMBRO_SAIU_TRG tira o grupo do ativo da pessoa na hora
        update MMM_MEMBRO
           set SITUACAO = 'SAIU',
               SAIU_EM  = systimestamp,
               PAPEL    = 'MEMBRO'
         where ID_GRUPO  = r.id_grupo
           and ID_MEMBRO = p_id_membro
           and SITUACAO  = 'ATIVO';
        l_qtd := sql%rowcount;
        if l_qtd = 0 then
            raise_application_error(-20212, 'A pessoa escolhida não está no grupo.');
        end if;
        -- quem foi tirado continua com o link na conversa do grupo; sem isto ele volta com o mesmo link
        revogar_ativos(r.id_grupo);
    end remover_membro;

    procedure sair_do_grupo(p_id_membro_novo_dono in number default null) is
        r            t_membro := eu;
        l_trava      number;
        l_outros     pls_integer;
        l_novo_dono  number := p_id_membro_novo_dono;
    begin
        if r.fl_demo = 'S' then
            raise_application_error(-20214, 'O grupo da demonstração acaba sozinho quando a visita termina.');
        end if;

        -- trava o grupo: dois donos saindo juntos nao podem deixa-lo sem dono
        select ID_GRUPO
          into l_trava
          from MMM_GRUPO
         where ID_GRUPO = r.id_grupo
           for update;

        select count(*)
          into l_outros
          from MMM_MEMBRO m
          join MMM_USUARIO u
            on u.ID_USUARIO = m.ID_USUARIO
         where m.ID_GRUPO   = r.id_grupo
           and m.SITUACAO   = 'ATIVO'
           and m.ID_MEMBRO <> r.id_membro
           and u.TIPO       = 'GOOGLE';

        if l_outros = 0 then
            -- ultimo a sair: o grupo acaba com lista, sessoes e historico (cascata a partir de MMM_GRUPO)
            delete from MMM_GRUPO
             where ID_GRUPO = r.id_grupo;
        else
            -- antes do update, enquanto o grupo ainda e o ativo: depois dele o VPD esconde a pessoa da mesa.
            -- E antes do passar_dono: a trava da sessao vem antes das linhas de MMM_MEMBRO, na ordem do jogo
            -- (o placar do fim grava MMM_MEMBRO com a sessao travada); na ordem inversa os dois se esperam
            MMM_PKG_JOGO.tirar_do_sofa(r.id_membro);
            if r.papel = 'DONO' then
                if l_novo_dono is null then
                    select max(m.ID_MEMBRO) keep (dense_rank first order by m.ENTROU_EM, m.ID_MEMBRO)
                      into l_novo_dono
                      from MMM_MEMBRO m
                      join MMM_USUARIO u
                        on u.ID_USUARIO = m.ID_USUARIO
                     where m.ID_GRUPO   = r.id_grupo
                       and m.SITUACAO   = 'ATIVO'
                       and m.ID_MEMBRO <> r.id_membro
                       and u.TIPO       = 'GOOGLE';
                else
                    exigir_membro_ativo(r.id_grupo, l_novo_dono);
                end if;
                passar_dono(r.id_grupo, r.id_membro, l_novo_dono);
            end if;
            update MMM_MEMBRO
               set SITUACAO = 'SAIU',
                   SAIU_EM  = systimestamp
             where ID_MEMBRO = r.id_membro;
        end if;

        -- sem o grupo antigo, vale o ultimo em que a pessoa entrou (ou nenhum: a pagina 1 manda para a 2)
        MMM_PKG_SEGURANCA.garantir_grupo_ativo;
    end sair_do_grupo;

    procedure excluir_grupo is
        type t_ids is table of number;
        r          t_membro := eu;
        l_trava    number;
        l_sessoes  t_ids;
        l_papel    MMM_MEMBRO.PAPEL%type;
        e_ocupado  exception;
        pragma exception_init(e_ocupado, -30006);
    begin
        -- o grupo da demo e a propria visita: o visitante nao cria nem entra em outro grupo, e o fim da visita ja apaga
        -- tudo (MMM_PKG_DEMO.expurgar)
        if r.fl_demo = 'S' then
            raise_application_error(-20214, 'O grupo da demonstração acaba sozinho quando a visita termina.');
        elsif r.papel <> 'DONO' then
            raise_application_error(-20202, 'Só o dono do grupo pode fazer isso.');
        end if;

        -- na ordem do sair_do_grupo e do jogo: o grupo, as sessoes e so depois as linhas de MMM_MEMBRO (o placar do fim
        -- grava MMM_MEMBRO com a sessao travada; na ordem inversa os dois se esperariam)
        select ID_GRUPO
          into l_trava
          from MMM_GRUPO
         where ID_GRUPO = r.id_grupo
           for update;
        select ID_SESSAO
          bulk collect into l_sessoes
          from MMM_SESSAO
         where ID_GRUPO = r.id_grupo
           for update wait 3;

        -- o papel de agora, com a linha travada: o Tornar dono feito em outro aparelho pode ter passado o papel adiante
        begin
            select PAPEL
              into l_papel
              from MMM_MEMBRO
             where ID_MEMBRO = r.id_membro
               and SITUACAO  = 'ATIVO'
               for update;
        exception
            when no_data_found then
                l_papel := null;
        end;
        if nvl(l_papel, '-') <> 'DONO' then
            raise_application_error(-20202, 'Só o dono do grupo pode fazer isso.');
        end if;

        -- a mesma cascata de quando o ultimo membro com conta Google sai: membros, convites, servicos, lista, sessoes com
        -- votos e duelos, assistidos e o grupo ativo de cada membro
        delete from MMM_GRUPO
         where ID_GRUPO = r.id_grupo;

        -- vale o ultimo grupo em que o dono entrou (ou nenhum: a pagina 1 manda para a 2); os outros membros passam pelo
        -- mesmo na proxima pagina que abrirem (o desvio da pagina 1 e o MMM_MEMBRO_ATIVO)
        MMM_PKG_SEGURANCA.garantir_grupo_ativo;
    exception
        when e_ocupado then
            -- uma jogada da sessao aberta segurava a linha por mais de 3 s
            raise_application_error(-20215, 'O grupo está ocupado agora. Tente de novo em instantes.');
    end excluir_grupo;

end MMM_PKG_GRUPO;
/

create or replace package MMM_PKG_DEMO authid definer as

    -- funcao de autenticacao do esquema VISITANTE: senha digitada nunca vale
    function recusar_senha(p_username in varchar2, p_password in varchar2) return boolean;

    -- pagina 9998: confere o esquema, o Worker e os tetos e devolve o login novo para o apex_authentication.post_login
    function novo_login return varchar2;

    -- a sessao esta no esquema VISITANTE (a 9998 aberta pelo endereco com ?request=APEX_AUTHENTICATION%3DVISITANTE)
    function esquema_visitante return boolean;

    -- Post-Authentication do esquema VISITANTE: cria a pessoa, o grupo da demo, os robos e a lista
    procedure pos_login_visitante;

    procedure encerrar_visita;

    -- job de hora em hora (fora do APEX): visitas vencidas saem inteiras
    procedure expurgar;

end MMM_PKG_DEMO;
/

create or replace package body MMM_PKG_DEMO as

    c_visitantes_hora constant pls_integer := 60;
    c_visitas_por_ip  constant pls_integer := 10;

    -- gosto por chave de MMM_CLIMA
    c_perfil_marina constant varchar2(200) := '{"gosta":["romance","risada","chorar","quentinho","prender"],"evita":["susto"]}';
    c_perfil_rafa   constant varchar2(200) := '{"gosta":["adrenalina","mundo","susto","unhas","investigar"],"evita":["romance"]}';

    function recusar_senha(p_username in varchar2, p_password in varchar2) return boolean is
    begin
        -- o visitante so entra pela pagina 9998, via apex_authentication.post_login
        return false;
    end recusar_senha;

    -- sem o request do esquema a sessao fica no esquema corrente (GOOGLE), onde a coluna vem nula,
    -- e o post_login rodaria a Post-Authentication do Google
    function esquema_visitante return boolean is
        l_esquema varchar2(255);
    begin
        select max(s.SESSION_AUTHENTICATION_NAME)
          into l_esquema
          from APEX_WORKSPACE_SESSIONS s
         where s.APEX_SESSION_ID = to_number(v('APP_SESSION'));
        return nvl(l_esquema, '-') = 'VISITANTE';
    end esquema_visitante;

    function novo_login return varchar2 is
        l_segredo varchar2(200);
        l_ip      varchar2(64);
        l_chave   varchar2(64);
        l_total   pls_integer;
        l_do_ip   pls_integer;
        l_bytes   raw(5) := dbms_crypto.randombytes(5);
        -- SHA-256 em hex do segredo MMM_SEGREDO do Worker, na substitution do app. Vazia = sem Worker:
        -- o cabecalho nao existe e fica so o teto global
        l_hash    varchar2(64) := upper(MMM_PKG_UTIL.config('MMM_HASH_PROXY'));
    begin
        -- sem o request do esquema, o post_login rodaria a Post-Authentication do GOOGLE e recusaria o visitante
        if not esquema_visitante then
            raise_application_error(-20251, 'Abra a demonstração pelo endereço do app.');
        end if;

        -- com Worker so ele escreve x-mmm-proxy e x-mmm-ip; direto no host da ATP eles nao vem.
        -- O IP so conta quando o segredo confere, e o log guarda o hash dele com o segredo, nunca o IP
        if l_hash is not null then
            l_segredo := substr(owa_util.get_cgi_env('x-mmm-proxy'), 1, 200);
            l_ip      := substr(owa_util.get_cgi_env('x-mmm-ip'), 1, 64);
            if l_segredo is null or l_ip is null
               or rawtohex(dbms_crypto.hash(utl_raw.cast_to_raw(l_segredo), dbms_crypto.hash_sh256)) <> l_hash then
                raise_application_error(-20251, 'Abra a demonstração pelo endereço do app.');
            end if;
            l_chave := rawtohex(dbms_crypto.hash(utl_raw.cast_to_raw(l_ip || l_segredo), dbms_crypto.hash_sh256));
        end if;

        -- o teto conta pelo log: MMM_USUARIO tem VPD e quem ainda nao entrou nao ve as outras visitas
        select count(*),
               count(case when MENSAGEM = l_chave then 1 end)
          into l_total, l_do_ip
          from MMM_INTEGRACAO_LOG
         where SISTEMA   = 'APP'
           and OPERACAO  = 'DEMO_VISITA'
           and CRIADO_EM > systimestamp - interval '1' hour;
        if l_total >= c_visitantes_hora or l_do_ip >= c_visitas_por_ip then
            raise_application_error(-20251, 'A demonstração está cheia agora. Tente de novo em alguns minutos.');
        end if;
        MMM_PKG_UTIL.log_app('DEMO_VISITA', null, l_chave);
        return 'VISITANTE-' || rawtohex(l_bytes);
    end novo_login;

    procedure pos_login_visitante is
        l_id_grupo  number;
        l_id_membro number;
    begin
        -- so o login que o novo_login inventou: uma conta Google numa sessao no esquema VISITANTE seria gravada como visita
        -- (a entrada pelo aparelho lembrado ja confere o esquema; isto e a defesa a mais)
        if not regexp_like(sys_context('APEX$SESSION', 'APP_USER'), '^VISITANTE-[0-9A-F]{10}$') then
            raise_application_error(-20252, 'A demonstração só começa pelo botão Começar.');
        end if;
        MMM_PKG_SEGURANCA.registrar_login(p_tipo => 'VISITANTE', p_nome => 'Visitante');

        l_id_grupo  := MMM_PKG_SEGURANCA.criar_grupo(
                           p_nome    => 'Sessão de Sexta',
                           p_apelido => 'Você',
                           p_cor     => 1,
                           p_fl_demo => 'S');
        l_id_membro := MMM_PKG_SEGURANCA.id_membro_atual;

        -- Marina e Rafa entram em todo grupo de demonstracao, com o gosto deles
        insert into MMM_MEMBRO (ID_GRUPO, ID_USUARIO, APELIDO, COR, PAPEL, PERFIL_SIMULADO)
        select l_id_grupo,
               u.ID_USUARIO,
               u.NOME,
               case u.LOGIN when 'ROBO:MARINA' then 2 else 3 end,
               'MEMBRO',
               case u.LOGIN when 'ROBO:MARINA' then c_perfil_marina else c_perfil_rafa end
          from MMM_USUARIO u
         where u.TIPO = 'ROBO'
           and u.LOGIN in ('ROBO:MARINA', 'ROBO:RAFA');

        -- a tela mostra o mais recente primeiro: cada item ganha um segundo a menos, para a lista aparecer na ordem
        -- da lista modelo e nao na ordem em que o banco devolve as linhas
        insert into MMM_LISTA_ITEM (ID_GRUPO, ID_TITULO, ID_MEMBRO_SUGERIU, PIPOCAS, ORIGEM, CRIADO_EM)
        select l_id_grupo,
               d.ID_TITULO,
               nvl(m.ID_MEMBRO, l_id_membro),
               d.PIPOCAS,
               d.ORIGEM,
               systimestamp - numtodsinterval(row_number() over (order by d.ID_DEMO_ITEM), 'SECOND')
          from MMM_DEMO_ITEM d
          left join MMM_USUARIO u
            on u.LOGIN = d.LOGIN_SUGERIU
          left join MMM_MEMBRO m
            on m.ID_GRUPO   = l_id_grupo
           and m.ID_USUARIO = u.ID_USUARIO;

        insert into MMM_GRUPO_SERVICO (ID_GRUPO, ID_SERVICO)
        select l_id_grupo, s.ID_SERVICO
          from MMM_SERVICO s
         where s.CODIGO in ('netflix', 'prime', 'disney', 'hbo', 'globoplay');

        -- post_login redireciona e encerra o pedido: grava antes
        commit;
    end pos_login_visitante;

    procedure encerrar_visita is
    begin
        -- sem senha, quem sai nao volta: o expurgo da proxima hora apaga tudo
        update MMM_USUARIO
           set EXPIRA_EM = systimestamp
         where LOGIN = sys_context('APEX$SESSION', 'APP_USER')
           and TIPO  = 'VISITANTE';
    end encerrar_visita;

    procedure expurgar is
        l_grupos   pls_integer;
        l_usuarios pls_integer;
    begin
        -- o grupo leva membros, lista, sessoes, votos e duelos (cascata a partir de MMM_GRUPO)
        delete from MMM_GRUPO g
         where g.FL_DEMO = 'S'
           and exists (select 1
                         from MMM_MEMBRO m
                         join MMM_USUARIO u
                           on u.ID_USUARIO = m.ID_USUARIO
                        where m.ID_GRUPO  = g.ID_GRUPO
                          and m.PAPEL     = 'DONO'
                          and u.TIPO      = 'VISITANTE'
                          and u.EXPIRA_EM < systimestamp);
        l_grupos := sql%rowcount;

        delete from MMM_USUARIO u
         where u.TIPO      = 'VISITANTE'
           and u.EXPIRA_EM < systimestamp
           and not exists (select 1
                             from MMM_MEMBRO m
                            where m.ID_USUARIO = u.ID_USUARIO);
        l_usuarios := sql%rowcount;

        MMM_PKG_UTIL.log_app('EXPURGO_DEMO', l_grupos + l_usuarios, l_grupos || ' grupos, ' || l_usuarios || ' visitantes');
        commit;
    end expurgar;

end MMM_PKG_DEMO;
/
