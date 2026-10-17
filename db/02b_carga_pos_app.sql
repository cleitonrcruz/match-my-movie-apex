-- Script 02, parte B (depois do app e das credenciais do TMDB): mapeamento clima-genero, conferencia e lista da demo.

-- liga pelo nome gravado em MMM_GENERO: os generos de serie que o TMDB manda em ingles ja chegam com o nome
-- de MMM_PKG_TMDB.nome_genero
insert into MMM_CLIMA_GENERO (ID_CLIMA, ID_GENERO)
select c.ID_CLIMA,
       g.ID_GENERO
  from json_table(q'~[
        {"t":"FILME","c":"risada","g":"Comédia"},
        {"t":"FILME","c":"quentinho","g":"Animação"},
        {"t":"FILME","c":"quentinho","g":"Família"},
        {"t":"FILME","c":"romance","g":"Romance"},
        {"t":"FILME","c":"chorar","g":"Drama"},
        {"t":"FILME","c":"unhas","g":"Thriller"},
        {"t":"FILME","c":"unhas","g":"Mistério"},
        {"t":"FILME","c":"unhas","g":"Crime"},
        {"t":"FILME","c":"susto","g":"Terror"},
        {"t":"FILME","c":"adrenalina","g":"Ação"},
        {"t":"FILME","c":"adrenalina","g":"Aventura"},
        {"t":"FILME","c":"mundo","g":"Ficção científica"},
        {"t":"FILME","c":"mundo","g":"Fantasia"},
        {"t":"SERIE","c":"risada","g":"Comédia"},
        {"t":"SERIE","c":"investigar","g":"Crime"},
        {"t":"SERIE","c":"investigar","g":"Mistério"},
        {"t":"SERIE","c":"prender","g":"Drama"},
        {"t":"SERIE","c":"adrenalina","g":"Ação e aventura"},
        {"t":"SERIE","c":"mundo","g":"Ficção científica e fantasia"},
        {"t":"SERIE","c":"quentinho","g":"Animação"},
        {"t":"SERIE","c":"quentinho","g":"Família"}
       ]~', '$[*]'
       columns (
           TIPO_TITULO  varchar2(5)  path '$.t',
           CODIGO       varchar2(30) path '$.c',
           GENERO       varchar2(60) path '$.g')) m
  join MMM_CLIMA c
    on c.TIPO_TITULO = m.TIPO_TITULO
   and c.CODIGO      = m.CODIGO
  join MMM_GENERO g
    on g.NOME = m.GENERO
   and ((m.TIPO_TITULO = 'FILME' and g.FL_FILME = 'S')
     or (m.TIPO_TITULO = 'SERIE' and g.FL_SERIE = 'S'));

select c.TIPO_TITULO,
       c.CODIGO
  from MMM_CLIMA c
 where not exists (select 1
                     from MMM_CLIMA_GENERO cg
                    where cg.ID_CLIMA = c.ID_CLIMA);

set serveroutput on

declare
    l_id number;
begin
    for d in (select jt.TIPO, jt.ID_TMDB, jt.ROBO, jt.PIPOCAS, jt.ORIGEM
                from json_table(q'~[
                      ["FILME",1032863,"MARINA",3,"Viu o trailer no Instagram"],
                      ["FILME",687163,"RAFA",3,"Indicação de amigo"],
                      ["FILME",157336,null,2,"Quero rever"],
                      ["FILME",1184918,"MARINA",3,"A irmã dela indicou"],
                      ["FILME",933260,"RAFA",2,"Todo mundo comentou"],
                      ["FILME",350,"MARINA",2,"Quero rever"],
                      ["FILME",1233413,"RAFA",3,"Viu o trailer"],
                      ["FILME",1368166,null,2,"Indicação de amigo"],
                      ["FILME",27205,null,1,"Quero rever"],
                      ["FILME",1022789,"MARINA",2,"Para ver com os sobrinhos"],
                      ["FILME",4935,"MARINA",2,"Rede social"],
                      ["FILME",238,"RAFA",1,"Nunca viu, precisa"],
                      ["FILME",76341,"RAFA",2,"Quero rever"],
                      ["FILME",1168190,null,2,"Viu o trailer"],
                      ["FILME",1007757,"MARINA",2,"Rede social"],
                      ["FILME",1000837,null,3,"Todo mundo indicou"],
                      ["FILME",598,"RAFA",2,"Quero rever"],
                      ["FILME",138843,"RAFA",2,"Noite de terror"],
                      ["FILME",693134,null,3,"Vimos o primeiro"],
                      ["SERIE",2316,"MARINA",2,"Rever do começo"],
                      ["SERIE",97546,null,3,"Indicação de amigo"],
                      ["SERIE",1396,"RAFA",3,"Parou na 3ª temporada"],
                      ["SERIE",95480,null,2,"Podcast"],
                      ["SERIE",60625,"RAFA",1,"Episódio solto"],
                      ["FILME",40096,"MARINA",3,"Quero rever"],
                      ["FILME",7347,"RAFA",2,"Quero rever"],
                      ["FILME",666,null,2,"Nunca vimos"],
                      ["SERIE",95350,"RAFA",2,"Viu o trailer"],
                      ["SERIE",108978,"RAFA",2,"Indicação de amigo"],
                      ["SERIE",66732,"MARINA",2,"Falta a última temporada"],
                      ["SERIE",119051,"MARINA",3,"Rede social"],
                      ["SERIE",136315,null,3,"Todo mundo indicou"],
                      ["SERIE",95396,null,3,"Podcast"],
                      ["SERIE",100088,"RAFA",3,"Jogou o game"],
                      ["SERIE",93405,"RAFA",2,"Viu o trailer"],
                      ["SERIE",1421,"MARINA",1,"Para ver no almoço"],
                      ["SERIE",78074,null,2,"Indicação de amigo"],
                      ["SERIE",110529,"MARINA",2,"Rede social"]
                     ]~', '$[*]'
                     columns (
                         TIPO     varchar2(5)   path '$[0]',
                         ID_TMDB  number        path '$[1]',
                         ROBO     varchar2(10)  path '$[2]',
                         PIPOCAS  number        path '$[3]',
                         ORIGEM   varchar2(100) path '$[4]')) jt) loop
        begin
            l_id := MMM_PKG_TMDB.garantir_titulo(d.TIPO, d.ID_TMDB);
            merge into MMM_DEMO_ITEM i
            using (select l_id as ID_TITULO from dual) s
               on (i.ID_TITULO = s.ID_TITULO)
             when not matched then insert (ID_TITULO, LOGIN_SUGERIU, PIPOCAS, ORIGEM)
                  values (s.ID_TITULO, nvl2(d.ROBO, 'ROBO:' || d.ROBO, null), d.PIPOCAS, d.ORIGEM);
            commit;
        exception
            when others then
                rollback;
                dbms_output.put_line(d.TIPO || ' ' || d.ID_TMDB || ': ' || sqlerrm);
        end;
    end loop;
end;
/
