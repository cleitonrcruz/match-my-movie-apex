create or replace package MMM_PKG_SEGURANCA authid definer is

    e_nao_membro exception;
    pragma exception_init(e_nao_membro, -20101);

    -- funcoes de politica (DBMS_RLS): recebem schema e objeto, devolvem o predicado
    function predicado_usuario_ler     (p_schema in varchar2, p_objeto in varchar2) return varchar2;
    function predicado_usuario_alterar (p_schema in varchar2, p_objeto in varchar2) return varchar2;
    function predicado_grupo_ativo     (p_schema in varchar2, p_objeto in varchar2) return varchar2;
    function predicado_grupo           (p_schema in varchar2, p_objeto in varchar2) return varchar2;
    function predicado_membro          (p_schema in varchar2, p_objeto in varchar2) return varchar2;
    function predicado_dados           (p_schema in varchar2, p_objeto in varchar2) return varchar2;
    function predicado_voto_sigilo     (p_schema in varchar2, p_objeto in varchar2) return varchar2;

    function id_usuario_atual return number;
    function id_grupo_ativo   return number;
    function id_membro_atual  return number;
    function tipo_usuario_atual return varchar2;

    -- a tela manda o grupo que mostrou (x10 ou item *_GRUPO_TELA); recusa se o ativo mudou em outro aparelho
    procedure exigir_grupo_da_tela(p_id_grupo_tela in varchar2);

    -- Post-Authentication do esquema GOOGLE
    procedure pos_login_google;

    procedure registrar_login (
        p_tipo       in varchar2,
        p_email      in varchar2 default null,
        p_nome       in varchar2 default null,
        p_google_sub in varchar2 default null);

    procedure garantir_grupo_ativo;

    procedure ativar_grupo (p_id_grupo in number);

    function criar_grupo (
        p_nome    in varchar2,
        p_apelido in varchar2,
        p_cor     in number default 1,
        p_fl_demo in varchar2 default 'N') return number;

end MMM_PKG_SEGURANCA;
/

