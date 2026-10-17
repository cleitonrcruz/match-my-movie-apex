// Proxy reverso do Match My Movie (app 103 da ATP) no subdominio mmm. O visitante fala com o
// dominio; o Worker repete o pedido na ATP e devolve a resposta. So passam os caminhos que o app usa: paginas e arquivos
// do app, arquivos do APEX (/i/) e as rotas do proprio APEX. App Builder, admin, REST e o resto da ATP ficam de fora.

// login com Google atras do proxy: a ATP monta o redirect_uri com o nome dela e o Google exige o mesmo valor na
// autorizacao e na troca do codigo. O Worker troca o da ATP pelo do dominio nos dois pontos: no Location que leva o
// navegador ao Google e no POST da troca do codigo, que a ATP faz para ca em vez de ir direto ao Google
const GOOGLE_AUTORIZACAO = "https://accounts.google.com/o/oauth2/v2/auth";
const GOOGLE_TOKEN = "https://oauth2.googleapis.com/token";
const ROTA_TOKEN = "/_oauth/google/token";

// robos que montam a previa do link (WhatsApp, Telegram, iMessage, Facebook, X, Slack, Discord, LinkedIn, Teams): nao
// guardam sessao, entao o convite vai direto a pagina 50, que tem o nome do grupo, quem convidou e a imagem nas etiquetas
// og:. O Signal busca a previa com o nome do WhatsApp, e o iMessage com o do Facebook e do X
const ROBO_PREVIA = /WhatsApp|facebookexternalhit|Facebot|TelegramBot|Twitterbot|Slackbot|Discordbot|LinkedInBot|SkypeUriPreview|Pinterest|redditbot|Iframely|Embedly|vkShare|Viber|Snapchat|Google-PageRenderer/i;

const callbackAtp = (env) => `${env.ORIGEM}/ords/apex_authentication.callback`;
const callbackProprio = (env) => `https://${env.CANONICO}/ords/apex_authentication.callback`;

// o client_id vem no corpo (client_secret_post) ou no Authorization Basic (client_secret_basic)
function clienteDoPedido(pedido, corpo) {
  if (corpo.get("client_id")) return corpo.get("client_id");
  const basico = (pedido.headers.get("authorization") || "").match(/^basic\s+(.+)$/i);
  if (!basico) return null;
  try {
    return decodeURIComponent(atob(basico[1]).split(":")[0]);
  } catch (erro) {
    return null;
  }
}

// so repassa o pedido do proprio app: nao vira proxy aberto para o endpoint de token do Google
async function trocarCodigo(pedido, env) {
  if (pedido.method !== "POST") return new Response(null, { status: 405 });
  const corpo = new URLSearchParams(await pedido.text());
  if (clienteDoPedido(pedido, corpo) !== env.GOOGLE_CLIENT_ID) return new Response(null, { status: 403 });
  if (corpo.get("redirect_uri") === callbackAtp(env)) corpo.set("redirect_uri", callbackProprio(env));
  const cabecalhos = new Headers({ "content-type": "application/x-www-form-urlencoded", accept: "application/json" });
  if (pedido.headers.has("authorization")) cabecalhos.set("authorization", pedido.headers.get("authorization"));
  const resposta = await fetch(GOOGLE_TOKEN, { method: "POST", headers: cabecalhos, body: corpo.toString() });
  return new Response(resposta.body, {
    status: resposta.status,
    headers: { "content-type": resposta.headers.get("content-type") || "application/json", "cache-control": "no-store" },
  });
}

// a ATP recusa chamada com Origin diferente de https:// + host recebido; atras do Worker o host recebido e o da ATP,
// entao o Origin do proprio dominio vira o da ATP e qualquer outra origem para aqui
function origemPermitida(pedido, proprio) {
  const origem = pedido.headers.get("origin");
  return !origem || origem === proprio;
}

function permitido(url, metodo, env) {
  const p = url.pathname;
  // o URL do runtime resolve '..' e '%2e%2e', mas deixa '%2f' e '%5c' codificados, e a ATP decodificaria por conta propria:
  // nenhum caminho do app usa esses escapes
  if (/%2f|%5c|%2e|%00/i.test(p)) return false;
  const leitura = metodo === "GET" || metodo === "HEAD";
  if (p === env.APP.replace(/\/$/, "") || p.startsWith(env.APP)) return true;
  if (leitura && (p.startsWith(env.ARQUIVOS) || p.startsWith("/i/"))) return true;
  if (leitura && (p === "/ords/wwv_flow.js_messages" || p === "/ords/wwv_flow.js_dialogs")) return true;
  if (metodo === "POST" && (p === "/ords/wwv_flow.ajax" || p === "/ords/wwv_flow.accept")) return true;
  // link antigo f?p= so para o proprio app (pelo id ou pelo alias)
  if (leitura && p === "/ords/f") {
    if (url.searchParams.getAll("p").length !== 1) return false;
    const app = url.searchParams.get("p").split(":")[0].toUpperCase();
    return app === env.APP_ID || app === env.APP_ALIAS;
  }
  // volta do Google e saida da sessao
  if (leitura && (p === "/ords/apex_authentication.callback" || p === "/ords/apex_authentication.logout")) return true;
  return false;
}

