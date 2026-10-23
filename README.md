# Match My Movie

![Oracle APEX](https://img.shields.io/badge/Oracle%20APEX-26.1.5-F80000)
![Oracle AI Database](https://img.shields.io/badge/Oracle%20AI%20Database-26ai-F80000)
![OCI](https://img.shields.io/badge/OCI-Autonomous%20Database-312D2A)
![PL/SQL](https://img.shields.io/badge/PL%2FSQL-1f4e79)
![PWA](https://img.shields.io/badge/PWA-instal%C3%A1vel-5A0FC8)
![Cloudflare Workers](https://img.shields.io/badge/Cloudflare-Workers-F38020)
![MIT](https://img.shields.io/badge/license-MIT-green)

<p align="justify">Aplicação para escolher em grupo o que assistir, construída em <b>Oracle APEX</b> sobre <b>Autonomous Database</b>: cada pessoa vota no próprio celular e o filme da noite sai num jogo rápido.</p>

**[Abrir a demonstração](https://mmm.cleitonrcruz.com.br/demo)**. Não precisa de login: a demonstração abre um grupo de exemplo por 24 horas, com a Marina e o Rafa votando junto.

<p align="center"><img src="docs/img/inicio.webp" alt="Tela inicial do Match My Movie" width="390"></p>

## O que faz

<p align="justify">Cada grupo tem uma lista do que quer ver, com o catálogo do TMDB, os pôsteres, onde assistir no Brasil, quem sugeriu e quanta vontade a pessoa tem, de uma a três pipocas. Dá para adicionar pela busca, por filme, série, pessoa ou saga, ou colando a lista antiga do bloco de notas. Na Hora do Cinema, o grupo responde a abertura (filme ou série, tempo, clima, criança, aluguel e relógio por carta) e recebe um baralho de até 15 cartas, que cada um vota no próprio celular, com super e veto. A revelação é simultânea, o desempate sai por duelo ou roleta, e o vencedor vira um ingresso com o botão Assistir. Depois de assistir, alguém rasga o ingresso e cada um dá a sua nota. O que viram fora do jogo também entra: na ficha do título, o Já assistimos pede a nota e leva o título da lista para os assistidos. No fim da ficha, o Você também pode gostar mostra as recomendações do TMDB que o grupo ainda não viu nem escolheu na Hora do Cinema; o toque abre a ficha do título, e o Adicionar à lista o põe na lista com a vontade de quem adicionou. Os convites saem por link, com cartão de prévia no WhatsApp, ou por código; o push avisa quando a sessão começa e quem ainda falta votar; e o login é com a conta Google, com a opção de manter conectado no aparelho.</p>

## Stack

| Camada | Tecnologia |
|---|---|
| Banco | Oracle AI Database 26ai Autonomous (Always Free), versão 23.26.4.1.0 |
| Aplicação | Oracle APEX 26.1.5, Universal Theme 42 |
| Front-end | JavaScript, HTML e CSS próprios sobre o Universal Theme |
| PWA | Instalável, com o Web Push nativo do APEX |
| Domínio | Cloudflare Worker na frente do ORDS |
| Dados | API do TMDB (catálogo e onde assistir, via JustWatch) e Streaming Availability (link direto para o serviço) |
| Login | Google (OAuth2), com a troca do código pelo token feita no Worker |

## Decisões técnicas

- Segurança por grupo com VPD (`DBMS_RLS`): as tabelas com dado do grupo têm política ([`05_politicas.sql`](db/05_politicas.sql)), e o predicado, em [`MMM_PKG_SEGURANCA`](db/03_seguranca.sql), lê o grupo ativo no banco. A tela nunca escolhe o grupo: o id que ela manda serve só de conferência. O convite fica de fora do VPD, porque quem aceita ainda não é membro e só chega a ele pelo código.
- Voto em sigilo pelo próprio banco: enquanto o baralho está em votação, uma segunda política em `MMM_VOTO` deixa cada pessoa ver só o próprio voto.
- O jogo roda no servidor. Cada rotina que muda a sessão trava a linha (`FOR UPDATE WAIT 3`) e sobe a versão, e os celulares acompanham por polling, que recua no 429 e no 5xx ([`MMM_PKG_JOGO`](db/09_jogo.sql), [`mmm-jogo.js`](apex/static/mmm-jogo.js)).
- Catálogo dentro dos termos do TMDB: os títulos em uso são renovados aos 30 dias e nada fica guardado mais de 175 dias ([`MMM_PKG_TMDB`](db/07_tmdb.sql), [`MMM_PKG_RETENCAO`](db/10_retencao.sql), [`jobs`](db/jobs/)).
- Manter conectado com seletor e validador: o banco guarda o hash do validador e o próximo cifrado com uma chave tirada do validador atual, que não fica gravado, então quem lê a tabela não monta um cookie. O validador troca a cada uso, e se um antigo volta a ser usado a família inteira é revogada ([`MMM_PKG_LEMBRAR`](db/11_lembrar.sql)).
- Demonstração sem login: visitante de 24 horas, com grupo próprio e dois robôs que votam pelo servidor, e um teto de visitas contado pelo IP, guardado só como hash ([`MMM_PKG_DEMO`](db/06_grupo_demo.sql)).
- Worker com lista fechada de caminhos: o convite `/c/<código>` entrega o cartão de prévia aos robôs do WhatsApp e leva as pessoas para a entrada ([`worker/src/index.js`](worker/src/index.js)).
- Auditoria sem dado pessoal nas tabelas do app: `CRIADO_POR` e `ALTERADO_POR` guardam o id do usuário, não o e-mail ([`04_objetos.sql`](db/04_objetos.sql)). O log de integração guarda o login para contar a cota e o teto da demo, e sai aos 90 dias.

## Organização

| Arquivo ou pasta | Conteúdo |
|---|---|
| `db/01_tabelas.sql` | Tabelas, chaves e comentários do dicionário |
| `db/02a_carga_inicial.sql`, `db/02b_carga_pos_app.sql` | Serviços de streaming, climas, robôs da demo, o mapeamento clima-gênero e a lista de exemplo |
| `db/03_seguranca.sql` | `MMM_PKG_SEGURANCA`: os predicados do VPD, o usuário e o grupo ativo |
| `db/04_objetos.sql` | Triggers de auditoria, a saída do grupo e as views |
| `db/05_politicas.sql` | As políticas de VPD |
| `db/05_util_http.sql` | `MMM_PKG_UTIL` e `MMM_PKG_HTTP`: configuração, push, log e as chamadas HTTP, com disjuntor e cota |
| `db/06_grupo_demo.sql` | `MMM_PKG_GRUPO` e `MMM_PKG_DEMO`: grupos, convites e a demonstração |
| `db/07_tmdb.sql` | `MMM_PKG_TMDB`: busca, detalhes, onde assistir, sagas, pessoas e recomendações |
| `db/08_sa_lista.sql` | `MMM_PKG_SA` e `MMM_PKG_LISTA`: o botão Assistir, a lista do grupo e a ficha do título |
| `db/09_jogo.sql` | `MMM_PKG_JOGO`: abertura, baralho, votos, revelação, duelo, roleta e placar |
| `db/10_retencao.sql` | `MMM_PKG_RETENCAO`: expurgos, a faxina da demo, a anonimização de contas e o alerta de renovação parada |
| `db/11_lembrar.sql` | `MMM_PKG_LEMBRAR`: manter conectado no aparelho |
| `db/12_ingresso.sql` | `MMM_PKG_INGRESSO`: o ingresso rasgado, as notas e o Já assistimos da ficha |
| `db/jobs` | Os jobs do scheduler |
| `apex/static` | O JavaScript e o CSS do app |
| `worker` | O Worker do domínio e a configuração dele |

## Sobre este repositório

<p align="justify">É um recorte do projeto, não a aplicação inteira: o banco, o front-end e o Worker. O export do APEX fica de fora, assim como as fontes e os ícones, que têm licença própria, e as credenciais do TMDB, do Streaming Availability, do Google e do Worker, que ficam no banco e no Cloudflare. Este produto usa a API do TMDB, mas não é endossado nem certificado pelo TMDB.</p>

## Autor

Cleiton Cruz, desenvolvedor Oracle APEX e PL/SQL.
[linkedin.com/in/cleitonrcruz](https://www.linkedin.com/in/cleitonrcruz/)
