-- Script 12: MMM_PKG_INGRESSO, o ingresso rasgado e a nota.
-- O vencedor da votacao nasce em MMM_ASSISTIDO como para assistir. Logo depois da escolha, a pagina 1 de quem estava
-- na plateia mostra o ingresso, para rasgar quando quiser (nem sempre o filme termina no mesmo dia, e os creditos
-- ficam de fora); quem rasga marca o assistido, e cada pessoa da a sua nota, de 1 a 5 pipocas (MMM_NOTA). A pagina 6
-- lista o que falta assistir (com o Rasgar) e o que ja assistiram, com a media e a nota de cada um. Marina e Rafa, da
-- demo, dao nota quando o visitante rasga, pelo voto que deram ao titulo.

create or replace package MMM_PKG_INGRESSO as

    -- o ingresso que a pessoa tem de rasgar, ou dar a nota, agora (pagina 1); nulo quando nao ha
    function pendente return number;

    -- o cartao da pagina 1 com o ingresso pendente (vazio quando nao ha)
    function cartao_html return clob;

    -- a lista da pagina 6: para assistir e ja assistiram, com as notas
    function assistidos_html return clob;

    procedure rasgar(p_id_assistido in number);
    procedure dar_nota(p_id_assistido in number, p_pipocas in number);

    -- Ja assistimos, na ficha da pagina 1: o titulo da lista vira assistido hoje, ja rasgado por quem marcou, sai da lista
    -- (filme ou serie: marcar na ficha quer dizer que terminaram) e leva a nota de quem marcou; os outros dao a nota pela
    -- pagina 6. Devolve o ID_ASSISTIDO
    function marcar_assistido(p_id_item in number, p_pipocas in number) return number;

    -- MMM_INGRESSO (x01 = RASGAR, NOTA, MARCAR ou DADOS, x02 = ID_ASSISTIDO, ou ID_LISTA_ITEM no MARCAR, ou x04 = ID_SESSAO,
    -- x03 = pipocas, x10 = grupo da tela)
    procedure ajax;

end MMM_PKG_INGRESSO;
/