// o APEX manda o cookie da sessao sem validade, e o app da Tela de Inicio do iPhone perde cookie de sessao quando e
// fechado: o cookie da sessao do app (COOKIE_SESSAO) ganha a vida da sessao do app 103, 30 dias. O que ja tem validade
// fica como veio, e tambem o do logout: o APEX 26.1 apaga com o valor -1, sem validade
const VALIDADE_COOKIE = 2592000;

function precisaValidade(cookie, nome) {
  const [par, ...atributos] = cookie.split(";");
  const igual = par.indexOf("=");
  if (igual < 0 || par.slice(0, igual).trim() !== nome) return false;
  const valor = par.slice(igual + 1).trim();
  if (valor === "" || valor === "-1") return false;
  return !atributos.some((a) => /^\s*(expires|max-age)\s*=/i.test(a));
}

function manterCookie(cabecalhos, nome) {
  const cookies = cabecalhos.getSetCookie();
  if (!cookies.some((c) => precisaValidade(c, nome))) return;
  cabecalhos.delete("set-cookie");
  for (const c of cookies) cabecalhos.append("set-cookie", precisaValidade(c, nome) ? `${c}; Max-Age=${VALIDADE_COOKIE}` : c);
}

// sem sessao, a pagina protegida responde 302 direto a escolha de conta do Google, e o Session Not Valid do login social
// do APEX 26.1 nao muda isso. Na navegacao de pagina (o app instalado que volta depois de a sessao
// sumir e recarrega a pagina, o link tocado nela, o atalho do manifesto) a pessoa vai para a entrada, que tem o Continuar
// com o Google. So pagina do app: a volta do Google (callback) segue como o APEX mandar. Seguem ao Google o pedido de
// login (request APEX_AUTHENTICATION: o botao da entrada e o do convite), a pagina 51 do convite e o que nao e navegacao
// de pagina. A navegacao que o service worker do app repete chega com o Sec-Fetch-Dest empty (medido no Chrome), entao
// vale o Sec-Fetch-Mode, fora a moldura declarada
function semPedidoDeLogin(pedido, url, env) {
  if (pedido.method !== "GET" || pedido.headers.get("sec-fetch-mode") !== "navigate") return false;
  if (["iframe", "frame", "embed", "object"].includes(pedido.headers.get("sec-fetch-dest"))) return false;
  if (!url.pathname.startsWith(env.APP) && url.pathname !== "/ords/f") return false;
  const p = (url.searchParams.get("p") || "").split(":");
  if (url.pathname === `${env.APP}entrar-no-grupo` || (url.pathname === "/ords/f" && ["51", "ENTRAR-NO-GRUPO"].includes((p[1] || "").toUpperCase()))) return false;
  const request = url.searchParams.get("request") || p[3] || "";
  return !/^APEX_AUTHENTICATION=/i.test(request);
}

// cache da borda: os arquivos do APEX (/i/<versao>/) mudam de caminho a cada versao e ficam um ano; os do app levam no
// caminho uma versao que nao muda quando o arquivo muda, entao ficam so uma hora. Erro nao fica
function cacheDaBorda(p, env) {
  if (p.startsWith("/i/")) return { cacheEverything: true, cacheTtlByStatus: { "200-299": 31536000, "300-599": 0 } };
  if (p.startsWith(env.ARQUIVOS)) return { cacheEverything: true, cacheTtlByStatus: { "200-299": 3600, "300-599": 0 } };
  return null;
}

