-- Script 02, parte A (antes das politicas): servicos, climas e robos.

insert into MMM_SERVICO (CODIGO, NOME, CATEGORIA, CODIGO_SA, ORDEM)
select j.CODIGO, j.NOME, j.CATEGORIA, j.CODIGO_SA, j.ORDEM
  from json_table(q'~[
        {"c":"netflix","n":"Netflix","t":"ASSINATURA","sa":"netflix","o":10},
        {"c":"prime","n":"Prime Video","t":"ASSINATURA","sa":"prime","o":20},
        {"c":"hbo","n":"HBO Max","t":"ASSINATURA","sa":"hbo","o":30},
        {"c":"disney","n":"Disney+","t":"ASSINATURA","sa":"disney","o":40},
        {"c":"globoplay","n":"Globoplay","t":"ASSINATURA","o":50},
        {"c":"appletv","n":"Apple TV","t":"ASSINATURA","sa":"apple","o":60},
        {"c":"paramount","n":"Paramount+","t":"ASSINATURA","sa":"paramount","o":70},
        {"c":"claro","n":"Claro tv+","t":"ASSINATURA","o":80},
        {"c":"mubi","n":"MUBI","t":"ASSINATURA","sa":"mubi","o":90},
        {"c":"telecine","n":"Telecine","t":"ASSINATURA","o":100},
        {"c":"universal","n":"Universal+","t":"ASSINATURA","o":110},
        {"c":"mgm","n":"MGM+","t":"ASSINATURA","o":120},
        {"c":"oldflix","n":"Oldflix","t":"ASSINATURA","o":130},
        {"c":"arte","n":"Arte","t":"ASSINATURA","o":140},
        {"c":"mercado","n":"Mercado Play","t":"ASSINATURA","o":150},
        {"c":"apple_loja","n":"Apple TV (loja)","t":"LOJA","sa":"apple","o":200},
        {"c":"amazon_loja","n":"Amazon (aluguel)","t":"LOJA","sa":"prime","o":210},
        {"c":"google","n":"Google Play","t":"LOJA","o":220},
        {"c":"claro_video","n":"Claro video","t":"LOJA","o":230}
       ]~', '$[*]'
       columns (
           CODIGO     varchar2(30) path '$.c',
           NOME       varchar2(60) path '$.n',
           CATEGORIA  varchar2(10) path '$.t',
           CODIGO_SA  varchar2(30) path '$.sa',
           ORDEM      number       path '$.o')) j;

insert into MMM_CLIMA (TIPO_TITULO, CODIGO, NOME, DICA, ICONE, ORDEM)
select j.TIPO_TITULO, j.CODIGO, j.NOME, j.DICA, j.ICONE, j.ORDEM
  from json_table(q'~[
        {"t":"FILME","c":"risada","n":"Dar risada","d":"comédia","i":"riso","o":1},
        {"t":"FILME","c":"quentinho","n":"Coração quentinho","d":"animação e família","i":"caneca","o":2},
        {"t":"FILME","c":"romance","n":"Clima de romance","d":"romance","i":"coracao","o":3},
        {"t":"FILME","c":"chorar","n":"Chorar no sofá","d":"drama","i":"gota","o":4},
        {"t":"FILME","c":"unhas","n":"Roer as unhas","d":"suspense e crime","i":"raio","o":5},
        {"t":"FILME","c":"susto","n":"Levar susto","d":"terror","i":"fantasma","o":6},
        {"t":"FILME","c":"adrenalina","n":"Adrenalina","d":"ação e aventura","i":"chama","o":7},
        {"t":"FILME","c":"mundo","n":"Outro mundo","d":"ficção e fantasia","i":"planeta","o":8},
        {"t":"SERIE","c":"risada","n":"Dar risada","d":"comédia","i":"riso","o":1},
        {"t":"SERIE","c":"investigar","n":"Investigar o crime","d":"crime e mistério","i":"lupa","o":2},
        {"t":"SERIE","c":"prender","n":"Drama que prende","d":"drama","i":"gota","o":3},
        {"t":"SERIE","c":"adrenalina","n":"Adrenalina","d":"ação e aventura","i":"chama","o":4},
        {"t":"SERIE","c":"mundo","n":"Outro mundo","d":"ficção e fantasia","i":"planeta","o":5},
        {"t":"SERIE","c":"quentinho","n":"Leve e divertida","d":"animação e família","i":"caneca","o":6}
       ]~', '$[*]'
       columns (
           TIPO_TITULO  varchar2(5)  path '$.t',
           CODIGO       varchar2(30) path '$.c',
           NOME         varchar2(40) path '$.n',
           DICA         varchar2(60) path '$.d',
           ICONE        varchar2(30) path '$.i',
           ORDEM        number       path '$.o')) j;

insert into MMM_USUARIO (LOGIN, TIPO, NOME)
values ('ROBO:MARINA', 'ROBO', 'Marina');

insert into MMM_USUARIO (LOGIN, TIPO, NOME)
values ('ROBO:RAFA', 'ROBO', 'Rafa');

commit;