create or replace package body MMM_PKG_INGRESSO as

    -- o ingresso rasgado pede a nota por uma semana; depois disso a nota segue so pela pagina 6
    c_dias_pedir_nota constant pls_integer := 7;
    -- o ingresso de mais de duas semanas nao aparece mais na pagina 1
    c_dias_cartao     constant pls_integer := 14;

    function esc(p_texto in varchar2) return varchar2 is
    begin
        return apex_escape.html(p_texto);
    end esc;

    function pipocas_txt(p_valor in number) return varchar2 is
    begin
        return to_char(round(p_valor, 1), 'fm0D0', 'nls_numeric_characters='', ''');
    end pipocas_txt;

    function decidido(p_modo in varchar2) return varchar2 is
    begin
        return case p_modo
                   when 'UNICO'     then 'Só um agradou a todos'
                   when 'DUELOS'    then 'Venceu nos duelos'
                   when 'ROLETA'    then 'A roleta decidiu'
                   when 'MINHA_VEZ' then 'Carta Minha Vez'
               end;
    end decidido;

    function pendente return number is
        l_me    number := MMM_PKG_SEGURANCA.id_membro_atual;
        l_grupo number := MMM_PKG_SEGURANCA.id_grupo_ativo;
        l_id    number;
    begin
        if l_me is null or l_grupo is null then
            return null;
        end if;
        select max(a.ID_ASSISTIDO) keep (dense_rank first order by a.RASGADO_EM nulls first, a.ID_ASSISTIDO desc)
          into l_id
          from MMM_ASSISTIDO a
          join MMM_SESSAO s
            on s.ID_SESSAO = a.ID_SESSAO
         where a.ID_GRUPO = l_grupo
           and s.ENCERRADA_EM > systimestamp - numtodsinterval(c_dias_cartao, 'DAY')
           and exists (select 1
                         from MMM_SESSAO_PRESENCA p
                        where p.ID_SESSAO = a.ID_SESSAO
                          and p.ID_MEMBRO = l_me
                          and p.SITUACAO <> 'SAIU')
           and not exists (select 1
                             from MMM_NOTA n
                            where n.ID_ASSISTIDO = a.ID_ASSISTIDO
                              and n.ID_MEMBRO    = l_me)
           -- inteiro: desde a escolha (rasga quando quiser); rasgado por alguem: pede a nota por uma semana
           and (a.RASGADO_EM is null
                or (a.ID_MEMBRO_RASGOU is not null
                    and a.RASGADO_EM > systimestamp - numtodsinterval(c_dias_pedir_nota, 'DAY')));
        return l_id;
    end pendente;

    -- o que o aparelho precisa para desenhar o ingresso (e o JSON vai num data-ingresso)
    function dados_json(p_id_assistido in number) return clob is
        l_me   number := MMM_PKG_SEGURANCA.id_membro_atual;
        l_json clob;
    begin
        select json_object(
                   'id'         value a.ID_ASSISTIDO,
                   'estado'     value case when a.RASGADO_EM is null then 'RASGAR' else 'NOTA' end,
                   'rasgouQuem' value (select m.APELIDO from MMM_MEMBRO m where m.ID_MEMBRO = a.ID_MEMBRO_RASGOU),
                   'rasgouEu'   value case when a.ID_MEMBRO_RASGOU = l_me then 'true' else 'false' end format json,
                   'minhaNota'  value (select n.PIPOCAS from MMM_NOTA n where n.ID_ASSISTIDO = a.ID_ASSISTIDO and n.ID_MEMBRO = l_me),
                   'grupo'      value g.NOME,
                   'titulo'     value t.TITULO,
                   'tipo'       value t.TIPO,
                   'ano'        value t.ANO,
                   'duracao'    value t.DURACAO_MIN,
                   'temporadas' value t.TEMPORADAS,
                   'cls'        value t.CLASSIFICACAO,
                   'poster'     value case when regexp_like(t.POSTER_PATH, '^/[A-Za-z0-9_-]+\.(jpg|jpeg|png)$') then t.POSTER_PATH end,
                   'inicio'     value to_char(s.INICIO_PREVISTO_EM at time zone 'America/Sao_Paulo', 'HH24"h"MI'),
                   'fim'        value to_char(s.FIM_PREVISTO_EM at time zone 'America/Sao_Paulo', 'HH24"h"MI'),
                   'codigo'     value lpad(a.ID_SESSAO, 8, '0'),
                   'plateia'    value (select json_arrayagg(json_object('apelido' value m.APELIDO, 'cor' value m.COR)
                                                            order by p.ID_PRESENCA returning clob)
                                         from MMM_SESSAO_PRESENCA p
                                         join MMM_MEMBRO m
                                           on m.ID_MEMBRO = p.ID_MEMBRO
                                        where p.ID_SESSAO = a.ID_SESSAO
                                          and p.SITUACAO <> 'SAIU') format json
                   returning clob)
          into l_json
          from MMM_ASSISTIDO a
          join MMM_TITULO t
            on t.ID_TITULO = a.ID_TITULO
          join MMM_GRUPO g
            on g.ID_GRUPO = a.ID_GRUPO
          left join MMM_SESSAO s
            on s.ID_SESSAO = a.ID_SESSAO
         where a.ID_ASSISTIDO = p_id_assistido;
        return l_json;
    end dados_json;

    function cartao_html return clob is
        l_id     number := pendente;
        l_me     number := MMM_PKG_SEGURANCA.id_membro_atual;
        l_titulo MMM_TITULO.TITULO%type;
        l_rasgou MMM_ASSISTIDO.RASGADO_EM%type;
        l_quem   number;
        l_apelido MMM_MEMBRO.APELIDO%type;
        l_fim     timestamp with time zone;
        l_chamada varchar2(4000);
    begin
        if l_id is null then
            return null;
        end if;
        -- o fim previsto do ingresso (serie sem fim previsto: duas horas depois do comeco) so muda a chamada
        select t.TITULO, a.RASGADO_EM, a.ID_MEMBRO_RASGOU,
               (select m.APELIDO from MMM_MEMBRO m where m.ID_MEMBRO = a.ID_MEMBRO_RASGOU),
               nvl(s.FIM_PREVISTO_EM, s.INICIO_PREVISTO_EM + interval '2' hour)
          into l_titulo, l_rasgou, l_quem, l_apelido, l_fim
          from MMM_ASSISTIDO a
          join MMM_TITULO t
            on t.ID_TITULO = a.ID_TITULO
          left join MMM_SESSAO s
            on s.ID_SESSAO = a.ID_SESSAO
         where a.ID_ASSISTIDO = l_id;
        l_chamada := case
                         when l_rasgou is null and l_fim > systimestamp
                         then 'Quando terminarem <b>' || esc(l_titulo) || '</b>, rasgue o ingresso e dê a sua nota.'
                         when l_rasgou is null then 'Assistiram <b>' || esc(l_titulo) || '</b>? Rasgue o ingresso e dê a sua nota.'
                         when l_quem = l_me then 'Falta a sua nota para <b>' || esc(l_titulo) || '</b>.'
                         else esc(l_apelido) || ' rasgou o ingresso de <b>' || esc(l_titulo) || '</b>. Que nota você dá?'
                     end;
        return '<section class="mmm-IngressoPendente" id="mmm-ingresso-pendente" aria-labelledby="mmm-ingresso-pendente-chamada" data-ingresso="'
               || apex_escape.html_attribute(dados_json(l_id)) || '">'
               || '<p class="mmm-IngressoPendente-chamada" id="mmm-ingresso-pendente-chamada">' || l_chamada || '</p>'
               || '<div class="mmm-IngressoPendente-palco"></div>'
               || '</section>';
    end cartao_html;

    function assistidos_html return clob is
        l_me     number := MMM_PKG_SEGURANCA.id_membro_atual;
        l_html   clob;
        l_tem    boolean;
        procedure add(p_texto in varchar2) is
        begin
            dbms_lob.append(l_html, p_texto);
        end add;
        procedure poster(p_path in varchar2) is
        begin
            if regexp_like(p_path, '^/[A-Za-z0-9_-]+\.(jpg|jpeg|png)$') then
                add('<img class="mmm-AssistidoItem-poster" src="https://image.tmdb.org/t/p/w92' || p_path
                    || '" width="46" height="69" alt="" loading="lazy" decoding="async">');
            else
                add('<span class="mmm-AssistidoItem-poster is-vazio" aria-hidden="true"></span>');
            end if;
        end poster;
    begin
        dbms_lob.createtemporary(l_html, true);
        add('<div class="mmm-AssistidosNotas">');

        -- o que foi escolhido e ainda nao teve o ingresso rasgado
        l_tem := false;
        for r in (select a.ID_ASSISTIDO, t.TITULO, t.POSTER_PATH, a.DATA_ASSISTIDO, s.MODO_DESFECHO
                    from MMM_ASSISTIDO a
                    join MMM_TITULO t
                      on t.ID_TITULO = a.ID_TITULO
                    left join MMM_SESSAO s
                      on s.ID_SESSAO = a.ID_SESSAO
                   where a.RASGADO_EM is null
                   order by a.DATA_ASSISTIDO desc, a.ID_ASSISTIDO desc) loop
            if not l_tem then
                add('<h3 class="mmm-AssistidosNotas-titulo">Para assistir</h3><ul class="mmm-AssistidosLista">');
                l_tem := true;
            end if;
            add('<li class="mmm-AssistidoItem is-pendente" data-ingresso="' || apex_escape.html_attribute(dados_json(r.ID_ASSISTIDO)) || '">');
            poster(r.POSTER_PATH);
            add('<div class="mmm-AssistidoItem-texto"><span class="mmm-AssistidoItem-data">Escolhido em '
                || to_char(r.DATA_ASSISTIDO, 'DD/MM/YYYY') || '</span><b>' || esc(r.TITULO) || '</b><span>' || decidido(r.MODO_DESFECHO) || '</span></div>'
                || '<button type="button" class="t-Button mmm-BotaoSec js-mmm-rasgar" aria-label="Rasgar o ingresso de '
                || apex_escape.html_attribute(r.TITULO) || '"><span class="t-Button-label">Rasgar o ingresso</span></button></li>');
        end loop;
        if l_tem then
            add('</ul>');
        end if;

        -- o que ja assistiram, com as notas
        l_tem := false;
        for r in (select a.ID_ASSISTIDO, a.ID_SESSAO, t.TITULO, t.POSTER_PATH, a.DATA_ASSISTIDO, s.MODO_DESFECHO,
                         (select avg(n.PIPOCAS) from MMM_NOTA n where n.ID_ASSISTIDO = a.ID_ASSISTIDO) as MEDIA,
                         (select count(*) from MMM_NOTA n where n.ID_ASSISTIDO = a.ID_ASSISTIDO) as NOTAS,
                         (select n.PIPOCAS from MMM_NOTA n where n.ID_ASSISTIDO = a.ID_ASSISTIDO and n.ID_MEMBRO = l_me) as MINHA
                    from MMM_ASSISTIDO a
                    join MMM_TITULO t
                      on t.ID_TITULO = a.ID_TITULO
                    left join MMM_SESSAO s
                      on s.ID_SESSAO = a.ID_SESSAO
                   where a.RASGADO_EM is not null
                   order by a.DATA_ASSISTIDO desc, a.ID_ASSISTIDO desc
                   fetch first 100 rows only) loop
            if not l_tem then
                add('<h3 class="mmm-AssistidosNotas-titulo">Já assistiram</h3><ul class="mmm-AssistidosLista">');
                l_tem := true;
            end if;
            add('<li class="mmm-AssistidoItem" data-ingresso="' || apex_escape.html_attribute(dados_json(r.ID_ASSISTIDO)) || '">');
            poster(r.POSTER_PATH);
            add('<div class="mmm-AssistidoItem-texto"><span class="mmm-AssistidoItem-data">'
                || to_char(r.DATA_ASSISTIDO, 'DD/MM/YYYY') || '</span><b>' || esc(r.TITULO) || '</b><span>'
                -- marcado na ficha (Ja assistimos) nao tem sessao
                || case when r.ID_SESSAO is null then 'Fora da Hora do Cinema' else decidido(r.MODO_DESFECHO) end || '</span>');
            if r.NOTAS > 0 then
                add('<div class="mmm-Notas"><span class="mmm-Notas-media" role="img" aria-label="Média de '
                    || pipocas_txt(r.MEDIA) || ' de 5 pipocas, ' || r.NOTAS || case r.NOTAS when 1 then ' nota' else ' notas' end || '">'
                    -- a media em meias pipocas, por classe: a CSP recusa estilo inline
                    || '<span class="mmm-Nota mmm-Nota--' || to_char(round(r.MEDIA * 2) * 5) || '"></span>'
                    || '<b>' || pipocas_txt(r.MEDIA) || '</b></span><ul class="mmm-Notas-cada">');
                for n in (select m.APELIDO, m.COR, n.PIPOCAS
                            from MMM_NOTA n
                            join MMM_MEMBRO m
                              on m.ID_MEMBRO = n.ID_MEMBRO
                           where n.ID_ASSISTIDO = r.ID_ASSISTIDO
                           order by n.PIPOCAS desc, m.APELIDO) loop
                    add('<li><span class="mmm-Avatar mmm-Avatar--p mmm-Cor--' || n.COR || '" aria-hidden="true">'
                        || esc(upper(substr(n.APELIDO, 1, 1))) || '</span>' || esc(n.APELIDO) || ' <b>' || n.PIPOCAS
                        || '</b><span class="mmm-Sr"> de 5</span></li>');
                end loop;
                add('</ul></div>');
            end if;
            add('</div>');
            add('<button type="button" class="t-Button mmm-BotaoSec js-mmm-dar-nota" aria-label="'
                || case when r.MINHA is null then 'Dar a sua nota para ' else 'Trocar a sua nota para ' end
                || apex_escape.html_attribute(r.TITULO) || '"><span class="t-Button-label">'
                || case when r.MINHA is null then 'Dar nota' else 'Sua nota: ' || r.MINHA end || '</span></button></li>');
        end loop;
        if l_tem then
            add('</ul>');
        end if;

        if not l_tem and dbms_lob.getlength(l_html) < 40 then
            add('<p class="mmm-AssistidosNotas-vazio">Nada assistido ainda. Quando vocês escolherem um filme na Hora do Cinema, '
                || 'ele aparece aqui; depois do filme, rasguem o ingresso e deem a nota. Assistiram algo da lista fora do jogo? '
                || 'Toquem em Já assistimos na ficha do título.</p>');
        end if;
        add('</div>');
        return l_html;
    end assistidos_html;

    -- Marina e Rafa da demo dao a nota pelo voto que deram ao titulo no baralho
    procedure notas_dos_robos(p_id_assistido in number) is
    begin
        merge into MMM_NOTA n
        using (select a.ID_GRUPO, a.ID_ASSISTIDO, m.ID_MEMBRO,
                      nvl(max(case v.VOTO when 'SUPER' then 5 when 'QUERO' then 4 when 'NAO' then 3 when 'VETO' then 2 end), 4) as PIPOCAS
                 from MMM_ASSISTIDO a
                 join MMM_MEMBRO m
                   on m.ID_GRUPO = a.ID_GRUPO
                 left join MMM_SESSAO_CARTA c
                   on c.ID_SESSAO = a.ID_SESSAO
                  and c.ID_TITULO = a.ID_TITULO
                 left join MMM_VOTO v
                   on v.ID_SESSAO = a.ID_SESSAO
                  and v.ID_CARTA  = c.ID_CARTA
                  and v.ID_MEMBRO = m.ID_MEMBRO
                where a.ID_ASSISTIDO = p_id_assistido
                  and m.PERFIL_SIMULADO is not null
                group by a.ID_GRUPO, a.ID_ASSISTIDO, m.ID_MEMBRO) x
           on (n.ID_ASSISTIDO = x.ID_ASSISTIDO and n.ID_MEMBRO = x.ID_MEMBRO)
         when not matched then insert (ID_GRUPO, ID_ASSISTIDO, ID_MEMBRO, PIPOCAS)
              values (x.ID_GRUPO, x.ID_ASSISTIDO, x.ID_MEMBRO, x.PIPOCAS);
    end notas_dos_robos;

    procedure rasgar(p_id_assistido in number) is
        l_me   number := MMM_PKG_SEGURANCA.id_membro_atual;
        l_demo MMM_GRUPO.FL_DEMO%type;
        l_qtd  pls_integer;
    begin
        -- o VPD so mostra o assistido do grupo ativo: de outro grupo, nada acontece
        select count(*)
          into l_qtd
          from MMM_ASSISTIDO
         where ID_ASSISTIDO = p_id_assistido;
        if l_qtd = 0 or l_me is null then
            raise_application_error(-20801, 'Esse ingresso não é do grupo aberto.');
        end if;
        -- quem rasga primeiro fica; quem chega depois so segue para a nota
        update MMM_ASSISTIDO
           set RASGADO_EM       = systimestamp,
               ID_MEMBRO_RASGOU = l_me,
               DATA_ASSISTIDO   = MMM_PKG_UTIL.hoje_br
         where ID_ASSISTIDO = p_id_assistido
           and RASGADO_EM is null;
        select g.FL_DEMO
          into l_demo
          from MMM_ASSISTIDO a
          join MMM_GRUPO g
            on g.ID_GRUPO = a.ID_GRUPO
         where a.ID_ASSISTIDO = p_id_assistido;
        if l_demo = 'S' then
            notas_dos_robos(p_id_assistido);
        end if;
    end rasgar;

    procedure dar_nota(p_id_assistido in number, p_pipocas in number) is
        l_me     number := MMM_PKG_SEGURANCA.id_membro_atual;
        l_rasgou MMM_ASSISTIDO.RASGADO_EM%type;
    begin
        if p_pipocas is null or p_pipocas not in (1, 2, 3, 4, 5) then
            raise_application_error(-20802, 'Escolha de 1 a 5 pipocas.');
        end if;
        begin
            select RASGADO_EM
              into l_rasgou
              from MMM_ASSISTIDO
             where ID_ASSISTIDO = p_id_assistido;
        exception
            when no_data_found then
                raise_application_error(-20801, 'Esse ingresso não é do grupo aberto.');
        end;
        if l_rasgou is null then
            raise_application_error(-20803, 'Rasgue o ingresso antes de dar a nota.');
        end if;
        if l_me is null then
            raise_application_error(-20801, 'Esse ingresso não é do grupo aberto.');
        end if;
        merge into MMM_NOTA n
        using (select p_id_assistido as ID_ASSISTIDO, l_me as ID_MEMBRO from dual) x
           on (n.ID_ASSISTIDO = x.ID_ASSISTIDO and n.ID_MEMBRO = x.ID_MEMBRO)
         when matched then update set n.PIPOCAS = p_pipocas
         when not matched then insert (ID_ASSISTIDO, ID_MEMBRO, PIPOCAS)
              values (x.ID_ASSISTIDO, x.ID_MEMBRO, p_pipocas);
    end dar_nota;

    function marcar_assistido(p_id_item in number, p_pipocas in number) return number is
        e_ocupado  exception;
        pragma exception_init(e_ocupado, -30006);
        l_me       number := MMM_PKG_SEGURANCA.id_membro_atual;
        l_grupo    MMM_LISTA_ITEM.ID_GRUPO%type;
        l_titulo   MMM_LISTA_ITEM.ID_TITULO%type;
        l_retirado MMM_LISTA_ITEM.RETIRADO_EM%type;
        l_id       MMM_ASSISTIDO.ID_ASSISTIDO%type;
        l_demo     MMM_GRUPO.FL_DEMO%type;
    begin
        if p_pipocas is null or p_pipocas not in (1, 2, 3, 4, 5) then
            raise_application_error(-20802, 'Escolha de 1 a 5 pipocas.');
        end if;
        if l_me is null then
            raise_application_error(-20805, 'Esse título não é da lista do grupo aberto.');
        end if;
        -- a linha travada: quem marca junto com outra pessoa espera a primeira e depois ve o titulo fora da lista
        -- (o VPD so mostra o item do grupo ativo)
        begin
            select ID_GRUPO, ID_TITULO, RETIRADO_EM
              into l_grupo, l_titulo, l_retirado
              from MMM_LISTA_ITEM
             where ID_LISTA_ITEM = p_id_item
               for update wait 3;
        exception
            when no_data_found then
                raise_application_error(-20805, 'Esse título não é da lista do grupo aberto.');
            when e_ocupado then
                raise_application_error(-20807, 'Outra pessoa está marcando este título agora. Tente de novo.');
        end;
        if l_retirado is not null then
            raise_application_error(-20806, 'Esse título já saiu da lista.');
        end if;
        -- serie escolhida na Hora do Cinema continua na lista com o ingresso inteiro: e esse assistido que fica rasgado (o
        -- rasgar ja da as notas dos robos da demo), e nao um segundo, que deixaria o ingresso do jogo pedindo para rasgar
        select max(ID_ASSISTIDO)
          into l_id
          from MMM_ASSISTIDO
         where ID_GRUPO   = l_grupo
           and ID_TITULO  = l_titulo
           and RASGADO_EM is null;
        if l_id is not null then
            rasgar(l_id);
        else
            insert into MMM_ASSISTIDO (ID_GRUPO, ID_TITULO, DATA_ASSISTIDO, RASGADO_EM, ID_MEMBRO_RASGOU)
            values (l_grupo, l_titulo, MMM_PKG_UTIL.hoje_br, systimestamp, l_me)
            returning ID_ASSISTIDO into l_id;
            select FL_DEMO
              into l_demo
              from MMM_GRUPO
             where ID_GRUPO = l_grupo;
        end if;
        update MMM_LISTA_ITEM
           set RETIRADO_EM       = systimestamp,
               MOTIVO_RETIRADA   = 'ASSISTIDO',
               ID_MEMBRO_RETIROU = l_me
         where ID_LISTA_ITEM = p_id_item;
        dar_nota(l_id, p_pipocas);
        -- na demo, Marina e Rafa dao a nota como no Rasgar
        if l_demo = 'S' then
            notas_dos_robos(l_id);
        end if;
        return l_id;
    end marcar_assistido;

    procedure ajax is
        l_acao  varchar2(10) := upper(apex_application.g_x01);
        l_id    number := to_number(apex_application.g_x02 default null on conversion error);
        l_nota  number := to_number(apex_application.g_x03 default null on conversion error);
        l_media number;
        l_qtd   number;
        l_json  clob;
        l_media_txt varchar2(10);
        l_sessao number := to_number(apex_application.g_x04 default null on conversion error);
    begin
        MMM_PKG_SEGURANCA.exigir_grupo_da_tela(apex_application.g_x10);
        -- a pagina 30 conhece a sessao, e nao o assistido: x04 = ID_SESSAO (o VPD so mostra o do grupo aberto)
        if l_id is null and l_sessao is not null then
            select max(ID_ASSISTIDO)
              into l_id
              from MMM_ASSISTIDO
             where ID_SESSAO = l_sessao;
        end if;
        if l_acao = 'DADOS' then
            -- o ingresso como as paginas 1 e 6 o recebem (estado, quem rasgou, a minha nota), para a pagina 30
            if l_id is null then
                raise_application_error(-20801, 'Esse ingresso não é do grupo aberto.');
            end if;
            l_json := dados_json(l_id);
            select json_object('ok' value 'true' format json, 'ingresso' value l_json format json returning clob)
              into l_json
              from dual;
            MMM_PKG_UTIL.imprimir_json(l_json);
            return;
        end if;
        case l_acao
            when 'RASGAR' then rasgar(l_id);
            when 'NOTA'   then dar_nota(l_id, l_nota);
            -- no MARCAR o x02 e o item da lista; dali em diante l_id e o assistido que nasceu, para a media
            when 'MARCAR' then l_id := marcar_assistido(l_id, l_nota);
            else raise_application_error(-20804, 'Pedido desconhecido.');
        end case;
        commit;
        select avg(PIPOCAS), count(*)
          into l_media, l_qtd
          from MMM_NOTA
         where ID_ASSISTIDO = l_id;
        if l_qtd > 0 then
            l_media_txt := pipocas_txt(l_media);
        end if;
        select json_object(
                   'ok'    value 'true' format json,
                   'media' value l_media_txt,
                   'notas' value l_qtd
                   returning clob)
          into l_json
          from dual;
        MMM_PKG_UTIL.imprimir_json(l_json);
    exception
        when others then
            MMM_PKG_UTIL.responder_erro(sqlcode, sqlerrm, dbms_utility.format_error_stack || dbms_utility.format_error_backtrace);
    end ajax;

end MMM_PKG_INGRESSO;
/
