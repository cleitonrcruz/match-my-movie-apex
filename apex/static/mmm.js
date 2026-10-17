// Match My Movie: núcleo de todas as páginas (#APP_FILES#mmm.js?v=N em User Interface Attributes > JavaScript > File URLs).
// Nada de JS inline na página: com a CSP da 26.1 só passa arquivo do próprio site ou script do APEX com nonce.
(function (apex, $) {
  "use strict";

  var mmm = window.mmm = window.mmm || {};
  var CDN = "https://image.tmdb.org/t/p/";
  var CAMINHO_TMDB = /^\/[A-Za-z0-9_-]+\.(jpg|jpeg|png|svg)$/;
  var CLASSIFICACOES = ["L", "10", "12", "14", "16", "18"];
  // tamanhos do CDN do TMDB; conferir a lista em /configuration antes de fixar
  var TAMANHOS = {
    poster: { src: "w342", srcset: ["w185", "w342", "w500"] },
    mini: { src: "w92", srcset: ["w92", "w185"] },
    fundo: { src: "w780", srcset: ["w780", "w1280"] },
    logo: { src: "w92", srcset: ["w45", "w92"] },
    // foto de pessoa: o CDN só tem w45, w185 e h632; a w185 cobre o círculo pequeno em tela de 2x e 3x
    perfil: { src: "w185", srcset: ["w185"] }
  };

  // página do app pelo endereço amigável (/ords/r/<espaço>/<app>/<página>): a entrada e o convite saem dele
  var NO_APP = /\/r\/[^/]+\/[^/]+\/[^/]*$/;

  // convite aberto de fora: o /c/<código> do Worker leva a entrar#convite=<código>, sem item no endereço, e a entrada
  // reaproveita a sessão do navegador (com item, o APEX abre sessão nova e o cookie dela toma o lugar da sessão logada).
  // Conectado, a entrada leva à página 1, ou a Meus grupos (2) para quem não tem grupo aberto, e ela segue para o convite
  // na sessão de agora (a 50 leva a conta Google à 51);
  // sem conexão, a entrada segue para o convite público. O fragmento sai da URL antes, e só vale o código do convite
  function seguirConvite() {
    var pagina = String(apex.env.APP_PAGE_ID);
    if (window.location.hash.indexOf("#convite=") !== 0 || (pagina !== "1" && pagina !== "2" && pagina !== "9999") || window.self !== window.top) { return; }
    var codigo = /^#convite=([A-HJ-NP-Z2-9]{8})$/i.exec(window.location.hash);
    window.history.replaceState(window.history.state, "", window.location.pathname + window.location.search);
    if (!codigo || !NO_APP.test(window.location.pathname)) { return; }
    var convite = new URL("convite", window.location.href);
    convite.searchParams.set("p50_codigo", codigo[1].toUpperCase());
    if (pagina !== "9999") { convite.searchParams.set("session", apex.env.APP_SESSION); }
    window.location.replace(convite.href);
  }
  seguirConvite();

  // app que volta do segundo plano muito tempo depois: o APEX 26.1 guarda no máximo um dia parado e a limpeza de
  // hora em hora apaga a sessão vencida; um toque nesta página velha iria ao Google. Escondida por mais de 12 horas, a
  // página recomeça pela entrada, que leva à lista com a sessão viva e mostra a fachada sem ela
  var LONGE_MS = 12 * 60 * 60 * 1000;
  var escondidaEm = document.visibilityState === "hidden" ? Date.now() : null;
  document.addEventListener("visibilitychange", function () {
    if (document.visibilityState === "hidden") {
      escondidaEm = Date.now();
      return;
    }
    var longe = escondidaEm !== null && Date.now() - escondidaEm > LONGE_MS;
    escondidaEm = null;
    if (longe && apex.env.APP_USER !== "nobody" && window.self === window.top && NO_APP.test(window.location.pathname)) {
      window.location.replace(new URL("entrar", window.location.href).href);
    }
  });

  mmm.instalado = function () {
    return window.matchMedia("(display-mode: standalone)").matches || window.navigator.standalone === true;
  };

  mmm.ehIos = function () {
    return /iPhone|iPad|iPod/.test(navigator.userAgent) ||
      (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);
  };

  // uma chamada de cada vez e na ordem: rajada em paralelo já rendeu 429 em proxy
  var fila = Promise.resolve();
  mmm.chamar = function (processo, dados, silencioso) {
    var opcoes = { dataType: "json" };
    var envio = $.extend({}, dados || {});
    // o grupo que esta tela mostra vai como conferência: o servidor recusa se o ativo mudou em outro aparelho
    if (envio.x10 === undefined && document.getElementById("P0_GRUPO_TELA")) {
      envio.x10 = $v("P0_GRUPO_TELA");
    }
    // no polling e na fila de jogadas a falha de rede tem nova tentativa:
    // sem um error próprio o APEX mostraria o aviso padrão a cada tentativa
    if (silencioso) { opcoes.error = function () { return null; }; }
    var chamada = fila.then(function () {
      return apex.server.process(processo, envio, opcoes);
    }).then(function (r) {
      if (!r || r.ok !== true) {
        var e = new Error((r && r.mensagem) || "Não deu certo agora. Tente de novo.");
        e.recusado = true;
        e.erro = r && r.erro;
        e.resposta = r;
        throw e;
      }
      return r;
    });
    fila = chamada.catch(function () { return null; });
    return chamada;
  };

  var toastTimer = null;

  function esconderToast() {
    var caixa = document.getElementById("mmm-toast");
    if (caixa) { caixa.classList.remove("is-visivel"); }
  }

  function agendarToast(ms) {
    window.clearTimeout(toastTimer);
    toastTimer = window.setTimeout(esconderToast, ms);
  }

  mmm.toast = function (mensagem, acao) {
    var caixa = document.getElementById("mmm-toast");
    if (!caixa) { return; }
    caixa.textContent = "";
    var texto = document.createElement("span");
    texto.textContent = mensagem;
    caixa.appendChild(texto);
    if (acao) {
      var b = document.createElement("button");
      b.type = "button";
      b.className = "mmm-Toast-acao";
      b.textContent = acao.rotulo;
      b.addEventListener("click", function () {
        esconderToast();
        acao.fn();
      });
      caixa.appendChild(b);
    }
    caixa.dataset.tempo = acao ? "6000" : "2600";
    caixa.classList.add("is-visivel");
    agendarToast(Number(caixa.dataset.tempo));
  };

  // falha de rede já sai no aviso padrão do APEX; aqui fica a recusa do servidor, com o texto dele
  mmm.erro = function (e) {
    if (e && e.recusado) { mmm.toast(e.message); }
  };

  mmm.anunciar = function (texto) {
    var a = document.getElementById("mmm-anuncio");
    if (!a) { return; }
    a.textContent = "";
    window.setTimeout(function () { a.textContent = texto; }, 30);
  };

  function el(tag, classe, texto) {
    var n = document.createElement(tag);
    if (classe) { n.className = classe; }
    if (texto !== undefined && texto !== null && texto !== "") { n.textContent = String(texto); }
    return n;
  }
  mmm.el = el;

  function linkExterno(classe, href, texto) {
    var a = el("a", classe, texto);
    if (/^https:\/\//.test(href || "")) {
      a.href = href;
      a.target = "_blank";
      a.rel = "noopener";
    } else {
      a.setAttribute("aria-disabled", "true");
    }
    return a;
  }
  mmm.linkExterno = linkExterno;

  // caminho fora do padrão do TMDB não vira URL: sai um quadro vazio do tamanho da capa
  mmm.imagem = function (caminho, tipo, sizes, alt) {
    var t = TAMANHOS[tipo] || TAMANHOS.poster;
    if (!CAMINHO_TMDB.test(caminho || "")) {
      return el("span", "mmm-Imagem--vazia mmm-Imagem--" + (TAMANHOS[tipo] ? tipo : "poster"));
    }
    var img = document.createElement("img");
    img.alt = alt || "";
    img.decoding = "async";
    img.loading = "lazy";
    img.src = CDN + t.src + caminho;
    img.srcset = t.srcset.map(function (w) { return CDN + w + caminho + " " + w.slice(1) + "w"; }).join(", ");
    img.sizes = sizes || "100vw";
    return img;
  };

  mmm.pipocas = function (n) {
    var v = Math.max(1, Math.min(3, Number(n) || 1));
    var s = el("span", "mmm-Pipocas mmm-Pipocas--" + v);
    s.setAttribute("role", "img");
    s.setAttribute("aria-label", "Vontade " + v + " de 3");
    return s;
  };

  mmm.classificacao = function (c) {
    if (CLASSIFICACOES.indexOf(c) < 0) { return null; }
    var s = el("span", "mmm-Classind mmm-Classind--" + c, c);
    s.setAttribute("role", "img");
    s.setAttribute("aria-label", c === "L" ? "Classificação livre" : "Classificação " + c + " anos");
    return s;
  };

  // seta de enfeite: fora do nome acessível do botão
  mmm.seta = function (s) {
    var e = el("span", "mmm-Seta", s);
    e.setAttribute("aria-hidden", "true");
    return e;
  };

  // foto da pessoa num círculo; sem foto válida, a inicial do nome
  mmm.foto = function (caminho, nome) {
    if (CAMINHO_TMDB.test(caminho || "")) {
      var img = mmm.imagem(caminho, "perfil", "44px", "");
      img.className = "mmm-Foto";
      return img;
    }
    var s = el("span", "mmm-Foto mmm-Foto--inicial", String(nome || "?").trim().charAt(0).toUpperCase());
    s.setAttribute("aria-hidden", "true");
    return s;
  };

  mmm.avatar = function (apelido, cor, pequeno) {
    var a = el("span", "mmm-Avatar mmm-Cor--" + (Number(cor) || 1) + (pequeno ? " mmm-Avatar--p" : ""),
      String(apelido || "?").charAt(0).toUpperCase());
    a.setAttribute("aria-hidden", "true");
    return a;
  };

  mmm.duracaoTexto = function (t) {
    if (t.tipo === "SERIE") {
      return t.temporadas ? t.temporadas + (t.temporadas === 1 ? " temporada" : " temporadas") : "série";
    }
    if (!t.duracao) { return ""; }
    var h = Math.floor(t.duracao / 60);
    var m = t.duracao % 60;
    return (h ? h + "h" : "") + (m < 10 && h ? "0" : "") + m + (h ? "" : " min");
  };

  // gaveta (Inline Drawer): o Voltar do Android fecha a gaveta em vez de sair da página
  mmm.abrirGaveta = function (id) {
    apex.theme.openRegion(id);
    window.history.pushState({ mmmGaveta: id }, "");
  };

  mmm.fecharGaveta = function (id) {
    if (window.history.state && window.history.state.mmmGaveta === id) {
      window.history.back();
    } else {
      apex.theme.closeRegion(id);
    }
  };

  window.addEventListener("popstate", function () {
    document.querySelectorAll(".mmm-Gaveta").forEach(function (g) {
      if (g.id) { apex.theme.closeRegion(g.id); }
    });
  });

  // teclado do celular: o Chrome do Android e o Safari encolhem só a área visível, e a gaveta presa ao rodapé ficava atrás
  // dele, com os botões. Enquanto o teclado está aberto, a página leva a classe e as medidas, e o mmm.css sobe a gaveta
  // até a borda dele (se não couber no que sobra da tela, ela rola por dentro)
  if (window.visualViewport) {
    var visivel = window.visualViewport;
    var acompanharTeclado = function () {
      var coberto = Math.max(0, Math.round(window.innerHeight - visivel.height - visivel.offsetTop));
      var aberto = coberto > 80;
      var raiz = document.documentElement;
      raiz.classList.toggle("mmm-ComTeclado", aberto);
      raiz.style.setProperty("--mmm-teclado", (aberto ? coberto : 0) + "px");
      raiz.style.setProperty("--mmm-visivel", Math.round(visivel.height) + "px");
    };
    visivel.addEventListener("resize", acompanharTeclado);
    visivel.addEventListener("scroll", acompanharTeclado);
  }

  var PAPEL_FICHA = { DIRECAO: "direção", CRIACAO: "criação" };
  var AREA_FICHA = { ELENCO: "Atuação", DIRECAO: "Direção", CRIACAO: "Criação" };

  // Faz parte da saga e Mais com: só onde a gaveta Adicionar existe (o mmm-inicio.js da página 1 registra mmm.explorar)
  function maisDaFicha(t) {
    var pessoas = (t.pessoas || []).filter(function (p) { return p && p.id && p.nome; });
    var saga = t.saga && t.saga.id && t.saga.nome ? t.saga : null;
    if (!mmm.explorar || (!saga && !pessoas.length)) { return null; }
    var bloco = el("section", "mmm-FichaMais");
    if (saga) {
      var b = el("button", "mmm-FichaMais-saga js-mmm-explorar");
      b.type = "button";
      b.dataset.tipo = "saga";
      b.dataset.id = String(saga.id);
      b.dataset.nome = saga.nome;
      b.appendChild(el("span", "mmm-FichaMais-rotulo", "Faz parte da saga"));
      b.appendChild(el("b", null, saga.nome));
      b.appendChild(mmm.seta("›"));
      bloco.appendChild(b);
    }
    if (pessoas.length) {
      var titulo = el("h3", null, "Mais com");
      titulo.id = "mmm-ficha-mais-com";
      bloco.appendChild(titulo);
      var lista = el("div", "mmm-Chips");
      lista.setAttribute("role", "group");
      lista.setAttribute("aria-labelledby", titulo.id);
      pessoas.forEach(function (p) {
        var c = el("button", "mmm-Chip mmm-Chip--pessoa js-mmm-explorar");
        c.type = "button";
        c.dataset.tipo = "pessoa";
        c.dataset.id = String(p.id);
        c.dataset.nome = p.nome;
        if (p.fotoPath) { c.dataset.foto = p.fotoPath; }
        if (AREA_FICHA[p.papel]) { c.dataset.area = AREA_FICHA[p.papel]; }
        c.setAttribute("aria-label", "Mais com " + p.nome + (PAPEL_FICHA[p.papel] ? " (" + PAPEL_FICHA[p.papel] + ")" : ""));
        c.appendChild(mmm.foto(p.fotoPath, p.nome));
        var txt = el("span", "mmm-Chip-texto");
        txt.appendChild(el("b", null, p.nome));
        if (PAPEL_FICHA[p.papel]) { txt.appendChild(el("small", null, PAPEL_FICHA[p.papel])); }
        c.appendChild(txt);
        lista.appendChild(c);
      });
      bloco.appendChild(lista);
    }
    return bloco;
  }

  function desenharFicha(t) {
    var corpo = document.getElementById("mmm-ficha-corpo");
    if (!corpo) { return; }
    corpo.textContent = "";

    var fundo = el("div", "mmm-Ficha-fundo");
    fundo.appendChild(mmm.imagem(t.fundo, "fundo", "(min-width: 560px) 560px, 100vw", ""));
    corpo.appendChild(fundo);

    var titulo = el("h2", "mmm-Ficha-titulo", t.titulo);
    titulo.id = "mmm-ficha-titulo";
    // a gaveta foca o primeiro [autofocus] ao abrir; sem ele iria ao Trailer e rolaria a ficha para baixo do fundo
    titulo.tabIndex = -1;
    titulo.setAttribute("autofocus", "");
    corpo.appendChild(titulo);

    var meta = el("div", "mmm-LinhaMeta");
    var ci = mmm.classificacao(t.cls);
    if (ci) { meta.appendChild(ci); }
    // nota com vírgula, como se escreve no Brasil (o JSON traz 8.4)
    [t.ano, mmm.duracaoTexto(t), t.nota ? "nota " + Number(t.nota).toFixed(1).replace(".", ",") : null].forEach(function (v) {
      if (v) { meta.appendChild(el("span", "mmm-LinhaMeta-item", v)); }
    });
    corpo.appendChild(meta);

    if (t.item) {
      var s = el("div", "mmm-Sugestao");
      s.appendChild(mmm.avatar(t.item.apelido, t.item.cor));
      s.appendChild(el("span", "mmm-Sugestao-texto",
        t.item.apelido + " sugeriu" + (t.item.origem ? ": " + t.item.origem : "")));
      s.appendChild(mmm.pipocas(t.item.pipocas));
      corpo.appendChild(s);
    }

    if (t.sinopse) {
      var p = el("p", "mmm-Ficha-sinopse", t.sinopse);
      if (t.sinopseIdioma && t.sinopseIdioma !== "pt-BR") {
        p.lang = t.sinopseIdioma;
        corpo.appendChild(el("p", "mmm-Credito", "Sinopse em outro idioma: o TMDB não tem em português."));
      }
      corpo.appendChild(p);
    } else {
      corpo.appendChild(el("p", "mmm-Ficha-sinopse is-vazia", "O TMDB ainda não tem sinopse deste título."));
    }
    if (t.generos && t.generos.length) {
      corpo.appendChild(el("div", "mmm-LinhaMeta", t.generos.join(" · ")));
    }
    var mais = maisDaFicha(t);
    if (mais) { corpo.appendChild(mais); }

    var onde = el("section", "mmm-Onde");
    onde.appendChild(el("h3", null, "Onde assistir no Brasil"));
    if (!t.onde || !t.onde.length) {
      onde.appendChild(el("p", null, "Não está em nenhum serviço agora."));
    } else {
      t.onde.forEach(function (o) {
        var linha = el("div", "mmm-Servico");
        linha.appendChild(mmm.imagem(o.logo, "logo", "34px", ""));
        var txt = el("div", null, o.nome);
        txt.appendChild(el("small", null, o.tipo === "ASSINATURA" ? "na assinatura" : "aluguel ou compra"));
        if (o.saiEm) { txt.appendChild(el("small", "mmm-Servico-sai", "sai do catálogo em " + o.saiEm)); }
        linha.appendChild(txt);
        onde.appendChild(linha);
      });
    }
    onde.appendChild(el("p", "mmm-Credito", "Dados de onde assistir: JustWatch."));
    corpo.appendChild(onde);

    var botoes = el("div", "mmm-Botoes");
    if (/^[A-Za-z0-9_-]{6,20}$/.test(t.trailer || "")) {
      botoes.appendChild(linkExterno("t-Button", "https://www.youtube.com/watch?v=" + t.trailer, "Trailer"));
    }
    botoes.appendChild(linkExterno("t-Button", t.tmdbUrl, "Ver no TMDB"));
    corpo.appendChild(botoes);

    // Já assistimos: só na página 1, onde está a lista e o mmm-ingresso.js traz o painel das pipocas
    if (t.item && String(apex.env.APP_PAGE_ID) === "1" && mmm.ingresso && mmm.ingresso.painelNota) {
      var vimos = el("button", "t-Button mmm-Botao--largo js-mmm-assistimos", "Já assistimos");
      vimos.type = "button";
      vimos.dataset.itemId = String(t.item.id);
      vimos.dataset.nome = t.titulo;
      corpo.appendChild(vimos);
    }

    if (t.item) {
      var tirar = el("button", "t-Button t-Button--danger mmm-Botao--largo js-mmm-tirar", "Tirar da lista");
      tirar.type = "button";
      tirar.dataset.itemId = String(t.item.id);
      tirar.dataset.nome = t.titulo;
      corpo.appendChild(tirar);
    }

    // carta Minha Vez: só na página 1 (o item com a URL da sessão só existe lá) e só para quem tem a carta
    if (t.item && t.minhaVez === true && document.getElementById("P1_URL_SESSAO")) {
      var vez = el("button", "t-Button t-Button--hot mmm-Botao--largo js-mmm-minha-vez", "Usar minha vez neste");
      vez.type = "button";
      vez.dataset.tituloId = String(t.id);
      corpo.appendChild(vez);
    }
  }

  mmm.ficha = {
    abrir: function (tituloId) {
      return mmm.chamar("MMM_FICHA", { x01: String(tituloId) }).then(function (r) {
        desenharFicha(r.titulo);
        mmm.abrirGaveta("mmm-ficha");
      }, mmm.erro);
    }
  };

  // a promessa do refresh do Template Component volta quando o modelo é limpo, antes da grade nova, e a região
  // não dispara o apexafterrefresh; o fim de verdade é o aviso addData do modelo (vem até com a lista vazia).
  // Com prazo, para uma falha de rede não segurar a fila
  function refrescar(id) {
    var r = apex.region(id);
    if (!r) { return Promise.resolve(); }
    var modelo = r.type === "TemplateComponent" ? apex.model.get(id) : null;
    if (!modelo) {
      return Promise.resolve(r.refresh()).catch(function () { return null; });
    }
    return new Promise(function (pronto) {
      var feito = false;
      var assinatura = null;
      var prazo = null;
      function fim() {
        if (feito) { return; }
        feito = true;
        window.clearTimeout(prazo);
        modelo.unSubscribe(assinatura);
        apex.model.release(id);
        pronto();
      }
      prazo = window.setTimeout(fim, 8000);
      assinatura = modelo.subscribe({ onChange: function (tipo) { if (tipo === "addData") { fim(); } } });
      r.refresh();
    });
  }

  // a lista mudou: a grade e as contagens da página (cartão do grupo e cabeçalho) voltam do servidor,
  // uma de cada vez, para não somar pedidos simultâneos na ATP
  function rodadaLista() {
    return ["lista", "mmm-grupo", "mmm-contagem"].reduce(function (fila, id) {
      return fila.then(function () { return refrescar(id); });
    }, Promise.resolve());
  }

  // duas rodadas ao mesmo tempo (dois Adicionar seguidos, Tirar e Desfazer) congelavam a página: o pedido que chega
  // com uma rodada andando vira uma rodada a mais no fim, e quem pediu espera também por ela
  var rodadaEmCurso = null;
  var outraRodada = false;
  function atualizarLista() {
    if (rodadaEmCurso) {
      outraRodada = true;
      return rodadaEmCurso;
    }
    rodadaEmCurso = rodadaLista().then(function seguir() {
      if (!outraRodada) { return null; }
      outraRodada = false;
      return rodadaLista().then(seguir);
    }).then(function () {
      rodadaEmCurso = null;
    });
    return rodadaEmCurso;
  }
  mmm.atualizarLista = atualizarLista;

  // depois do refresh o tema põe o foco no primeiro pôster; quem tirou um título continua no lugar dele
  // (no modo Editar, no X do pôster que veio para o lugar)
  function lugarNaGrade(itemId) {
    var x = document.querySelector('#lista .js-mmm-tirar[data-item-id="' + CSS.escape(String(itemId)) + '"]');
    var item = x && x.closest(".mmm-Grade-item");
    return item ? [].indexOf.call(item.parentNode.children, item) : -1;
  }

  function focarLugar(lugar) {
    var itens = document.querySelectorAll("#lista .mmm-Grade-item");
    if (lugar < 0 || !itens.length) { return; }
    var item = itens[Math.min(lugar, itens.length - 1)];
    var alvo = item.querySelector(document.querySelector("#lista.is-editando") ? ".js-mmm-tirar" : ".js-mmm-ficha");
    if (alvo) { alvo.focus(); }
  }

  function tirar(itemId, nome) {
    var lugar = lugarNaGrade(itemId);
    mmm.chamar("MMM_TIRAR", { x01: itemId }).then(function () {
      atualizarLista().then(function () { focarLugar(lugar); });
      mmm.anunciar(nome + " saiu da lista");
      mmm.toast(nome + " saiu da lista", {
        rotulo: "Desfazer",
        fn: function () {
          mmm.chamar("MMM_DEVOLVER", { x01: itemId }).then(function () {
            atualizarLista();
            mmm.toast(nome + " voltou para a lista");
          }, mmm.erro);
        }
      });
    }, mmm.erro);
  }

  var audio = null;
  var somLigado = false;
  try { somLigado = window.localStorage.getItem("mmm-som") === "1"; } catch (e) { somLigado = false; }
  // [frequência, início, duração, forma, volume]
  var NOTAS = {
    quero: [[660, 0, 0.12], [880, 0.07, 0.14]],
    nao: [[220, 0, 0.14, "triangle", 0.12]],
    super: [[784, 0, 0.1], [988, 0.07, 0.1], [1319, 0.14, 0.22]],
    veto: [[180, 0, 0.22, "sawtooth", 0.07]],
    vira: [[520, 0, 0.06, "square", 0.05]],
    tique: [[1200, 0, 0.03, "square", 0.04]],
    match: [[523, 0, 0.35], [659, 0.09, 0.35], [784, 0.18, 0.35], [1047, 0.27, 0.35]]
  };

  // efeito é opcional e só toca depois de um toque: o iPhone não libera áudio sem gesto
  mmm.som = function (tipo) {
    if (!somLigado || !NOTAS[tipo]) { return; }
    try {
      audio = audio || new (window.AudioContext || window.webkitAudioContext)();
      if (audio.state === "suspended") { audio.resume(); }
      var t0 = audio.currentTime;
      NOTAS[tipo].forEach(function (n) {
        var o = audio.createOscillator();
        var g = audio.createGain();
        var ini = t0 + n[1];
        var dur = n[2];
        o.type = n[3] || "sine";
        o.frequency.setValueAtTime(n[0], ini);
        g.gain.setValueAtTime(0, ini);
        g.gain.linearRampToValueAtTime(n[4] || 0.16, ini + 0.015);
        g.gain.exponentialRampToValueAtTime(0.0001, ini + dur);
        o.connect(g).connect(audio.destination);
        o.start(ini);
        o.stop(ini + dur + 0.05);
      });
    } catch (e) {
      /* sem áudio: segue em silêncio */
    }
  };

  mmm.vibrar = function (padrao) {
    try {
      if (navigator.vibrate) { navigator.vibrate(padrao); }
    } catch (e) {
      /* iPhone e iPad não vibram por código */
    }
  };

  function alternarSom() {
    somLigado = !somLigado;
    try { window.localStorage.setItem("mmm-som", somLigado ? "1" : "0"); } catch (e) { /* vale só nesta visita */ }
    document.querySelectorAll(".js-mmm-som").forEach(function (b) {
      b.setAttribute("aria-pressed", String(somLigado));
    });
    mmm.som("quero");
    mmm.toast(somLigado ? "Som ligado" : "Som desligado");
  }

  $(document)
    .off("click.mmm")
    .on("click.mmm", ".js-mmm-ficha", function () {
      mmm.ficha.abrir(this.dataset.tituloId);
    })
    .on("click.mmm", ".js-mmm-tirar", function () {
      if (window.history.state && window.history.state.mmmGaveta === "mmm-ficha") {
        mmm.fecharGaveta("mmm-ficha");
      }
      tirar(this.dataset.itemId, this.dataset.nome || "O título");
    })
    // a nota de quem marcou leva o título para os assistidos de hoje; os outros dão a nota na página 6
    .on("click.mmm", ".js-mmm-assistimos", function () {
      var b = this;
      var itemId = b.dataset.itemId;
      var nome = b.dataset.nome || "O título";
      if (!mmm.ingresso || !mmm.ingresso.painelNota || b.parentNode.querySelector(".mmm-NotaPainel")) { return; }
      // como no Tirar da lista: o foco volta ao lugar do título na grade, e não ao primeiro pôster
      var lugar = lugarNaGrade(itemId);
      var sair = function () {
        mmm.fecharGaveta("mmm-ficha");
        atualizarLista().then(function () { focarLugar(lugar); });
      };
      var painel = mmm.ingresso.painelNota({ id: "ficha-" + itemId }, sair, {
        aviso: "Vai para os assistidos de hoje e sai da lista. Os outros dão a nota deles em Assistidos.",
        enviar: function (n) { return mmm.chamar("MMM_INGRESSO", { x01: "MARCAR", x02: itemId, x03: n }); },
        texto: function () { return nome + " foi para os assistidos"; },
        // outra pessoa marcou antes: a ficha fecha e a lista volta sem o título (a nota vai pela página 6)
        falhou: function (e) { if (e && e.recusado && /já saiu da lista/.test(e.message || "")) { sair(); } }
      });
      b.parentNode.insertBefore(painel.no, b);
      b.remove();
      painel.focar();
    })
    .on("click.mmm", ".js-mmm-minha-vez", function () {
      var b = this;
      b.disabled = true;
      mmm.chamar("MMM_JOGO", { x01: "MINHA_VEZ", x03: b.dataset.tituloId }).then(function () {
        // a sessão já nasce encerrada: a página 30 mostra o ingresso
        window.location.href = $v("P1_URL_SESSAO");
      }, function (e) {
        b.disabled = false;
        mmm.erro(e);
      });
    })
    .on("click.mmm", ".js-mmm-explorar", function () {
      var d = this.dataset;
      var alvo = { tipo: d.tipo, id: d.id, nome: d.nome, fotoPath: d.foto || null, area: d.area || null };
      if (!mmm.explorar) { return; }
      // a ficha fecha antes: a entrada dela sai do histórico e o Voltar do Android passa a fechar a gaveta Adicionar
      if (window.history.state && window.history.state.mmmGaveta === "mmm-ficha") {
        var depois = function () {
          window.removeEventListener("popstate", depois);
          window.setTimeout(function () { mmm.explorar.abrir(alvo); }, 0);
        };
        window.addEventListener("popstate", depois);
        window.history.back();
      } else {
        apex.theme.closeRegion("mmm-ficha");
        mmm.explorar.abrir(alvo);
      }
    })
    .on("click.mmm", ".js-mmm-som", alternarSom)
    .on("click.mmm", ".js-mmm-avisos", function () {
      trocarAvisos(this, mmm.ativarAvisos, true);
    })
    .on("click.mmm", ".js-mmm-sair-todos", function () {
      // Perfil: a confirmação antes de sair de todos os aparelhos (o servidor esquece os aparelhos e encerra as sessões)
      apex.message.confirm("Você vai sair da sua conta neste aparelho e em todos os outros em que entrou, e nenhum deles abre mais sozinho na conta. Para voltar, entre de novo com o Google.", function (ok) {
        if (ok) { apex.submit({ request: "SAIR_TODOS" }); }
      }, { style: "warning", confirmLabel: "Sair de todos os aparelhos", cancelLabel: "Cancelar" });
    })
    .on("click.mmm", ".js-mmm-desligar-avisos", function () {
      trocarAvisos(this, mmm.desligarAvisos, false);
    })
    .on("click.mmm", ".js-mmm-compartilhar", function () {
      var url;
      try { url = new URL(this.dataset.url, window.location.href).href; } catch (e) { return; }
      if (!/^https:\/\//.test(url)) { return; }
      if (navigator.share) {
        navigator.share({ title: "Match My Movie", text: this.dataset.texto || "", url: url })
          .catch(function () { /* a pessoa fechou a folha de compartilhar */ });
        return;
      }
      if (navigator.clipboard) {
        navigator.clipboard.writeText(url).then(function () {
          mmm.toast("Link do convite copiado");
        }, function () {
          mmm.toast("Copie o link: " + url);
        });
        return;
      }
      mmm.toast("Copie o link: " + url);
    })
    // fechou a gaveta pelo X ou tocando fora: tira a entrada que o abrirGaveta pôs no histórico
    .on("dialogclose.mmm", ".mmm-Gaveta", function () {
      if (window.history.state && window.history.state.mmmGaveta === this.id) {
        window.history.back();
      }
    });

  function prepararToast() {
    var t = document.getElementById("mmm-toast");
    if (!t) { return; }
    // o tema recorta a posição Dialogs, Drawers and Popups (só gaveta e menu saem dela ao abrir):
    // o aviso vai para o fim da página para aparecer e receber o toque
    document.body.appendChild(t);
    // com o foco ou o dedo no aviso ele não some: dá tempo de chegar no Desfazer
    t.addEventListener("focusin", function () { window.clearTimeout(toastTimer); });
    t.addEventListener("pointerenter", function () { window.clearTimeout(toastTimer); });
    t.addEventListener("focusout", function () { agendarToast(Number(t.dataset.tempo || 2600)); });
    t.addEventListener("pointerleave", function () { agendarToast(Number(t.dataset.tempo || 2600)); });
  }

  // cartão Instalar da página 1 (só conta Google: visitante não recebe aviso). Aparece no iPhone e no iPad fora do app
  // instalado e onde o navegador oferece instalar (Android e Chrome no computador: o APEX guarda o beforeinstallprompt).
  // O Instalar abre a gaveta de instalação do APEX, com os passos da versão do iOS em uso (o Compartilhar fica no menu
  // da barra no Safari do iOS 26), ou a instalação do próprio navegador
  function prepararInstalar() {
    var card = document.getElementById("mmm-instalar");
    if (!card || !apex.pwa || !apex.pwa.openInstallDialog) { return; }
    var dispensado = false;
    try { dispensado = window.localStorage.getItem("mmm-instalar-dispensado") === "1"; } catch (e) { dispensado = false; }
    if (dispensado || mmm.instalado()) { return; }
    function mostrar(sim) { card.hidden = dispensado || !sim; }
    function conferir() {
      if (mmm.instalado()) { mostrar(false); return; }
      if (mmm.ehIos()) { mostrar(true); return; }
      apex.pwa.isInstallable().then(mostrar, function () { mostrar(false); });
    }
    conferir();
    window.addEventListener("beforeinstallprompt", conferir);
    window.addEventListener("appinstalled", function () { mostrar(false); });
    var instalar = card.querySelector(".js-mmm-instalar");
    if (instalar) {
      instalar.addEventListener("click", function () { apex.pwa.openInstallDialog(); });
    }
    var fechar = card.querySelector(".js-mmm-instalar-fechar");
    if (fechar) {
      fechar.addEventListener("click", function () {
        dispensado = true;
        card.hidden = true;
        try { window.localStorage.setItem("mmm-instalar-dispensado", "1"); } catch (e) { /* volta na próxima visita */ }
      });
    }
  }

  // chave da inscrição do navegador no mesmo formato de apex.pwa.publicKey (base64url sem padding)
  function chaveDaInscricao(inscricao) {
    var buf = inscricao.options && inscricao.options.applicationServerKey;
    if (!buf) { return null; }
    var bytes = new Uint8Array(buf);
    var s = "";
    for (var i = 0; i < bytes.length; i++) { s += String.fromCharCode(bytes[i]); }
    return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  }

  // em arquivo: a CSP barra função inline e link javascript:
  mmm.ativarAvisos = function () {
    // no iPhone só o app da Tela de Início pede permissão de push
    if (mmm.ehIos() && !mmm.instalado()) {
      mmm.toast("Adicione o Match My Movie à Tela de Início para receber avisos.");
      return Promise.resolve(false);
    }
    if (!("serviceWorker" in navigator) || !apex.pwa) {
      mmm.toast("Este aparelho não recebe avisos.");
      return Promise.resolve(false);
    }
    // com o endereço da página: sem ele o navegador resolve pelo <base href="/ords/"> do APEX, fora do escopo do sw.js,
    // e não acha o registro (a inscrição de chave antiga nunca seria descartada)
    return navigator.serviceWorker.getRegistration(window.location.href).then(function (reg) {
      return reg ? reg.pushManager.getSubscription() : null;
    }).then(function (atual) {
      var chave = atual ? chaveDaInscricao(atual) : null;
      // só descarta inscrição feita com outra chave VAPID; sem como comparar, mantém (derrubaria as outras contas)
      if (atual && chave && chave !== apex.pwa.publicKey) {
        var antiga = JSON.stringify(atual.toJSON());
        return atual.unsubscribe().catch(function () { return null; }).then(function () {
          return mmm.chamar("MMM_DESINSCREVER_PUSH", { x01: antiga }, true).catch(function () { return null; });
        });
      }
      return null;
    }).then(function () {
      return apex.pwa.subscribePushNotifications();
    }).then(function () {
      // o APEX resolve sem erro quando o push não é usável ou a permissão foi negada: só vale com a inscrição feita
      return apex.pwa.getPushSubscription();
    }).then(function (inscricao) {
      if (!inscricao) { throw new Error("sem inscrição"); }
      // o APEX acabou de registrar esta inscrição para a conta logada: a página 9 passa a mostrá-la como ligada
      return impressao(inscricao.endpoint).then(function (h) {
        if (h && lerInscritas().indexOf(h) < 0) { inscritas.push(h); }
      });
    }).then(function () {
      mmm.toast("Avisos ligados neste aparelho.");
      return true;
    }, function () {
      mmm.toast("Não foi possível ligar os avisos.");
      return false;
    });
  };

  // ---------- avisos deste aparelho (página 9) ----------
  // ligados = o navegador tem a inscrição feita com a chave VAPID de agora e ela está registrada para a conta logada. A
  // página traz em P9_AVISOS as impressões SHA-256 dos endereços das inscrições da conta: a mesma inscrição do navegador
  // pode estar registrada só para outra conta que entrou antes no mesmo aparelho, e aí o aviso desta não chegaria
  function inscricaoDoAparelho() {
    if (!("serviceWorker" in navigator) || !window.PushManager) { return Promise.resolve(null); }
    return navigator.serviceWorker.getRegistration(window.location.href).then(function (reg) {
      return reg ? reg.pushManager.getSubscription() : null;
    }).catch(function () { return null; });
  }

  function impressao(texto) {
    if (!texto || !window.crypto || !window.crypto.subtle || !window.TextEncoder) { return Promise.resolve(null); }
    return window.crypto.subtle.digest("SHA-256", new TextEncoder().encode(texto)).then(function (buf) {
      return [].map.call(new Uint8Array(buf), function (b) { return ("0" + b.toString(16)).slice(-2); }).join("");
    }, function () { return null; });
  }

  var inscritas = null;
  function lerInscritas() {
    if (!inscritas) {
      // a página 9 traz as impressões em P9_AVISOS; a página 1 (o balão Ative os avisos), em P1_AVISOS
      var item = document.getElementById("P9_AVISOS") ? "P9_AVISOS" : document.getElementById("P1_AVISOS") ? "P1_AVISOS" : null;
      try { inscritas = JSON.parse((item && $v(item)) || "[]") || []; } catch (e) { inscritas = []; }
    }
    return inscritas;
  }

  function estadoDosAvisos() {
    return inscricaoDoAparelho().then(function (inscricao) {
      if (!inscricao || !apex.pwa || chaveDaInscricao(inscricao) !== apex.pwa.publicKey) { return { ligado: false, inscricao: inscricao }; }
      return impressao(inscricao.endpoint).then(function (h) {
        return { ligado: !!h && lerInscritas().indexOf(h) >= 0, inscricao: inscricao, impressao: h };
      });
    });
  }

  // a região mostra um estado de cada vez (o texto e o botão dele, pelo mmm.css); o foco vai para o botão que aparece
  function mostrarAvisos(ligado, focar) {
    var regiao = document.getElementById("avisos");
    if (!regiao) { return; }
    regiao.setAttribute("data-avisos", ligado ? "ligado" : "desligado");
    var b = regiao.querySelector(ligado ? ".js-mmm-desligar-avisos" : ".js-mmm-avisos");
    if (focar && b) { b.focus(); }
  }

  // primeiro o servidor (só esta inscrição, só da conta logada): com a rede caída nada muda e dá para tentar de novo;
  // depois o navegador
  mmm.desligarAvisos = function () {
    return estadoDosAvisos().then(function (s) {
      if (!s.inscricao) { return null; }
      return mmm.chamar("MMM_DESINSCREVER_PUSH", { x01: JSON.stringify(s.inscricao.toJSON()) }, true).then(function () {
        inscritas = lerInscritas().filter(function (h) { return h !== s.impressao; });
        return s.inscricao.unsubscribe().catch(function () { return false; });
      });
    }).then(function () {
      mmm.toast("Avisos desligados neste aparelho.");
      return true;
    }, function (e) {
      mmm.toast(e && e.recusado ? e.message : "Não deu certo agora. Tente de novo.");
      return false;
    });
  };

  // um toque de cada vez: o Ativar pode esperar a permissão do aparelho e o registro no serviço de push
  function trocarAvisos(botao, fn, ligar) {
    if (botao.getAttribute("aria-disabled") === "true") { return; }
    botao.setAttribute("aria-disabled", "true");
    fn().then(function (ok) {
      botao.removeAttribute("aria-disabled");
      if (ok) { mostrarAvisos(ligar, true); }
    });
  }

  function prepararAvisos() {
    if (!document.getElementById("avisos") || !document.querySelector(".js-mmm-desligar-avisos")) { return; }
    estadoDosAvisos().then(function (s) { mostrarAvisos(s.ligado, false); });
  }

  // balão "Ative os avisos" da página 1, um balão por vez: o Instalar primeiro. Aparece depois de instalar (o app aberto
  // pela Tela de Início, ou o appinstalled nesta página no Android e no Chrome do computador), só para conta Google com o
  // push ligado no app (a região só existe para ela), com o aparelho sem a inscrição desta conta (a mesma conferência da
  // página 9) e sem a permissão negada; no iPhone, só dentro do app instalado. O Agora não fica guardado no aparelho
  function prepararBalaoAvisos() {
    var balao = document.getElementById("mmm-avisos");
    if (!balao || !apex.pwa) { return; }
    var instalar = document.getElementById("mmm-instalar");
    var dispensado = false;
    try { dispensado = window.localStorage.getItem("mmm-avisos-dispensado") === "1"; } catch (e) { dispensado = false; }
    var instaladoAgora = false;
    function podeMostrar() {
      return !dispensado && "serviceWorker" in navigator && !!window.PushManager && !!window.Notification &&
        window.Notification.permission !== "denied" && (mmm.instalado() || (instaladoAgora && !mmm.ehIos())) &&
        !(instalar && !instalar.hidden);
    }
    function conferir() {
      if (!podeMostrar()) { balao.hidden = true; return; }
      estadoDosAvisos().then(function (s) { balao.hidden = s.ligado || !podeMostrar(); });
    }
    // o cartão Instalar esconde a si mesmo no mesmo evento; o balão confere depois dele
    window.addEventListener("appinstalled", function () {
      instaladoAgora = true;
      window.setTimeout(conferir, 0);
    });
    var ativar = balao.querySelector(".js-mmm-balao-ativar");
    if (ativar) {
      ativar.addEventListener("click", function () {
        if (ativar.getAttribute("aria-disabled") === "true") { return; }
        ativar.setAttribute("aria-disabled", "true");
        mmm.ativarAvisos().then(function (ok) {
          ativar.removeAttribute("aria-disabled");
          // ligado, o aviso do app diz "Avisos ligados neste aparelho."; negado na pergunta do aparelho, o balão sai
          if (ok || (window.Notification && window.Notification.permission === "denied")) { balao.hidden = true; }
        });
      });
    }
    var fechar = balao.querySelector(".js-mmm-balao-fechar");
    if (fechar) {
      fechar.addEventListener("click", function () {
        dispensado = true;
        balao.hidden = true;
        try { window.localStorage.setItem("mmm-avisos-dispensado", "1"); } catch (e) { /* volta na próxima visita */ }
      });
    }
    conferir();
  }

  // caixa "Manter conectado neste aparelho" da entrada (9999): a escolha atravessa a ida e a volta do Google num cookie
  // curto de pedido, que a Post-Authentication lê e apaga (MMM_PKG_LEMBRAR.preparar); o endereço do login não ganha item.
  // O pedido não leva segredo nenhum (1 ou 0), por isso o JavaScript o grava. A última escolha fica no aparelho; na
  // primeira vez a caixa vem desmarcada
  function prepararManterConectado() {
    var caixa = document.getElementById("mmm-manter");
    if (!caixa) { return; }
    try { caixa.checked = window.localStorage.getItem("mmm-manter-conectado") === "1"; } catch (e) { caixa.checked = false; }
    caixa.addEventListener("change", function () {
      try { window.localStorage.setItem("mmm-manter-conectado", caixa.checked ? "1" : "0"); } catch (e) { /* vale só nesta visita */ }
    });
    var google = document.querySelector(".mmm-Entrada-acoes .mmm-Google");
    if (!google) { return; }
    google.addEventListener("click", function () {
      // o nome segue o do cookie da sessão do esquema: LEMBRAR_PEDIDO_MMM no http, __Host-LEMBRAR_PEDIDO_MMM no https
      var https = window.location.protocol === "https:";
      document.cookie = (https ? "__Host-" : "") + "LEMBRAR_PEDIDO_MMM=" + (caixa.checked ? "1" : "0") +
        "; Max-Age=600; Path=/; SameSite=Lax" + (https ? "; Secure" : "");
    });
  }

  // Sair (o do menu da conta e os do Perfil): os dois passam pelo apex.navigation.redirect com o request SAIR. Antes de
  // ir, a confirmação (o Sair também faz o aparelho esquecer a conta) e a conferência da sessão desta tela: numa aba velha,
  // de uma sessão que já acabou, o link de saída cairia na tela de erro do APEX (o checksum é da sessão dela), e o certo é
  // só ir à entrada, que leva à sessão que vale agora. Só a ação da pessoa nesses Sair (toque, clique ou tecla) pede
  // confirmação: o desvio que o APEX faz depois de um envio também passa pelo redirect com SAIR (o Sair de todos, a conta
  // excluída e o Sair da 9998 e da 9999, que já são uma escolha) e segue direto
  function prepararSaida() {
    var redirecionar = apex.navigation.redirect;
    var SAIR = /[?&]request=SAIR(?:&|$)/;
    var pedidoEm = 0;
    var entrada = function () { return new URL("entrar", window.location.href).href; };
    function ehSair(alvo) {
      if (!alvo || !alvo.closest) { return false; }
      var item = alvo.closest(".a-Menu-item");
      if (item) {
        var a = item.querySelector("a[href]");
        return !!a && SAIR.test(a.getAttribute("href"));
      }
      return String(apex.env.APP_PAGE_ID) === "9" && !!alvo.closest('button[data-otel-label="SAIR"], button[data-otel-label="SAIR_DEMO"]');
    }
    // a marca nasce no gesto da pessoa sobre o Sair: o menu do APEX age no soltar do ponteiro, o botão do Perfil no click, o
    // teclado no keydown seguido do click, e o leitor de tela chega por um click
    function marcar(e) {
      if (ehSair(e.target)) { pedidoEm = Date.now(); }
    }
    ["pointerdown", "pointerup", "click"].forEach(function (tipo) {
      document.addEventListener(tipo, marcar, true);
    });
    document.addEventListener("keydown", function (e) {
      if (e.key === "Enter" || e.key === " ") { marcar(e); }
    }, true);
    apex.navigation.redirect = function (url) {
      if (typeof url !== "string" || !SAIR.test(url) || Date.now() - pedidoEm > 1500) { return redirecionar.apply(this, arguments); }
      pedidoEm = 0;
      var demo = /^VISITANTE-/.test(apex.env.APP_USER || "");
      apex.message.confirm(demo ? "Sair da demonstração? A visita acaba aqui." :
        "Sair da conta neste aparelho? Ele deixa de entrar sozinho na sua conta.", function (ok) {
        if (!ok) { return; }
        apex.server.process("MMM_VIVA", {}, { dataType: "json", error: function () { return null; } }).then(function (r) {
          redirecionar.call(apex.navigation, r && r.ok === true ? url : entrada());
        }, function () {
          redirecionar.call(apex.navigation, entrada());
        });
      }, { style: "warning", confirmLabel: demo ? "Sair da demonstração" : "Sair", cancelLabel: "Cancelar" });
    };
  }

  $(function () {
    prepararSaida();
    apex.actions.add([{
      name: "mmm-som",
      label: "Som dos efeitos",
      action: alternarSom
    }]);
    document.querySelectorAll(".js-mmm-som").forEach(function (b) {
      b.setAttribute("aria-pressed", String(somLigado));
    });
    // a mensagem de sucesso do APEX some sozinha, como o aviso do app (para com o mouse em cima, o foco no fechar ou um
    // toque nela); a de erro fica até a pessoa fechar
    apex.message.setDismissPreferences({ dismissPageSuccess: true, dismissPageSuccessDuration: 5000 });
    // o menu da conta mostra em amarelo a página em que a pessoa está (mmm.css); o menu do APEX não marca o item atual
    document.body.setAttribute("data-mmm-pagina", String(apex.env.APP_PAGE_ID));
    prepararToast();
    prepararInstalar();
    prepararAvisos();
    prepararBalaoAvisos();
    prepararManterConectado();
  });
})(apex, apex.jQuery);
