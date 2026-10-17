-- Script 05: politicas VPD.

declare
    -- se o nome do schema mudar, e so aqui
    c_schema constant varchar2(128) := 'MMM';

    type t_tabelas is table of varchar2(128);
    l_dados t_tabelas := t_tabelas(
        'MMM_GRUPO_SERVICO', 'MMM_LISTA_ITEM', 'MMM_SESSAO', 'MMM_SESSAO_PRESENCA',
        'MMM_SESSAO_CARTA', 'MMM_VOTO', 'MMM_DUELO', 'MMM_DUELO_VOTO', 'MMM_ASSISTIDO', 'MMM_NOTA');

    procedure politica (
        p_tabela   in varchar2,
        p_nome     in varchar2,
        p_funcao   in varchar2,
        p_comandos in varchar2,
        p_checar   in boolean) is
    begin
        dbms_rls.add_policy(
            object_schema   => c_schema,
            object_name     => p_tabela,
            policy_name     => p_nome,
            function_schema => c_schema,
            policy_function => 'MMM_PKG_SEGURANCA.' || p_funcao,
            statement_types => p_comandos,
            update_check    => p_checar,
            policy_type     => dbms_rls.dynamic);
    end politica;
begin
    politica('MMM_USUARIO', 'MMM_USUARIO_LER_VPD', 'PREDICADO_USUARIO_LER', 'SELECT', false);
    politica('MMM_USUARIO', 'MMM_USUARIO_ALTERAR_VPD', 'PREDICADO_USUARIO_ALTERAR', 'INSERT, UPDATE, DELETE', true);
    politica('MMM_GRUPO_ATIVO', 'MMM_GRUPO_ATIVO_VPD', 'PREDICADO_GRUPO_ATIVO', 'SELECT', false);
    -- sem INSERT: criar grupo e livre; ler, mudar e apagar so quem e membro
    politica('MMM_GRUPO', 'MMM_GRUPO_VPD', 'PREDICADO_GRUPO', 'SELECT, UPDATE, DELETE', true);
    politica('MMM_MEMBRO', 'MMM_MEMBRO_VPD', 'PREDICADO_MEMBRO', 'SELECT, INSERT, UPDATE, DELETE', true);

    for i in 1 .. l_dados.count loop
        politica(l_dados(i), l_dados(i) || '_VPD', 'PREDICADO_DADOS', 'SELECT, INSERT, UPDATE, DELETE', true);
    end loop;

    -- segunda politica em MMM_VOTO: soma-se (AND) a de dado do grupo
    politica('MMM_VOTO', 'MMM_VOTO_SIGILO_VPD', 'PREDICADO_VOTO_SIGILO', 'SELECT', false);
end;
/