export default {
  async fetch(pedido, env) {
    const url = new URL(pedido.url);
    const proprio = url.origin;
    const destino = new URL(env.ORIGEM);

    // http e outro host vao para o endereco oficial em https; em http os cookies do app (Secure, __Host-)
    // seriam descartados pelo navegador. CANONICO vazio so nos testes locais
    if (env.CANONICO && (url.protocol !== "https:" || url.hostname !== env.CANONICO)) {
      return Response.redirect(`https://${env.CANONICO}${url.pathname}${url.search}`, 301);
    }
    if (url.pathname === ROTA_TOKEN) return trocarCodigo(pedido, env);
    // atalhos publicos: convite pelo codigo e entrada direta na demonstracao. Sem item nem request no endereco: para eles
    // o APEX abre sessao nova, e o cookie dela toma o lugar da sessao logada do navegador (o app instalado passaria a abrir
    // fora da conta). O convite vai pela entrada com o codigo no fragmento (o mmm.js segue para a pagina 50, na sessao de
    // agora ou na publica); a demonstracao vai a 9998, que so pede o esquema VISITANTE a quem nao esta conectado
    const convite = url.pathname.match(/^\/c\/([A-HJ-NP-Z2-9]{8})$/i);
    if (convite) {
      const codigo = convite[1].toUpperCase();
      if (ROBO_PREVIA.test(pedido.headers.get("user-agent") || "")) return Response.redirect(`${proprio}${env.APP}convite?p50_codigo=${codigo}`, 302);
      return Response.redirect(`${proprio}${env.APP}entrar#convite=${codigo}`, 302);
    }
    if (url.pathname === "/demo") return Response.redirect(`${proprio}${env.APP}visitante`, 302);
    if (url.pathname === "/" || url.pathname === "") {
      return Response.redirect(`${proprio}${env.INICIO}`, 302);
    }
    if (!permitido(url, pedido.method, env)) {
      return new Response("Página não encontrada.", { status: 404, headers: { "content-type": "text/plain; charset=utf-8" } });
    }
    if (!origemPermitida(pedido, proprio)) {
      return new Response("Origem não permitida.", { status: 403, headers: { "content-type": "text/plain; charset=utf-8" } });
    }

    const cabecalhos = new Headers(pedido.headers);
    cabecalhos.delete("host");
    // so o Worker escreve estes cabecalhos (os do cliente sao descartados); o banco confere o segredo e conta as
    // visitas da demo pelo IP de verdade
    cabecalhos.delete("x-mmm-proxy");
    cabecalhos.delete("x-mmm-ip");
    if (env.MMM_SEGREDO) {
      cabecalhos.set("x-mmm-proxy", env.MMM_SEGREDO);
      cabecalhos.set("x-mmm-ip", pedido.headers.get("cf-connecting-ip") || "");
    }
    if (cabecalhos.has("origin")) cabecalhos.set("origin", destino.origin);
    const referer = cabecalhos.get("referer");
    if (referer && referer.startsWith(proprio)) cabecalhos.set("referer", destino.origin + referer.slice(proprio.length));

    const alvo = new URL(url.pathname + url.search, destino);
    const opcoes = { method: pedido.method, headers: cabecalhos, redirect: "manual" };
    if (pedido.method !== "GET" && pedido.method !== "HEAD") opcoes.body = pedido.body;
    const cache = cacheDaBorda(url.pathname, env);
    if (cache) opcoes.cf = cache;
    // leitura que falha na conexao (conexao reaproveitada que a origem ja fechou) tenta de novo uma vez; POST e a pagina
    // 'ir' (conta o clique antes de redirecionar) nao, para nao contar em dobro
    let resposta;
    try {
      resposta = await fetch(alvo, opcoes);
    } catch (erro) {
      if ((pedido.method !== "GET" && pedido.method !== "HEAD") || url.pathname === `${env.APP}ir`) throw erro;
      resposta = await fetch(alvo, opcoes);
    }

    // redirecionamento para a propria ATP volta para o dominio, se o caminho for do app; os outros seguem como vieram
    // 101, 204, 205 e 304 nao podem levar corpo: o 304 aparece quando o navegador ja tem o arquivo em cache
    const semCorpo = [101, 204, 205, 304].includes(resposta.status);
    const saida = new Response(semCorpo ? null : resposta.body, resposta);
    const location = resposta.headers.get("location");
    if (location) {
      const l = new URL(location, destino);
      if (l.origin === destino.origin && permitido(l, "GET", env)) {
        saida.headers.set("location", proprio + l.pathname + l.search);
      } else if (l.origin + l.pathname === GOOGLE_AUTORIZACAO) {
        if (semPedidoDeLogin(pedido, url, env)) {
          saida.headers.set("location", `${proprio}${env.INICIO}`);
        } else if (l.searchParams.get("redirect_uri") === callbackAtp(env)) {
          l.searchParams.set("redirect_uri", callbackProprio(env));
          saida.headers.set("location", l.toString());
        }
      }
    }
    // vazio, nada muda
    if (env.COOKIE_SESSAO) manterCookie(saida.headers, env.COOKIE_SESSAO);
    return saida;
  },
};
