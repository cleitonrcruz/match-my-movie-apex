create or replace package MMM_PKG_RETENCAO authid definer as
    -- roda fora do APEX (DBMS_SCHEDULER como MMM): o VPD devolve tudo e cada passo agrupa por conta propria
    procedure executar_diario;
    procedure executar_horario;
end MMM_PKG_RETENCAO;
/

create or replace package body MMM_PKG_RETENCAO as

    -- renovar aos 30 dias deixa 145 de folga antes do limite; 175 dias ficam abaixo
    -- de 6 meses em qualquer epoca do ano (termo do TMDB)
    c_dias_limite_tmdb       constant pls_integer := 175;
    c_dias_sem_uso           constant pls_integer := 30;
    c_dias_link_direto       constant pls_integer := 60;
    c_dias_item_retirado     constant pls_integer := 7;
    c_dias_sessao_fechada    constant pls_integer := 7;
    c_dias_usuario_sem_grupo constant pls_integer := 30;
    c_dias_log               constant pls_integer := 90;
    c_horas_sessao_parada    constant pls_integer := 3;
    -- renovacao parada aos 45 dias avisa 130 dias antes do limite de 175
    c_dias_alerta_renovacao  constant pls_integer := 45;

    procedure registrar(p_operacao in varchar2, p_quantidade in number, p_mensagem in varchar2 default null) is
    begin
        insert into MMM_INTEGRACAO_LOG (SISTEMA, OPERACAO, FL_ENVIADO, QUANTIDADE, MENSAGEM)
        values ('APP', p_operacao, 'N', p_quantidade, substr(p_mensagem, 1, 2000));
    end registrar;

    procedure expurgar_grupos is
    begin
        -- tirar da lista vira definitivo; o Desfazer da tela so precisa de segundos
        delete from MMM_LISTA_ITEM
         where RETIRADO_EM < systimestamp - numtodsinterval(c_dias_item_retirado, 'DAY');
        registrar('EXPURGO_ITEM_RETIRADO', sql%rowcount);

        -- sessao que nao deu em filme nao tem o que guardar
        delete from MMM_SESSAO
         where SITUACAO in ('CANCELADA', 'ABANDONADA', 'SEM_RESULTADO')
           and ENCERRADA_EM < systimestamp - numtodsinterval(c_dias_sessao_fechada, 'DAY');
        registrar('EXPURGO_SESSAO_SEM_FILME', sql%rowcount);
    end expurgar_grupos;

    procedure expurgar_link_direto is
    begin
        -- o SA permite cache; isto e frescor do link e da data de saida, nao termo
        delete from MMM_LINK_DIRETO
         where SAI_EM < MMM_PKG_UTIL.hoje_br
            or SINCRONIZADO_EM < systimestamp - numtodsinterval(c_dias_link_direto, 'DAY');
        registrar('EXPURGO_LINK_DIRETO', sql%rowcount);
    end expurgar_link_direto;

    procedure expurgar_tmdb is
        l_limite timestamp with time zone := systimestamp - numtodsinterval(c_dias_limite_tmdb, 'DAY');
        l_qtd    pls_integer;
    begin
        -- passou do limite: sai mesmo que um grupo use (o termo nao abre excecao);
        -- a cascata leva generos, disponibilidade, links, itens, cartas, votos, duelos e assistidos
        delete from MMM_TITULO
         where SINCRONIZADO_EM < l_limite;
        l_qtd := sql%rowcount;
        if l_qtd > 0 then
            registrar('EXPURGO_TITULO_LIMITE', l_qtd,
                      'Titulos sem renovacao em ' || c_dias_limite_tmdb || ' dias; ver FALHAS_SEGUIDAS dos que restam');
        end if;

        -- o que ninguem usa nao precisa esperar o limite
        delete from MMM_TITULO t
         where t.SINCRONIZADO_EM < systimestamp - numtodsinterval(c_dias_sem_uso, 'DAY')
           and not exists (select 1 from MMM_V_TITULO_EM_USO u where u.ID_TITULO = t.ID_TITULO);
        registrar('EXPURGO_TITULO_SEM_USO', sql%rowcount);

        -- as tabelas de apoio sao trocadas a cada leitura; aqui so sobra
        delete from MMM_DISPONIBILIDADE where SINCRONIZADO_EM < l_limite;
        l_qtd := sql%rowcount;
        delete from MMM_TITULO_GENERO where SINCRONIZADO_EM < l_limite;
        l_qtd := l_qtd + sql%rowcount;
        delete from MMM_PROVEDOR where SINCRONIZADO_EM < l_limite;
        l_qtd := l_qtd + sql%rowcount;
        delete from MMM_GENERO where SINCRONIZADO_EM < l_limite;
        l_qtd := l_qtd + sql%rowcount;
        registrar('EXPURGO_APOIO_TMDB', l_qtd);

        select count(*)
          into l_qtd
          from MMM_CLIMA c
         where not exists (select 1
                             from MMM_CLIMA_GENERO cg
                            where cg.ID_CLIMA = c.ID_CLIMA);
        if l_qtd > 0 then
            registrar('CLIMA_SEM_GENERO', l_qtd, 'Clima ficou sem genero; refazer o mapeamento clima-genero');
        end if;
    end expurgar_tmdb;

    procedure expurgar_log is
    begin
        delete from MMM_INTEGRACAO_LOG
         where CRIADO_EM < systimestamp - numtodsinterval(c_dias_log, 'DAY');
        registrar('EXPURGO_LOG', sql%rowcount);
    end expurgar_log;

    -- sessao esquecida aberta trava o grupo: so pode haver uma aberta por grupo
    procedure abandonar_paradas is
        l_qtd pls_integer := 0;
        l_ok  number;
    begin
        for c in (select ID_SESSAO
                    from MMM_SESSAO
                   where SITUACAO in ('VOTANDO', 'REVELADA', 'FINAL')
                     and nvl(ALTERADO_EM, CRIADO_EM) < systimestamp - numtodsinterval(c_horas_sessao_parada, 'HOUR')) loop
            begin
                -- quem estiver jogando nela agora segura a linha: fica para a proxima rodada
                select 1
                  into l_ok
                  from MMM_SESSAO
                 where ID_SESSAO = c.ID_SESSAO
                   and SITUACAO in ('VOTANDO', 'REVELADA', 'FINAL')
                   for update skip locked;
                update MMM_SESSAO
                   set SITUACAO     = 'ABANDONADA',
                       ENCERRADA_EM = systimestamp,
                       VERSAO       = VERSAO + 1
                 where ID_SESSAO = c.ID_SESSAO;
                commit;
                l_qtd := l_qtd + 1;
            exception
                when no_data_found then
                    null;
            end;
        end loop;
        registrar('SESSAO_ABANDONADA', l_qtd);
    end abandonar_paradas;

    -- inscricao de push que nao e de uma conta Google: a que um visitante forcou pelo console (a pagina 9 nao oferece,
    -- mas o APEX aceita de qualquer sessao do app) ou a que sobrou de conta apagada por outro caminho. O APEX nao apaga
    -- nenhuma delas sozinho. Sem conta Google visivel nao mexe em nada: um VPD cego faria todas parecerem orfas
    procedure limpar_inscricoes_orfas is
        l_contas pls_integer;
        l_qtd    pls_integer := 0;
    begin
        MMM_PKG_UTIL.garantir_workspace;
        select count(*)
          into l_contas
          from MMM_USUARIO
         where TIPO = 'GOOGLE';
        if l_contas = 0 then
            return;
        end if;
        for s in (select p.USER_NAME, p.SUBSCRIPTION_INTERFACE
                    from APEX_APPL_PUSH_SUBSCRIPTIONS p
                   where p.APPLICATION_ID = MMM_PKG_UTIL.app_id
                     and not exists (select 1
                                       from MMM_USUARIO u
                                      where upper(u.LOGIN) = upper(p.USER_NAME)
                                        and u.TIPO = 'GOOGLE')) loop
            apex_pwa.unsubscribe_push_notifications(
                p_application_id         => MMM_PKG_UTIL.app_id,
                p_user_name              => s.USER_NAME,
                p_subscription_interface => s.SUBSCRIPTION_INTERFACE);
            l_qtd := l_qtd + 1;
        end loop;
        if l_qtd > 0 then
            registrar('PUSH_INSCRICAO_ORFA', l_qtd);
        end if;
    end limpar_inscricoes_orfas;

    -- conta Google sem grupo ativo: sai aos 30 dias sem acesso, ou na hora em que a pessoa pede.
    -- Quem tem filiacao antiga (SAIU) nao pode ser apagado, porque votos e historico do grupo apontam
    -- para ela: a linha fica, sem e-mail, nome, sub e inscricao de push
    procedure anonimizar_contas is
        l_ids    apex_t_number;
        l_logins apex_t_varchar2;
    begin
        -- antes da selecao: quem e anonimizado agora ainda e GOOGLE, e a inscricao dele sai pelo login, abaixo
        limpar_inscricoes_orfas;
        select u.ID_USUARIO, u.LOGIN
          bulk collect into l_ids, l_logins
          from MMM_USUARIO u
         where u.TIPO = 'GOOGLE'
           and (u.EXCLUSAO_PEDIDA_EM is not null
                or nvl(u.ULTIMO_ACESSO_EM, u.CRIADO_EM) < systimestamp - numtodsinterval(c_dias_usuario_sem_grupo, 'DAY'))
           and not exists (select 1
                             from MMM_MEMBRO m
                            where m.ID_USUARIO = u.ID_USUARIO
                              and m.SITUACAO   = 'ATIVO');
        if l_ids.count = 0 then
            return;
        end if;

        -- nenhum aparelho continua lembrando a conta que sai (a apagada levaria as familias pela cascata; a EXCLUIDO, nao)
        MMM_PKG_LEMBRAR.apagar_contas(l_ids);

        -- fora de pagina o APEX_PWA exige o workspace; sem p_subscription_interface sai toda inscricao da pessoa,
        -- que o APEX guarda pelo login (o e-mail)
        MMM_PKG_UTIL.garantir_workspace;
        for i in 1 .. l_logins.count loop
            apex_pwa.unsubscribe_push_notifications(
                p_application_id => MMM_PKG_UTIL.app_id,
                p_user_name      => l_logins(i));
        end loop;

        delete from MMM_USUARIO u
         where u.ID_USUARIO in (select column_value from table(l_ids))
           and not exists (select 1
                             from MMM_MEMBRO m
                            where m.ID_USUARIO = u.ID_USUARIO);
        registrar('EXPURGO_USUARIO_SEM_GRUPO', sql%rowcount);

        update MMM_MEMBRO
           set APELIDO = 'Ex-membro'
         where ID_USUARIO in (select column_value from table(l_ids));

        update MMM_USUARIO
           set TIPO               = 'EXCLUIDO',
               LOGIN              = 'EXCLUIDO:' || ID_USUARIO,
               EMAIL              = null,
               NOME               = null,
               GOOGLE_SUB         = null,
               EXCLUSAO_PEDIDA_EM = null
         where ID_USUARIO in (select column_value from table(l_ids));
        registrar('ANONIMIZACAO_USUARIO', sql%rowcount);
    end anonimizar_contas;

    -- renovacao parada so no job nao aparece na tela; no dia 175 os titulos saem das listas e do historico
    -- de todos os grupos, e a ATP Always Free nao tem restore
    procedure alertar_renovacao is
        l_atrasados number;
        l_admin     number;
    begin
        select count(*)
          into l_atrasados
          from MMM_TITULO t
         where t.SINCRONIZADO_EM < systimestamp - numtodsinterval(c_dias_alerta_renovacao, 'DAY')
           and exists (select 1 from MMM_V_TITULO_EM_USO u where u.ID_TITULO = t.ID_TITULO);
        if l_atrasados = 0 then
            return;
        end if;
        registrar('RENOVACAO_ATRASADA', l_atrasados);
        select max(ID_USUARIO)
          into l_admin
          from MMM_USUARIO
         where LOGIN = upper(MMM_PKG_UTIL.config('MMM_ADMIN_LOGIN'));
        if l_admin is not null then
            MMM_PKG_UTIL.enviar_push(l_admin, 'Renovação do TMDB parada',
                l_atrasados || ' títulos em uso sem renovar há ' || c_dias_alerta_renovacao
                || ' dias. No dia ' || c_dias_limite_tmdb || ' saem das listas.', 'inicio');
        end if;
    end alertar_renovacao;

    -- aparelhos lembrados (MMM_PKG_LEMBRAR): familia vencida, parada ha 14 dias ou preparada e nunca emitida
    procedure expurgar_lembrar is
        l_qtd pls_integer;
    begin
        MMM_PKG_LEMBRAR.expurgar(l_qtd);
        registrar('EXPURGO_LEMBRAR', l_qtd);
    end expurgar_lembrar;

    procedure passo(p_nome in varchar2) is
        l_erro varchar2(2000);
    begin
        case p_nome
            when 'GRUPO'   then expurgar_grupos;
            when 'LINK'    then expurgar_link_direto;
            when 'TMDB'    then expurgar_tmdb;
            when 'LOG'     then expurgar_log;
            when 'SESSAO'  then abandonar_paradas;
            when 'DEMO'    then MMM_PKG_DEMO.expurgar;
            when 'LEMBRAR' then expurgar_lembrar;
            when 'CONTAS'  then anonimizar_contas;
            when 'ALERTA'  then alertar_renovacao;
        end case;
        commit;
    exception
        when others then
            l_erro := substr(p_nome || ': ' || sqlerrm || ' ' || dbms_utility.format_error_backtrace, 1, 2000);
            rollback;
            registrar('RETENCAO_ERRO', null, l_erro);
            commit;
    end passo;

    procedure executar_diario is
    begin
        MMM_PKG_UTIL.exigir_job_do_dono;
        -- grupos antes do TMDB: item tirado e sessao apagada liberam titulo sem uso no mesmo dia.
        -- Um passo que falha nao segura os outros; o erro fica no log.
        passo('GRUPO');
        passo('LINK');
        passo('TMDB');
        passo('LOG');
        -- por ultimo: o push ao admin chama set_security_group_id
        passo('ALERTA');
    end executar_diario;

    procedure executar_horario is
    begin
        MMM_PKG_UTIL.exigir_job_do_dono;
        passo('DEMO');
        passo('SESSAO');
        passo('LEMBRAR');
        -- por ultimo: a desinscricao do push chama set_security_group_id
        passo('CONTAS');
    end executar_horario;

end MMM_PKG_RETENCAO;
/
