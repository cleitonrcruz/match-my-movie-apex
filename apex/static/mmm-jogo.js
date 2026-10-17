// Páginas 20 e 30: o servidor (MMM_JOGO) decide tudo; a tela só desenha o estado que volta dele.
// Polling por versão, jogadas em fila (uma de cada vez, na ordem) e guardadas se a rede cair no meio.
// APEX_JSON omite a chave com valor nulo: no estado, nas cartas e nas contagens, chave ausente vale nulo ou falso.
apex.jQuery(function () {
  "use strict";

  var mmm = window.mmm;
  if (!mmm) { return; }
  mmm.jogo = mmm.jogo || {};

  var TERMINAIS = ["ENCERRADA", "SEM_RESULTADO", "CANCELADA", "ABANDONADA"];
  var SORTEIO = 0.3;               // até 30% a mais em cada espera, para os aparelhos do sofá não voltarem juntos
  var falhas = 0;                  // recusas seguidas (429, 5xx, rede, sessão ocupada); zera na primeira resposta boa
  var pausaAte = 0;                // o servidor pediu para esperar (429 ou 5xx): nada sai deste aparelho antes disso
  var sobrecargas = 0;             // só as recusas por sobrecarga seguidas (429 e 5xx) sobem a espera do recuo; a queda de
                                   // rede fica de fora; zera na primeira resposta boa

  // 429 da ATP: usa o Retry-After quando vem (em segundos ou data, no máximo 2 min); senão 2 s × 2^n até 30 s, com n
  // a partir de 0 na primeira recusa
  function esperaRecusa(e, n) {
    var ra = e && typeof e.getResponseHeader === "function" ? e.getResponseHeader("Retry-After") : null;
    var ms = ra ? (isFinite(Number(ra)) ? Number(ra) * 1000 : Date.parse(ra) - Date.now()) : NaN;
    var base = ms > 0 ? Math.min(ms, 120000) : Math.min(30000, 2000 * Math.pow(2, Math.max(0, n - 1)));
    return base + Math.floor(Math.random() * base * SORTEIO);
  }

  // a ATP pedindo para esperar: o 429, e também o 5xx (sobrecarga ou manutenção, com ou sem Retry-After, e o 500 ou os
  // 52x da Cloudflare quando a origem cai atrás do Worker), que senão voltariam a cada 3 s como queda de rede. Os pacotes
  // nunca respondem 5xx: a recusa de regra vem em 200 com ok false
  function sobrecarga(e) {
    return !!e && (e.status === 429 || e.status >= 500);
  }

  function recuar(e) {
    sobrecargas += 1;
    pausaAte = Date.now() + esperaRecusa(e, sobrecargas);
  }

  // pedido de uma vez só (cartas, criar, contar, entrar, o Assistir): no 429 ou 5xx volta sozinho, com o mesmo recuo das
  // jogadas, antes de a tela mostrar a falha; recusa do servidor e queda de rede vão direto para quem pediu.
  // aindaQuer (opcional): a tela já pediu outra coisa e esta resposta não serve mais
  function insistir(processo, dados, vezes, aindaQuer) {
    return new Promise(function (ok, falha) {
      var n = 0;
      (function tentar() {
        if (aindaQuer && !aindaQuer()) { falha({ cancelado: true }); return; }
        if (Date.now() < pausaAte) {
          window.setTimeout(tentar, pausaAte - Date.now());
          return;
        }
        mmm.chamar(processo, dados, true).then(function (r) {
          falhas = 0;
          sobrecargas = 0;
          ok(r);
        }, function (e) {
          n += 1;
          if (sobrecarga(e) && n < (vezes || 3)) {
            falhas += 1;
            recuar(e);
            window.setTimeout(tentar, pausaAte - Date.now());
            return;
          }
          falha(e);
        });
      })();
    });
  }
  mmm.jogo.pedir = insistir;

  // depois de CRIAR e CUTUCAR: entrega já o push que ficou na fila (o job do APEX leva uns 2 minutos)
  function empurrarPush() {
    return mmm.chamar("MMM_JOGO", { x01: "PUSH" }, true).catch(function () { return null; });
  }

  /* ---------- abertura (página 20) ---------- */
  // x04 de CONTAGENS e CRIAR no contrato de MMM_PKG_JOGO.ler_filtros: tipo, regra e final em maiúsculas,
  // crianca e aluguel em "S"/"N", tempo e relógio em número ou null. A conversão abaixo aceita booleano, minúsculas e Set,
  // e o servidor recusa valor fora da lista em vez de cair no padrão
  function contrato(f) {
    f = f || {};
    // a tela guarda as escolhas em Set: sem converter, sairiam listas vazias sem aviso
    function lista(v) { return Array.isArray(v) ? v.slice() : v instanceof Set ? Array.from(v) : []; }
    function sn(v) { return v === true || v === "S" || v === "s" ? "S" : "N"; }
    return {
      tipo: String(f.tipo || "").toUpperCase(),
      // o que não é número vai como veio e o servidor recusa: NaN sairia null no JSON, que é "sem pressa"
      tempo: f.tempo === undefined || f.tempo === null || f.tempo === "" ? null
        : isFinite(Number(f.tempo)) ? Number(f.tempo) : f.tempo,
      climas: lista(f.climas),
      recortes: lista(f.recortes),
      servicos: lista(f.servicos),
      aluguel: sn(f.aluguel),
      crianca: sn(f.crianca),
      regra: String(f.regra || "TODOS").toUpperCase(),
      final: String(f.final || "DUELOS").toUpperCase(),
      // segundos por carta no baralho; null é sem relógio (o servidor só aceita 10, 20 e 30)
      relogio: f.relogio === undefined || f.relogio === null || f.relogio === "" ? null
        : isFinite(Number(f.relogio)) ? Number(f.relogio) : f.relogio,
      presentes: lista(f.presentes).map(Number)
    };
  }

  // a contagem vem do servidor, com o mesmo filtro que monta o baralho: o número na tela é o que vai para a mesa
  // falhou (opcional): a tela fica sabendo da queda ou do 429 e não espera para sempre por uma contagem que não vem
  var contagens = 0;
  mmm.jogo.contar = apex.util.debounce(function (filtros, desenhar, falhou) {
    var minha = ++contagens;
    insistir("MMM_JOGO", { x01: "CONTAGENS", x04: JSON.stringify(contrato(filtros)) }, 3, function () { return minha === contagens; })
      .then(desenhar, function (e) {
        if (e && e.cancelado) { return; }
        mmm.erro(e);
        if (falhou) { falhou(e); }
      });
  }, 250);

  mmm.jogo.darCartas = function (filtros) {
    return insistir("MMM_JOGO", { x01: "CRIAR", x04: JSON.stringify(contrato(filtros)) }, 3).then(function (r) {
      // a demo não manda push (o servidor nem enfileira): o PUSH seria só mais um pedido na vaga HTTP da ATP
      var push = !r || r.demo !== true ? empurrarPush() : null;
      // a troca de página cancelava o PUSH no meio do caminho: espera a resposta dele, no máximo 1,5 s
      var prazo = new Promise(function (ok) { window.setTimeout(ok, push ? 1500 : 0); });
      return Promise.race([push ? Promise.resolve(push) : prazo, prazo]).then(function () {
        // replace: o Voltar da sessão cai no início, não numa abertura já usada
        window.location.replace($v("P20_URL_SESSAO"));
      });
    }, function (e) {
      if (e && e.erro === "em_andamento") {
        mmm.toast("O grupo já tem uma sessão em andamento.", {
          rotulo: "Entrar",
          fn: function () { window.location.replace($v("P20_URL_SESSAO")); }
        });
        return;
      }
      // pedido silencioso: sem este aviso, a queda de rede (ou o 429 que não passou) não diria nada
      if (!e || !e.recusado) {
        mmm.toast("Não deu certo agora. Tente de novo.");
        return;
      }
      mmm.erro(e);
    });
  };

  /* ---------- sessão (página 30) ---------- */
  var raiz = document.getElementById("mmm-jogo");
  if (!raiz) { return; }

  var SESSAO = raiz.getAttribute("data-sessao");
  var DEMO = raiz.getAttribute("data-demo") === "S";
  var CHAVE = "mmm-jogadas-" + SESSAO;
  // o limite da ATP Always Free é o HTTP (3 a 6 usuários somando os outros apps do banco): só pergunta quem espera
  // outra pessoa, com intervalo que cresce (fora quando só falta uma pessoa votar: faltaUm) e sorteio para os
  // aparelhos do sofá não perguntarem juntos
  var RAPIDO = 4000;               // primeira pergunta na espera
  var PASSO = 2000;                // cada "nada mudou" soma isto
  var MAXIMO = 15000;
  // roleta na mesa, à espera do giro: quem não tocou pergunta a cada 2 s e vê o giro quase junto com quem tocou;
  // depois de 3 min sem ninguém girar, volta a espaçar, para não pesar na ATP
  var ROLETA = 2000;
  var ROLETA_ATE = 3 * 60 * 1000;
  var DESISTE = 30 * 60 * 1000;    // meia hora sem mudança: para e espera um toque
  var REDE = 3000;                 // jogada que não saiu por queda de rede tenta de novo neste ritmo

  var versao = null;
  var ultimo = null;
  var intervalo = RAPIDO;
  var timer = null;
  var ultimaMudanca = Date.now();
  // na demo tudo muda dentro da requisição do próprio visitante: não há o que perguntar
  var ativo = !DEMO;
  var enviando = false;
  var timerEnvio = null;           // o único reenvio marcado (jogada nova durante o recuo espera junto)
  var envioEm = 0;
  var memoria = [];
  var telaLigada = null;

  function emitir(nome, dados) {
    raiz.dispatchEvent(new CustomEvent(nome, { detail: dados }));
  }

  function manterTela(ligar) {
    if (!("wakeLock" in navigator)) { return; }
    if (ligar && !telaLigada && document.visibilityState === "visible") {
      navigator.wakeLock.request("screen").then(function (w) {
        telaLigada = w;
        w.addEventListener("release", function () { telaLigada = null; });
      }, function () { telaLigada = null; });
    } else if (!ligar && telaLigada) {
      telaLigada.release();
      telaLigada = null;
    }
  }

  function parar() {
    ativo = false;
    window.clearTimeout(timer);
    manterTela(false);
  }

  // votando o próprio baralho ou devendo voto no duelo aberto não há o que perguntar: cada voto já devolve
  // o estado, e um cancelamento aparece no voto seguinte
  function esperando(r) {
    // sem estado ainda (o ENTRAR e o recarregar falharam, ex.: 429 na abertura): pergunta até ter um
    if (!r) { return true; }
    if (TERMINAIS.indexOf(r.status) >= 0) { return false; }
    var situacao = r.eu && r.eu.situacao;
    if (r.status === "VOTANDO") {
      return situacao !== "CONVIDADO" && situacao !== "VOTANDO";
    }
    if (r.status === "FINAL" && r.final === "DUELOS") {
      var atual = r.duelos && r.duelos.atual;
      // meuVoto nulo não vem do servidor: sem ele, quem está PRONTO ainda deve o voto
      return !(atual && situacao === "PRONTO" && !atual.meuVoto);
    }
    return true;
  }

  // só falta uma pessoa votar, no baralho ou no duelo aberto: o voto dela decide a mesa, e quem espera continua no ritmo
  // de 4 s em vez de espaçar até 15 s. Quem espera já votou (esperando)
  function faltaUm(r) {
    if (!r || !r.eu) { return false; }
    var faltam;
    if (r.status === "VOTANDO") {
      faltam = (r.presencas || []).filter(function (p) { return p.situacao === "CONVIDADO" || p.situacao === "VOTANDO"; });
    } else if (r.status === "FINAL" && r.final === "DUELOS" && r.duelos && r.duelos.atual) {
      var ja = r.duelos.atual.jaVotaram || [];
      faltam = (r.presencas || []).filter(function (p) { return p.situacao === "PRONTO" && ja.indexOf(p.id) < 0; });
    } else {
      return false;
    }
    return faltam.length === 1 && faltam[0].id !== r.eu.id;
  }

  function naRoleta(r) {
    return !!r && r.status === "FINAL" && r.final === "ROLETA" && Date.now() - ultimaMudanca < ROLETA_ATE;
  }

  function agendar() {
    window.clearTimeout(timer);
    if (ativo && document.visibilityState === "visible" && esperando(ultimo)) {
      var ms = intervalo + Math.floor(Math.random() * intervalo * SORTEIO);
      timer = window.setTimeout(perguntar, Math.max(ms, pausaAte - Date.now()));
    }
  }

  function aplicar(r) {
    // resposta de polling que saiu antes de uma jogada não pode voltar a tela
    if (versao !== null && r.v < versao) { return; }
    versao = r.v;
    if (!r.mudou) {
      intervalo = naRoleta(ultimo) ? ROLETA : faltaUm(ultimo) ? RAPIDO : Math.min(MAXIMO, intervalo + PASSO);
      return;
    }
    ultimo = r;
    ultimaMudanca = Date.now();
    intervalo = naRoleta(r) ? ROLETA : RAPIDO;
    emitir("mmmestado", r);
    if (TERMINAIS.indexOf(r.status) >= 0) {
      parar();
    } else {
      manterTela(true);
    }
  }

  // grupo trocado noutro aparelho: esta tela não grava mais nada, e a certa vem ao recarregar
  function trocouDeGrupo(e) {
    parar();
    window.clearTimeout(timerEnvio);
    timerEnvio = null;
    guardar([]);
    mmm.toast(e.message, { rotulo: "Recarregar", fn: function () { window.location.reload(); } });
  }

  function perguntar() {
    window.clearTimeout(timer);
    if (!ativo || document.visibilityState === "hidden") { return; }
    if (Date.now() < pausaAte) {
      timer = window.setTimeout(perguntar, pausaAte - Date.now());
      return;
    }
    mmm.chamar("MMM_JOGO", { x01: "ESTADO", x02: SESSAO, x05: versao === null ? "" : String(versao) }, true)
      .then(function (r) {
        falhas = 0;
        sobrecargas = 0;
        aplicar(r);
        if (Date.now() - ultimaMudanca > DESISTE) {
          parar();
          emitir("mmmpausa", null);
        }
      }, function (e) {
        if (e && e.recusado && e.erro === "grupo") {
          trocouDeGrupo(e);
          return;
        }
        if (e && e.recusado && (e.erro === "acesso" || e.erro === "parametro")) {
          // sessão de outro grupo ou apagada: não adianta insistir
          parar();
          mmm.toast(e.message);
          return;
        }
        // 429, 5xx, rede ou recusa de passagem (sessão ocupada, erro interno): pergunta de novo mais devagar.
        // e é o jqXHR do apex.server.process: o mmm.chamar repassa a rejeição sem trocá-la
        falhas += 1;
        if (sobrecarga(e)) { recuar(e); }
        intervalo = MAXIMO;
      })
      .then(agendar);
  }

  // estado inteiro de novo (redesenho depois de uma recusa)
  function recarregar() {
    versao = null;
    return insistir("MMM_JOGO", { x01: "ESTADO", x02: SESSAO }, 3).then(aplicar, mmm.erro);
  }

  function pendentes() {
    try {
      var s = window.sessionStorage.getItem(CHAVE);
      return s ? JSON.parse(s) : memoria;
    } catch (e) {
      return memoria;
    }
  }

  function guardar(lista) {
    memoria = lista;
    try {
      window.sessionStorage.setItem(CHAVE, JSON.stringify(lista));
    } catch (e) {
      /* sem storage: a fila fica só na memória desta página */
    }
  }

  // um reenvio marcado de cada vez: a jogada feita durante o recuo espera junto, em vez de abrir outra tentativa
  // (eram várias cadeias, uma por jogada, e o Retry-After não segurava nenhuma)
  function marcarEnvio(ms) {
    window.clearTimeout(timerEnvio);
    envioEm = Date.now() + Math.max(0, ms);
    timerEnvio = window.setTimeout(function () {
      timerEnvio = null;
      enviar();
    }, Math.max(0, ms));
  }

  function enviar() {
    if (enviando || timerEnvio) { return; }
    var lista = pendentes();
    if (!lista.length) { return; }
    if (Date.now() < pausaAte) {
      marcarEnvio(pausaAte - Date.now());
      return;
    }
    enviando = true;
    var j = lista[0];
    mmm.chamar("MMM_JOGO", { x01: j.a, x02: SESSAO, x03: j.x3 || "", x04: j.x4 || "" }, true).then(function (r) {
      enviando = false;
      falhas = 0;
      sobrecargas = 0;
      guardar(pendentes().slice(1));
      aplicar(r);
      if (j.a === "CUTUCAR" && !DEMO) { empurrarPush(); }
      enviar();
      agendar();
    }, function (e) {
      enviando = false;
      if (e && e.recusado && e.erro === "grupo") {
        // a fila desta sessão sai antes do aviso à tela, para nada gravar depois sem recarregar e a carta voltar
        trocouDeGrupo(e);
        emitir("mmmrecusado", { jogada: j, erro: e.erro });
        return;
      }
      if (e && e.recusado && e.erro !== "ocupado") {
        // o servidor recusou (ex.: super já usado): sem tirar da fila as jogadas seguintes ficariam presas
        guardar(pendentes().slice(1));
        if (e.erro !== "aguarde") { recarregar().then(agendar); }
        mmm.toast(e.message);
        emitir("mmmrecusado", { jogada: j, erro: e.erro });
        enviar();
        return;
      }
      // 429, 5xx, rede ou sessão ocupada por outra jogada: a jogada vale e fica na fila; volta depois do recuo (429, 5xx e
      // ocupada) ou no ritmo da rede, sem todos os aparelhos repetirem no mesmo instante
      falhas += 1;
      if (sobrecarga(e) || (e && e.erro === "ocupado")) {
        recuar(e);
        marcarEnvio(pausaAte - Date.now());
      } else {
        marcarEnvio(REDE);
      }
    });
  }

  // a tela marca a jogada na hora e o estado que volta confirma ou corrige
  mmm.jogo.jogar = function (acao, x3, x4) {
    var lista = pendentes().slice();
    lista.push({ a: acao, x3: x3 === undefined || x3 === null ? "" : String(x3), x4: x4 || "" });
    guardar(lista);
    enviar();
  };

  // jogadas que ainda não voltaram do servidor (a que está indo é a primeira): a tela conta com elas para não
  // devolver ao baralho a carta que já saiu
  mmm.jogo.pendentes = function () { return pendentes().slice(); };

  mmm.jogo.votar = function (idCarta, voto) { mmm.jogo.jogar("VOTAR", idCarta, voto); };
  mmm.jogo.desfazer = function (idCarta) { mmm.jogo.jogar("DESFAZER", idCarta); };
  mmm.jogo.votarDuelo = function (idDuelo, lado) { mmm.jogo.jogar("DUELO", idDuelo, lado); };
  mmm.jogo.atual = function () { return ultimo; };

  mmm.jogo.retomar = function () {
    ativo = !DEMO;
    intervalo = RAPIDO;
    ultimaMudanca = Date.now();
    perguntar();
  };

  // as cartas (título, pôster, sinopse, onde) vêm uma vez; o polling só traz ids e contagens. No 429 volta sozinho
  // (até 4 vezes) antes de a tela dizer que não deu para abrir
  mmm.jogo.cartas = function () {
    return insistir("MMM_JOGO", { x01: "CARTAS", x02: SESSAO }, 4);
  };

  document.addEventListener("visibilitychange", function () {
    if (document.visibilityState === "visible") {
      // o navegador solta o bloqueio de tela quando o app vai para segundo plano
      telaLigada = null;
      // em segundo plano o navegador atrasa o reenvio marcado: se a hora dele já passou, vai agora
      if (timerEnvio && Date.now() >= envioEm) {
        window.clearTimeout(timerEnvio);
        timerEnvio = null;
      }
      enviar();
      if (ativo) {
        intervalo = RAPIDO;
        perguntar();
      }
    } else {
      window.clearTimeout(timer);
    }
  });

  // a rede voltou: a jogada parada pela queda sai agora (a de um 429 continua esperando o recuo)
  window.addEventListener("online", function () {
    window.clearTimeout(timerEnvio);
    timerEnvio = null;
    enviar();
    perguntar();
  });

  // entrar marca presença; quem chegou tarde ou já saiu acompanha como espectador. As jogadas que ficaram na fila
  // (recarga no meio da sessão) saem depois, dando certo ou não o ENTRAR
  insistir("MMM_JOGO", { x01: "ENTRAR", x02: SESSAO }, 3).then(function (r) {
    aplicar(r);
    enviar();
    agendar();
  }, function () {
    recarregar().then(function () {
      enviar();
      agendar();
    });
  });
});