create or replace package body MMM_PKG_SEGURANCA is

    c_max_grupos_dono constant pls_integer := 20;

    -- Quem esta logado: o ID_USUARIO que a Post-Authentication gravou como tenant da sessao.
    -- Ler daqui, e nao de MMM_USUARIO pelo APP_USER, e o que deixa as politicas sem ciclo.
    c_eu constant varchar2(100) := q'~to_number(sys_context('APEX$SESSION', 'APP_TENANT_ID'))~';

    function em_sessao_apex return boolean is
    begin
        return sys_context('APEX$SESSION', 'APP_ID') is not null;
    end em_sessao_apex;

    -- Sem sessao APEX so o dono do schema conectado direto ou um job do DBMS_SCHEDULER ve tudo.
    -- ORDS (sessao por proxy) e qualquer outro usuario de banco nao veem nada.
    -- O job roda com o SESSION_USER de quem o criou: na ATP o MMM nao tem senha e os jobs nascem pelo ADMIN.
    -- Liberar o job de qualquer criador nao abre nada: sem grant, nenhum outro schema le estas tabelas nem chama
    -- estes pacotes, e quem tem privilegio ANY (ADMIN, SYSTEM) ja pode tudo no banco.
    function fora_do_apex (p_schema in varchar2) return varchar2 is
    begin
        if sys_context('USERENV', 'PROXY_USER') is null
           and (sys_context('USERENV', 'SESSION_USER') = p_schema
                or sys_context('USERENV', 'BG_JOB_ID') is not null) then
            return null;
        end if;
        return '1=0';
    end fora_do_apex;

    function montar (p_schema in varchar2, p_modelo in varchar2) return varchar2 is
    begin
        return replace(replace(p_modelo, '#S#', dbms_assert.simple_sql_name(p_schema)), '#EU#', c_eu);
    end montar;

    function predicado_usuario_ler (p_schema in varchar2, p_objeto in varchar2) return varchar2 is
    begin
        if not em_sessao_apex then
            return fora_do_apex(p_schema);
        end if;
        -- a propria linha pelo login (a Post-Authentication le antes de existir o tenant),
        -- os robos da demo e os colegas do grupo ativo (o push sai pelo login deles)
        return montar(p_schema, q'~(LOGIN = sys_context('APEX$SESSION', 'APP_USER')
 or TIPO = 'ROBO'
 or ID_USUARIO in (select m.ID_USUARIO
                     from #S#.MMM_MEMBRO m
                    where m.SITUACAO = 'ATIVO'
                      and m.ID_GRUPO = (select ga.ID_GRUPO
                                          from #S#.MMM_GRUPO_ATIVO ga
                                         where ga.ID_USUARIO = #EU#)))~');
    end predicado_usuario_ler;

    function predicado_usuario_alterar (p_schema in varchar2, p_objeto in varchar2) return varchar2 is
    begin
        if not em_sessao_apex then
            return fora_do_apex(p_schema);
        end if;
        return q'~LOGIN = sys_context('APEX$SESSION', 'APP_USER')~';
    end predicado_usuario_alterar;

    function predicado_grupo_ativo (p_schema in varchar2, p_objeto in varchar2) return varchar2 is
    begin
        if not em_sessao_apex then
            return fora_do_apex(p_schema);
        end if;
        return montar(p_schema, 'ID_USUARIO = #EU#');
    end predicado_grupo_ativo;

    function predicado_grupo (p_schema in varchar2, p_objeto in varchar2) return varchar2 is
    begin
        if not em_sessao_apex then
            return fora_do_apex(p_schema);
        end if;
        return montar(p_schema, q'~ID_GRUPO in (select m.ID_GRUPO
                    from #S#.MMM_MEMBRO m
                   where m.ID_USUARIO = #EU#
                     and m.SITUACAO = 'ATIVO')~');
    end predicado_grupo;

    function predicado_membro (p_schema in varchar2, p_objeto in varchar2) return varchar2 is
    begin
        if not em_sessao_apex then
            return fora_do_apex(p_schema);
        end if;
        -- nao pode consultar MMM_MEMBRO aqui: seria a politica da tabela lendo a propria tabela
        return montar(p_schema, q'~(ID_USUARIO = #EU#
 or ID_GRUPO = (select ga.ID_GRUPO
                  from #S#.MMM_GRUPO_ATIVO ga
                 where ga.ID_USUARIO = #EU#))~');
    end predicado_membro;

    function predicado_dados (p_schema in varchar2, p_objeto in varchar2) return varchar2 is
    begin
        if not em_sessao_apex then
            return fora_do_apex(p_schema);
        end if;
        -- grupo ativo de quem esta logado, e so enquanto ainda for membro ativo dele.
        -- "in" e nao "=": com a subconsulta escalar e o check option, insert com ID_GRUPO e returning (ou com
        -- colecao no select) da ORA-01733; a subconsulta devolve no maximo uma linha, o filtro e o mesmo
        return montar(p_schema, q'~ID_GRUPO in (select m.ID_GRUPO
              from #S#.MMM_GRUPO_ATIVO ga
              join #S#.MMM_MEMBRO m
                on m.ID_GRUPO   = ga.ID_GRUPO
               and m.ID_USUARIO = ga.ID_USUARIO
             where ga.ID_USUARIO = #EU#
               and m.SITUACAO   = 'ATIVO')~');
    end predicado_dados;

    function predicado_voto_sigilo (p_schema in varchar2, p_objeto in varchar2) return varchar2 is
    begin
        if not em_sessao_apex then
            return fora_do_apex(p_schema);
        end if;
        -- enquanto a sessao esta em VOTANDO cada um so ve o proprio voto
        return montar(p_schema, q'~(ID_MEMBRO in (select m.ID_MEMBRO
                       from #S#.MMM_MEMBRO m
                      where m.ID_USUARIO = #EU#)
 or ID_SESSAO in (select s.ID_SESSAO
                    from #S#.MMM_SESSAO s
                   where s.SITUACAO <> 'VOTANDO'))~');
    end predicado_voto_sigilo;

    function id_usuario_atual return number is
    begin
        return to_number(sys_context('APEX$SESSION', 'APP_TENANT_ID'));
    end id_usuario_atual;

    function id_grupo_ativo return number is
        l_id_usuario number := id_usuario_atual;
        l_id_grupo   number;
    begin
        select m.ID_GRUPO
          into l_id_grupo
          from MMM_GRUPO_ATIVO ga
          join MMM_MEMBRO m
            on m.ID_GRUPO   = ga.ID_GRUPO
           and m.ID_USUARIO = ga.ID_USUARIO
         where ga.ID_USUARIO = l_id_usuario
           and m.SITUACAO   = 'ATIVO';
        return l_id_grupo;
    exception
        when no_data_found then
            return null;
    end id_grupo_ativo;

    function id_membro_atual return number is
        l_id_usuario number := id_usuario_atual;
        l_id_membro  number;
    begin
        select m.ID_MEMBRO
          into l_id_membro
          from MMM_GRUPO_ATIVO ga
          join MMM_MEMBRO m
            on m.ID_GRUPO   = ga.ID_GRUPO
           and m.ID_USUARIO = ga.ID_USUARIO
         where ga.ID_USUARIO = l_id_usuario
           and m.SITUACAO   = 'ATIVO';
        return l_id_membro;
    exception
        when no_data_found then
            return null;
    end id_membro_atual;

    function tipo_usuario_atual return varchar2 is
        l_tipo MMM_USUARIO.TIPO%type;
    begin
        select max(TIPO)
          into l_tipo
          from MMM_USUARIO
         where ID_USUARIO = id_usuario_atual;
        return l_tipo;
    end tipo_usuario_atual;

    -- o grupo ativo vale por pessoa e muda sem as outras telas saberem (push, troca de grupo, convite):
    -- gravacao feita numa tela velha cairia no grupo novo
    procedure exigir_grupo_da_tela(p_id_grupo_tela in varchar2) is
        l_tela  number := to_number(p_id_grupo_tela default null on conversion error);
        l_ativo number := id_grupo_ativo;
    begin
        if l_tela is null or l_ativo is null or l_tela <> l_ativo then
            raise_application_error(-20107, 'Você trocou de grupo em outro aparelho. Recarregue a tela.');
        end if;
    end exigir_grupo_da_tela;

    procedure pos_login_google is
        l_sub   varchar2(255);
        l_email varchar2(255);
        l_nome  varchar2(400);
        l_token apex_jwt.t_token;

        -- nomes dos campos que chegaram do Google (sem os valores), para o log de erro
        function campos_userinfo return varchar2 is
        begin
            return apex_string.join(apex_json.get_members(p_path => '.'), ',');
        exception
            when others then
                return 'sem userinfo: ' || sqlerrm;
        end campos_userinfo;
    begin
        -- entrada automatica pelo aparelho lembrado (MMM_PKG_LEMBRAR, sessao publica na 9999): a conta vem do banco, e o
        -- apex_json nao tem nada do Google
        if MMM_PKG_LEMBRAR.entrada_em_curso then
            MMM_PKG_LEMBRAR.pos_login;
            return;
        end if;

        -- com o provedor Google o apex_json da Post-Authentication traz o userinfo; com o Generic OAuth2 (atras do
        -- Worker) traz a resposta do token, e sub, e-mail e nome vem do id_token que o Google assinou
        l_sub := apex_json.get_varchar2(p_path => 'sub');
        if l_sub is not null then
            l_email := apex_json.get_varchar2(p_path => 'email');
            l_nome  := apex_json.get_varchar2(p_path => 'name');
        elsif apex_json.does_exist(p_path => 'id_token') then
            l_token := apex_jwt.decode(p_value => apex_json.get_varchar2(p_path => 'id_token'));
            l_sub   := json_value(l_token.payload, '$.sub');
            l_email := json_value(l_token.payload, '$.email');
            l_nome  := json_value(l_token.payload, '$.name');
            -- o id_token tem de ser da conta que o APEX ja autenticou pelo userinfo
            if nvl(upper(l_email), '-') <> sys_context('APEX$SESSION', 'APP_USER') then
                raise_application_error(-20104, 'O Google devolveu outra conta. Tente de novo.');
            end if;
        end if;

        registrar_login(
            p_tipo       => 'GOOGLE',
            p_email      => l_email,
            p_nome       => l_nome,
            p_google_sub => l_sub);

        -- a caixa "Manter conectado neste aparelho" (o pedido vem num cookie curto): um erro ali nao derruba o login
        MMM_PKG_LEMBRAR.preparar;
    exception
        when others then
            -- a tela do APEX so mostra "erro no plug-in": o motivo fica no log
            MMM_PKG_UTIL.log_app('LOGIN_ERRO', sqlcode,
                substr(sqlerrm || ' | campos: ' || campos_userinfo || ' | ' || dbms_utility.format_error_backtrace, 1, 2000));
            raise;
    end pos_login_google;

    procedure garantir_grupo_ativo is
        l_id_usuario number := id_usuario_atual;
        l_valido     pls_integer;
    begin
        select count(*)
          into l_valido
          from MMM_GRUPO_ATIVO ga
          join MMM_MEMBRO m
            on m.ID_GRUPO   = ga.ID_GRUPO
           and m.ID_USUARIO = ga.ID_USUARIO
         where ga.ID_USUARIO = l_id_usuario
           and m.SITUACAO   = 'ATIVO';

        if l_valido = 0 then
            delete from MMM_GRUPO_ATIVO
             where ID_USUARIO = l_id_usuario;

            -- sem grupo ativo valido: volta para o grupo em que entrou por ultimo
            insert into MMM_GRUPO_ATIVO (ID_USUARIO, ID_GRUPO)
            select l_id_usuario,
                   max(m.ID_GRUPO) keep (dense_rank last order by m.ENTROU_EM)
              from MMM_MEMBRO m
             where m.ID_USUARIO = l_id_usuario
               and m.SITUACAO   = 'ATIVO'
            having count(*) > 0;
        end if;
    end garantir_grupo_ativo;

    procedure registrar_login (
        p_tipo       in varchar2,
        p_email      in varchar2 default null,
        p_nome       in varchar2 default null,
        p_google_sub in varchar2 default null) is
        l_login      MMM_USUARIO.LOGIN%type := sys_context('APEX$SESSION', 'APP_USER');
        l_id_usuario MMM_USUARIO.ID_USUARIO%type;
        l_sub        MMM_USUARIO.GOOGLE_SUB%type;
        l_id_grupo   number;

        -- e-mail que ja pertence a outra conta Google (o Google recicla endereco) nao herda os grupos dela
        procedure conferir_sub is
        begin
            if p_tipo = 'GOOGLE' and l_sub <> p_google_sub then
                raise_application_error(-20103, 'Este e-mail pertence a outra conta Google no app. Fale com o administrador.');
            end if;
        end conferir_sub;
    begin
        if l_login is null or l_login = 'nobody' then
            raise_application_error(-20100, 'registrar_login precisa de sessao APEX autenticada');
        end if;
        if p_tipo = 'GOOGLE' and p_google_sub is null then
            raise_application_error(-20100, 'O Google não devolveu a identificação da conta. Tente de novo.');
        end if;

        begin
            select ID_USUARIO, GOOGLE_SUB
              into l_id_usuario, l_sub
              from MMM_USUARIO
             where LOGIN = l_login;
            conferir_sub;

            -- entrar de novo antes do job horario desiste do Excluir minha conta
            update MMM_USUARIO
               set EMAIL              = case when p_tipo = 'GOOGLE' then lower(p_email) end,
                   NOME               = nvl(substr(p_nome, 1, 120), NOME),
                   ULTIMO_ACESSO_EM   = systimestamp,
                   EXCLUSAO_PEDIDA_EM = null
             where ID_USUARIO = l_id_usuario;
        exception
            when no_data_found then
                begin
                    insert into MMM_USUARIO (LOGIN, TIPO, EMAIL, NOME, GOOGLE_SUB, EXPIRA_EM, ULTIMO_ACESSO_EM)
                    values (l_login,
                            p_tipo,
                            case when p_tipo = 'GOOGLE' then lower(p_email) end,
                            substr(nvl(p_nome, p_email), 1, 120),
                            case when p_tipo = 'GOOGLE' then p_google_sub end,
                            case when p_tipo = 'VISITANTE' then systimestamp + interval '24' hour end,
                            systimestamp)
                    returning ID_USUARIO into l_id_usuario;
                exception
                    when dup_val_on_index then
                        begin
                            -- dois logins simultaneos no primeiro acesso: o outro ja criou a linha
                            select ID_USUARIO, GOOGLE_SUB
                              into l_id_usuario, l_sub
                              from MMM_USUARIO
                             where LOGIN = l_login;
                            conferir_sub;
                        exception
                            when no_data_found then
                                -- o sub ja existe com outro e-mail; a linha antiga nao e visivel daqui (VPD)
                                raise_application_error(-20103, 'Esta conta Google trocou de e-mail. Fale com o administrador do app.');
                        end;
                end;
        end;

        -- o tenant so pode ser gravado uma vez por sessao: outro valor da ORA-20987 (TENANT_ID_EXISTS), que o
        -- APEX escreve na resposta mesmo capturado. Outra conta numa sessao que ja tem tenant e recusada aqui:
        -- sem isso ela entraria com o tenant da anterior
        if sys_context('APEX$SESSION', 'APP_TENANT_ID') is null then
            apex_session.set_tenant_id(p_tenant_id => to_char(l_id_usuario));
        elsif sys_context('APEX$SESSION', 'APP_TENANT_ID') <> to_char(l_id_usuario) then
            raise_application_error(-20102, 'Este navegador já está conectado com outra conta. Saia e entre de novo.');
        end if;

        garantir_grupo_ativo;

        l_id_grupo := id_grupo_ativo;
        if l_id_grupo is not null then
            update MMM_GRUPO
               set ULTIMA_ATIVIDADE_EM = systimestamp
             where ID_GRUPO = l_id_grupo;
        end if;
    end registrar_login;

    procedure ativar_grupo (p_id_grupo in number) is
        l_id_usuario number := id_usuario_atual;
        l_membro     pls_integer;
    begin
        select count(*)
          into l_membro
          from MMM_MEMBRO m
         where m.ID_GRUPO   = p_id_grupo
           and m.ID_USUARIO = l_id_usuario
           and m.SITUACAO   = 'ATIVO';

        if l_membro = 0 then
            raise_application_error(-20101, 'Você não participa deste grupo.');
        end if;

        update MMM_GRUPO_ATIVO
           set ID_GRUPO = p_id_grupo
         where ID_USUARIO = l_id_usuario;

        if sql%rowcount = 0 then
            insert into MMM_GRUPO_ATIVO (ID_USUARIO, ID_GRUPO)
            values (l_id_usuario, p_id_grupo);
        end if;

        update MMM_GRUPO
           set ULTIMA_ATIVIDADE_EM = systimestamp
         where ID_GRUPO = p_id_grupo;
    end ativar_grupo;

    function criar_grupo (
        p_nome    in varchar2,
        p_apelido in varchar2,
        p_cor     in number default 1,
        p_fl_demo in varchar2 default 'N') return number is
        l_id_usuario number := id_usuario_atual;
        l_tipo       MMM_USUARIO.TIPO%type := tipo_usuario_atual;
        l_qtd        pls_integer;
        l_id_grupo   number;
    begin
        if l_id_usuario is null then
            raise_application_error(-20100, 'criar_grupo precisa de usuario logado');
        elsif (p_fl_demo = 'N' and l_tipo <> 'GOOGLE') or (p_fl_demo = 'S' and l_tipo <> 'VISITANTE') then
            raise_application_error(-20104, 'Na demonstração não dá para criar grupo. Entre com sua conta Google.');
        elsif trim(p_nome) is null then
            raise_application_error(-20106, 'Dê um nome ao grupo.');
        end if;

        select count(*)
          into l_qtd
          from MMM_MEMBRO
         where ID_USUARIO = l_id_usuario
           and PAPEL      = 'DONO'
           and SITUACAO   = 'ATIVO';
        if l_qtd >= c_max_grupos_dono then
            raise_application_error(-20105, 'Você já é dono de ' || c_max_grupos_dono || ' grupos.');
        end if;

        insert into MMM_GRUPO (NOME, FL_DEMO)
        values (substr(trim(p_nome), 1, 60), p_fl_demo)
        returning ID_GRUPO into l_id_grupo;

        -- o dono entra pela propria linha (ID_USUARIO = eu): e o caminho que a politica
        -- de membro aceita antes de o grupo novo ser o ativo
        insert into MMM_MEMBRO (ID_GRUPO, ID_USUARIO, APELIDO, COR, PAPEL)
        values (l_id_grupo, l_id_usuario, substr(trim(p_apelido), 1, 30), nvl(p_cor, 1), 'DONO');

        ativar_grupo(l_id_grupo);
        return l_id_grupo;
    end criar_grupo;

end MMM_PKG_SEGURANCA;
/
