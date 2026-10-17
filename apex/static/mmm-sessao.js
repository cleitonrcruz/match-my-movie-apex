// Match My Movie: página 30, a sessão (#APP_FILES#mmm-sessao.js?v=N nas File URLs, depois do mmm-jogo.js).
// Baralho com arraste, verso, espera, revelação, duelos, roleta em
// canvas, ingresso, confete e placar, mais o relógio de cada carta, o cronômetro da espera e o tempo de cada um na
// revelação. Quem decide é o servidor: a tela desenha o estado que chega pelo evento
// mmmestado do mmm-jogo.js e as cartas (CARTAS, uma vez), e as jogadas vão pela fila do motor (mmm.jogo.jogar).
// Texto de quem usa o app e do TMDB entra sempre por textContent; estilo só por classe (e o CSSOM no arraste e na barra).
// APEX_JSON omite a chave com valor nulo: chave ausente vale nulo ou falso (testar com === true ou !valor).
apex.jQuery(function () {
  "use strict";

  var mmm = window.mmm;
  var raiz = document.getElementById("mmm-jogo");
  var mesa = document.getElementById("mmm-mesa");
  if (!mmm || !mmm.jogo || !mmm.jogo.jogar || !raiz || !mesa) { return; }

  var el = mmm.el;
  var SVG = "http://www.w3.org/2000/svg";
  var CDN = "https://image.tmdb.org/t/p/";
  var CAMINHO_TMDB = /^\/[A-Za-z0-9_-]+\.(jpg|jpeg|png|svg)$/;
  var SESSAO = raiz.getAttribute("data-sessao");
  var DEMO = raiz.getAttribute("data-demo") === "S";
  var GRUPO = raiz.getAttribute("data-grupo") || "";
  var URL_INICIO = raiz.getAttribute("data-inicio") || "";
  var URL_ABERTURA = raiz.getAttribute("data-abertura") || "";
  var reduz = window.matchMedia("(prefers-reduced-motion: reduce)");
  var VOTOS = ["QUERO", "NAO", "SUPER", "VETO"];
  var ROTULO_VOTO = { QUERO: "quer", SUPER: "super", NAO: "não quer", VETO: "vetou" };
  var ICONE_VOTO = { QUERO: "check", SUPER: "estrela", NAO: "x", VETO: "veto" };

  var cartas = null;           // CARTAS por ordem
  var porId = {};
  var porTitulo = {};
  var estado = null;           // último estado do servidor
  var pessoas = {};            // presenças por id
  var tela = null;             // tela desenhada agora
  var travada = false;         // animação em curso (resultado de duelo, giro): o estado novo espera o fim dela
  var deck = { iniciado: false, posicao: 0, poder: { SUPER: 1, VETO: 1 }, meus: {}, animando: false, virada: false };
  var revelada = null;         // sessão cuja revelação já foi animada
  var dueloNaTela = null;      // id do duelo desenhado
  var ultimoMostrado;          // id do último duelo decidido que a tela já mostrou (undefined: ainda não olhou)
  var roleta = null;
  var ingresso = null;         // sessão cujo ingresso já foi montado
  var cutucadaAte = 0;
  var estadoNaFila = false;    // estado que chegou durante a saída de uma carta
  var estadoEm = Date.now();   // quando chegou o último estado (o segSemSinal dele é dessa hora)
  var arrasto = null;          // carta que o dedo (ou o mouse) está arrastando agora, com o ponteiro

  // relógio da carta do topo (só no baralho): segundos por carta da sessão (0 = sem relógio), a carta que está correndo,
  // o último passo, o que cada carta ainda tem (r: ms que faltam, p: ms da pausa da sinopse, z: zerou) e o aviso para o
  // anúncio da carta seguinte
  var PAUSA_SINOPSE = 10000;   // a sinopse aberta segura o relógio por até 10 s em cada carta, somando as aberturas
  var URGENTE = 5000;          // os últimos segundos: a cor muda e o leitor de tela ouve o aviso
  var CHAVE_RELOGIO = "mmm-relogio-" + SESSAO;
  var relogio = { seg: 0, id: null, t: 0, cartas: {}, timer: null, salvoEm: 0, escondido: false, saindo: false, aviso: null, volta: null };

  /* ---------- peças ---------- */
  function icone(nome, classe) {
    var s = document.createElementNS(SVG, "svg");
    s.setAttribute("class", classe || "mmm-Icone");
    s.setAttribute("aria-hidden", "true");
    s.setAttribute("focusable", "false");
    var u = document.createElementNS(SVG, "use");
    u.setAttribute("href", "#i-" + nome);
    s.appendChild(u);
    return s;
  }

  function filhos(n, lista) {
    (lista || []).forEach(function (f) {
      if (f === null || f === undefined || f === false) { return; }
      n.appendChild(typeof f === "string" ? document.createTextNode(f) : f);
    });
    return n;
  }

  function botao(classe, conteudo, acao) {
    var b = filhos(el("button", classe), conteudo);
    b.type = "button";
    if (acao) { b.dataset.acao = acao; }
    return b;
  }

  function link(classe, href, conteudo) {
    var a = filhos(el("a", classe), conteudo);
    a.href = href;
    return a;
  }

  function titulo1(texto, sr) {
    var h = el("h1", sr ? "mmm-Sr" : "mmm-Tela-titulo", texto);
    h.tabIndex = -1;
    return h;
  }

  function img(caminho, larguras, sizes, alt) {
    if (!CAMINHO_TMDB.test(caminho || "")) { return null; }
    var i = document.createElement("img");
    i.alt = alt || "";
    i.decoding = "async";
    i.src = CDN + larguras[Math.min(1, larguras.length - 1)] + caminho;
    i.srcset = larguras.map(function (w) { return CDN + w + caminho + " " + w.slice(1) + "w"; }).join(", ");
    i.sizes = sizes;
    return i;
  }

  // pôster ou, sem caminho válido, o quadro com o nome
  function poster(c, larguras, sizes, alt, classe) {
    var i = c ? img(c.poster, larguras, sizes, alt) : null;
    if (i) {
      if (classe) { i.className = classe; }
      return i;
    }
    var v = el("span", "mmm-SemCapa" + (classe ? " " + classe : ""), c ? c.nome : "");
    if (alt) {
      v.setAttribute("role", "img");
      v.setAttribute("aria-label", alt);
    }
    return v;
  }

  function avatar(p, pequeno) {
    return mmm.avatar(p ? p.apelido : "?", p ? p.cor : 1, pequeno);
  }

  function nomes(lista) {
    if (lista.length <= 1) { return lista.join(""); }
    return lista.slice(0, -1).join(", ") + " e " + lista[lista.length - 1];
  }

  function duracao(c) {
    if (c.tipo === "SERIE") {
      var t = c.temporadas ? c.temporadas + (c.temporadas === 1 ? " temporada" : " temporadas") : "série";
      return c.duracao ? t + " · ep. " + c.duracao + " min" : t;
    }
    if (!c.duracao) { return ""; }
    return Math.floor(c.duracao / 60) + "h" + String(c.duracao % 60).padStart(2, "0");
  }

  function linhaMeta(c) {
    var m = el("div", "mmm-LinhaMeta");
    var ci = mmm.classificacao(c.cls);
    if (ci) { m.appendChild(ci); }
    [c.ano, duracao(c)].forEach(function (v) { if (v) { m.appendChild(el("span", "mmm-LinhaMeta-item", String(v))); } });
    return m;
  }

  /* ---------- hora no fuso de Brasília (o servidor conta o ingresso nesse fuso) ---------- */
  var RELOGIO = new Intl.DateTimeFormat("pt-BR", { timeZone: "America/Sao_Paulo", hour: "2-digit", minute: "2-digit", hourCycle: "h23" });
  function partes(data) {
    var p = {};
    RELOGIO.formatToParts(data).forEach(function (x) { p[x.type] = x.value; });
    return Number(p.hour) * 60 + Number(p.minute);
  }
  function hhmm(min) {
    var m = ((min % 1440) + 1440) % 1440;
    return String(Math.floor(m / 60)).padStart(2, "0") + "h" + String(m % 60).padStart(2, "0");
  }
  function inicioPrevisto() {
    var agora = partes(new Date());
    var h = Math.floor(agora / 60) * 60;
    return h + Math.ceil((agora - h + 5) / 5) * 5;
  }
  function horaIso(iso) {
    var d = iso ? new Date(iso) : null;
    return d && !isNaN(d.getTime()) ? hhmm(partes(d)) : null;
  }

  /* ---------- anúncio para leitor de tela (região fixa: criada uma vez, fora da mesa) ---------- */
  var falar = el("div", "mmm-Sr");
  falar.id = "mmm-jogo-anuncio";
  falar.setAttribute("aria-live", "polite");
  falar.setAttribute("aria-atomic", "true");
  raiz.appendChild(falar);
  function anunciar(texto) {
    falar.textContent = "";
    window.setTimeout(function () { falar.textContent = texto; }, 40);
  }
  // o relógio fala só nos últimos segundos, numa região dele (o anúncio da carta seguinte não o corta)
  var falarRelogio = el("div", "mmm-Sr");
  falarRelogio.id = "mmm-relogio-anuncio";
  falarRelogio.setAttribute("aria-live", "polite");
  falarRelogio.setAttribute("aria-atomic", "true");
  raiz.appendChild(falarRelogio);

  /* ---------- tempo em texto: 0:52 na tela, "52 segundos" para o leitor de tela ---------- */
  function tempoTexto(seg) {
    var s = Math.max(0, Math.round(Number(seg) || 0));
    var h = Math.floor(s / 3600);
    var m = Math.floor((s % 3600) / 60);
    var r = String(s % 60).padStart(2, "0");
    return h ? h + ":" + String(m).padStart(2, "0") + ":" + r : m + ":" + r;
  }
  function tempoFalado(seg) {
    var s = Math.max(0, Math.round(Number(seg) || 0));
    var partes = [];
    var h = Math.floor(s / 3600);
    var m = Math.floor((s % 3600) / 60);
    if (h) { partes.push(h + (h === 1 ? " hora" : " horas")); }
    if (m) { partes.push(m + (m === 1 ? " minuto" : " minutos")); }
    if (s % 60 || !partes.length) { partes.push(s % 60 + (s % 60 === 1 ? " segundo" : " segundos")); }
    return partes.join(" e ");
  }
  // o tempo na tela (escondido do leitor) e o mesmo tempo falado
  function tempoDuplo(classe, seg) {
    var t = el("span", classe);
    var v = el("span", null, tempoTexto(seg));
    v.setAttribute("aria-hidden", "true");
    t.appendChild(v);
    t.appendChild(el("span", "mmm-Sr", tempoFalado(seg)));
    return t;
  }

  /* ---------- troca de tela: o foco vai para o título novo ---------- */
  // nova: a mesma tela com outra pergunta (o duelo seguinte), que leva o foco ao título como uma tela nova
  function mostrar(nome, secao, nova) {
    var mudou = tela !== nome;
    var foco = document.activeElement && mesa.contains(document.activeElement) ? document.activeElement.dataset.foco : null;
    if (nome !== "roleta") { pararRoleta(); }
    if (nome !== "baralho") { pararRelogio(); }
    tela = nome;
    mesa.textContent = "";
    mesa.appendChild(secao);
    raiz.dataset.tela = nome;
    if (mudou || nova) {
      if (mudou) { window.scrollTo(0, 0); }
      var h = secao.querySelector("h1");
      if (h) { h.focus({ preventScroll: true }); }
    } else if (foco) {
      // o redesenho da mesma tela não tira o foco de quem estava num botão
      var alvo = secao.querySelector('[data-foco="' + foco + '"]');
      if (alvo) { alvo.focus({ preventScroll: true }); }
    }
    return mudou;
  }

  function secao(classe) {
    return el("section", "mmm-Tela " + classe);
  }

  /* ---------- dados ---------- */
  function guardarCartas(lista) {
    cartas = (lista || []).slice();
    porId = {};
    porTitulo = {};
    cartas.forEach(function (c) {
      porId[c.id] = c;
      porTitulo[c.titulo] = c;
    });
  }

  // a ordem do baralho é a do servidor (o estado traz cartas[] por ORDEM)
  function ordem() {
    return ((estado && estado.cartas) || []).map(function (c) { return porId[c.id]; }).filter(Boolean);
  }

  function situacao() { return (estado && estado.eu && estado.eu.situacao) || "ESPECTADOR"; }
  function estou() { var s = situacao(); return s !== "SAIU" && s !== "ESPECTADOR"; }
  function humanosNoSofa() {
    return (estado.presencas || []).filter(function (p) { return p.robo !== true && p.situacao !== "SAIU"; });
  }

  // votei a última carta e o servidor ainda não respondeu: na tela eu já estou pronto
  function prontoAqui(p) {
    return p.id === estado.eu.id && estado.status === "VOTANDO" && (p.situacao === "VOTANDO" || p.situacao === "CONVIDADO") &&
      deck.iniciado && deck.posicao >= ordem().length;
  }

  // quem ainda deve voto agora (para o cutucar e o tirar do sofá)
  function devendo() {
    var r = estado;
    if (r.status === "VOTANDO") {
      return (r.presencas || []).filter(function (p) { return (p.situacao === "CONVIDADO" || p.situacao === "VOTANDO") && !prontoAqui(p); });
    }
    var atual = r.status === "FINAL" && r.duelos && r.duelos.atual;
    if (atual) {
      var ja = atual.jaVotaram || [];
      return (r.presencas || []).filter(function (p) { return p.situacao === "PRONTO" && ja.indexOf(p.id) < 0; });
    }
    return [];
  }

  /* ---------- baralho: o que a tela mostra vem à frente do servidor enquanto há jogada na fila ---------- */
  function sincronizarBaralho() {
    var pend = mmm.jogo.pendentes ? mmm.jogo.pendentes() : [];
    if (deck.iniciado && pend.length) { return false; }
    var pos = Number(estado.eu.votadas) || 0;
    var poder = { SUPER: Number(estado.eu.super) || 0, VETO: Number(estado.eu.veto) || 0 };
    pend.forEach(function (j) {
      if (j.a === "VOTAR") {
        pos++;
        if (poder[j.x4] !== undefined) { poder[j.x4]--; }
      } else if (j.a === "DESFAZER") {
        pos--;
      }
    });
    var total = ordem().length;
    pos = Math.max(0, Math.min(pos, total));
    var mudou = !deck.iniciado || pos !== deck.posicao;
    deck.iniciado = true;
    deck.posicao = pos;
    deck.poder = { SUPER: Math.max(0, poder.SUPER), VETO: Math.max(0, poder.VETO) };
    return mudou;
  }

  function cartaDoTopo() { return mesa.querySelector('.mmm-Carta[data-pos="0"]'); }

  function terminaTexto(c) {
    var ini = inicioPrevisto();
    if (c.tipo === "FILME") { return c.duracao ? "termina às " + hhmm(ini + c.duracao) : null; }
    var n = Number(estado.episodios) || 0;
    if (!n) { return c.duracao ? "episódios de ~" + c.duracao + " min" : null; }
    var rot = n === 1 ? "1 episódio" : n + " episódios";
    return c.duracao ? rot + ", termina às " + hhmm(ini + n * c.duracao) : rot;
  }

  function logos(c) {
    var caixa = el("div", "mmm-Carta-logos");
    var hoje = estado.servicosSessao || [];
    var assin = (c.servicos || []).filter(function (s) { return s.categoria === "ASSINATURA"; });
    // os serviços escolhidos para hoje vêm primeiro
    assin.sort(function (a, b) { return (hoje.indexOf(a.codigo) < 0) - (hoje.indexOf(b.codigo) < 0); });
    assin.slice(0, 4).forEach(function (s) {
      var i = img(s.logo, ["w45", "w92"], "26px", s.nome);
      if (i) {
        i.title = s.nome;
        caixa.appendChild(i);
      } else {
        caixa.appendChild(el("span", "mmm-Carta-servico", s.nome));
      }
    });
    if (assin.length > 4) { caixa.appendChild(el("span", "mmm-Carta-mais", "+" + (assin.length - 4))); }
    if (!assin.length && (c.servicos || []).length) { caixa.appendChild(el("span", "mmm-Carta-mais", "só aluguel")); }
    return caixa;
  }

  function verso(c) {
    var v = el("div", "mmm-Carta-face mmm-Carta-verso");
    v.appendChild(el("h2", "mmm-Carta-versoTitulo", c.nome));
    v.appendChild(linhaMeta(c));
    if (c.sinopse) {
      var p = el("p", "mmm-Carta-sinopse", c.sinopse);
      if (c.sinopseIdioma && c.sinopseIdioma !== "pt-BR") { p.lang = c.sinopseIdioma; }
      v.appendChild(p);
    } else {
      v.appendChild(el("p", "mmm-Carta-sinopse is-vazia", "O TMDB ainda não tem sinopse deste título."));
    }
    if (c.sugeriu) {
      var s = el("div", "mmm-Sugestao");
      s.appendChild(mmm.avatar(c.sugeriu, c.cor));
      var t = el("div", "mmm-Sugestao-texto");
      t.appendChild(el("b", null, c.sugeriu));
      t.appendChild(document.createTextNode(" sugeriu "));
      t.appendChild(mmm.pipocas(c.pipocas));
      s.appendChild(t);
      v.appendChild(s);
    }
    if (/^[A-Za-z0-9_-]{6,20}$/.test(c.trailer || "")) {
      var a = mmm.linkExterno("mmm-JogoBotao mmm-Carta-trailer", "https://www.youtube.com/watch?v=" + c.trailer, "Ver o trailer");
      a.insertBefore(icone("play"), a.firstChild);
      v.appendChild(a);
    }
    return v;
  }

  function botaoVirar(c) {
    var vira = botao("mmm-Carta-virar", [icone("info")], "virar");
    vira.dataset.foco = "virar";
    vira.setAttribute("aria-label", "Ver a sinopse de " + c.nome);
    vira.setAttribute("aria-pressed", "false");
    return vira;
  }

  // o lugar da carta na pilha e o que só a do topo tem (o nome acessível e o botão da sinopse); a carta que desce (o
  // Desfazer) volta desvirada e sem o resto de um arraste
  function posicionar(carta, c, pos, n, total) {
    carta.dataset.pos = String(pos);
    carta.style.transition = "";
    carta.style.transform = "";
    carta.style.opacity = "";
    if (carta.classList.contains("is-virada")) {
      carta.classList.remove("is-virada");
      carta.querySelector(".mmm-Carta-frente").inert = false;
      carta.querySelector(".mmm-Carta-verso").inert = true;
    }
    var vira = carta.querySelector(".mmm-Carta-virar");
    if (pos) {
      carta.setAttribute("aria-hidden", "true");
      carta.removeAttribute("aria-label");
      if (vira) { vira.remove(); }
      return;
    }
    carta.removeAttribute("aria-hidden");
    carta.setAttribute("aria-label", c.nome + ", carta " + (n + 1) + " de " + total);
    if (!vira) { carta.appendChild(botaoVirar(c)); }
  }

  function htmlCarta(c, pos, n, total) {
    var carta = el("div", "mmm-Carta");
    carta.dataset.id = String(c.id);
    var gira = el("div", "mmm-Carta-gira");
    var face = el("div", "mmm-Carta-face mmm-Carta-frente");
    face.appendChild(poster(c, ["w342", "w500", "w780"], "(min-width: 900px) 440px, 92vw", "", "mmm-Carta-poster"));
    [["quero", "QUERO"], ["nao", "NÃO"], ["super", "SUPER"], ["veto", "VETO"]].forEach(function (k) {
      var s = el("span", "mmm-Carimbo mmm-Carimbo--" + k[0], k[1]);
      s.setAttribute("aria-hidden", "true");
      face.appendChild(s);
    });
    var info = el("div", "mmm-Carta-info");
    info.appendChild(el("div", "mmm-Carta-titulo", c.nome));
    info.appendChild(linhaMeta(c));
    var fim = terminaTexto(c);
    if (fim) { info.appendChild(el("div", "mmm-Carta-termina", fim)); }
    info.appendChild(logos(c));
    face.appendChild(info);
    gira.appendChild(face);
    var v = verso(c);
    v.inert = true;
    gira.appendChild(v);
    carta.appendChild(gira);
    posicionar(carta, c, pos, n, total);
    return carta;
  }

  function virar(carta, calado) {
    if (!carta) { return; }
    consumirRelogio();
    var virada = carta.classList.toggle("is-virada");
    deck.virada = virada;
    var c = porId[carta.dataset.id];
    carta.querySelector(".mmm-Carta-frente").inert = virada;
    carta.querySelector(".mmm-Carta-verso").inert = !virada;
    var b = carta.querySelector(".mmm-Carta-virar");
    if (b && c) {
      b.setAttribute("aria-pressed", String(virada));
      b.setAttribute("aria-label", (virada ? "Ver o pôster de " : "Ver a sinopse de ") + c.nome);
    }
    if (!calado) { mmm.som("vira"); }
    desenharRelogio();
  }

  function desenharPilha(secaoBaralho) {
    var lista = ordem();
    var total = lista.length;
    var pilha = secaoBaralho.querySelector(".mmm-Pilha");
    var vistas = lista.slice(deck.posicao, deck.posicao + 3);
    // as cartas que continuam entre as três de cima ficam no DOM (o pôster já decodificado e a subida que o votar começou
    // no CSS); a que saiu e as que não estão mais entre elas saem
    var ficam = {};
    Array.prototype.slice.call(pilha.querySelectorAll(".mmm-Carta")).forEach(function (k) {
      var segue = !k.dataset.saiu && !ficam[k.dataset.id] && vistas.some(function (c) { return String(c.id) === k.dataset.id; });
      if (segue) { ficam[k.dataset.id] = k; } else { k.remove(); }
    });
    delete pilha.dataset.anda;
    // no DOM a de baixo vem antes e a do topo por último (a da frente é desenhada por cima); a que já está no lugar não se
    // move, para a transição não recomeçar
    var anterior = null;
    vistas.slice().reverse().forEach(function (c) {
      var pos = vistas.indexOf(c);
      var k = ficam[String(c.id)];
      var nova = !k;
      if (k) {
        posicionar(k, c, pos, deck.posicao, total);
      } else {
        k = htmlCarta(c, pos, deck.posicao, total);
      }
      var lugar = anterior ? anterior.nextSibling : pilha.firstChild;
      if (k !== lugar) { pilha.insertBefore(k, lugar); }
      // a que entra por baixo da pilha aparece aos poucos, do fundo
      if (nova && pos === 2 && Object.keys(ficam).length && !reduz.matches) {
        k.dataset.pos = "3";
        void k.offsetWidth;
        k.dataset.pos = "2";
      }
      anterior = k;
    });
    deck.virada = false;
    var barra = secaoBaralho.querySelector(".mmm-Progresso i");
    barra.style.width = (total ? (deck.posicao / total) * 100 : 0) + "%";
    secaoBaralho.querySelector(".mmm-Progresso-num").textContent = Math.min(deck.posicao + 1, total) + "/" + total;
    atualizarPoderes(secaoBaralho);
    var desf = secaoBaralho.querySelector('[data-acao="desfazer"]');
    // a carta que zerou fica como Não: o Desfazer aparece parado e o toque explica
    var anterior = deck.posicao > 0 ? lista[deck.posicao - 1] : null;
    var zerou = !!anterior && relogioZerou(anterior.id);
    var semVoto = deck.posicao === 0 || zerou;
    desf.setAttribute("aria-disabled", String(semVoto));
    desf.classList.toggle("is-disabled", semVoto);
    desf.setAttribute("aria-label", zerou ? "Desfazer o último voto (o tempo daquela carta acabou)" : "Desfazer o último voto");
    var topo = pilha.querySelector('.mmm-Carta[data-pos="0"]');
    if (topo) {
      // a carta que subiu de posição ganha o arraste uma vez só
      if (!topo.dataset.arrasto) {
        topo.dataset.arrasto = "1";
        prepararArrasto(topo);
      }
      var c = porId[topo.dataset.id];
      anunciar((relogio.aviso ? relogio.aviso + " " : "") + c.nome + ". Carta " + (deck.posicao + 1) + " de " + total + ".");
      relogio.aviso = null;
      relogioNaCarta(c.id);
    } else {
      pararRelogio();
    }
  }

  function atualizarPoderes(s) {
    ["SUPER", "VETO"].forEach(function (k) {
      var n = deck.poder[k];
      var b = s.querySelector('[data-voto="' + k + '"]');
      if (b) {
        b.querySelector(".mmm-Acao-ficha").textContent = String(n);
        b.setAttribute("aria-disabled", String(!n));
        b.classList.toggle("is-disabled", !n);
        b.setAttribute("aria-label", (k === "SUPER" ? "Super" : "Veto") + ", " + (n ? "1 restante" : "já usado"));
      }
      var l = s.querySelector('[data-poder="' + k + '"]');
      if (l) { l.textContent = String(n); }
    });
  }

  function lateral() {
    var a = el("aside", "mmm-Lateral");
    a.setAttribute("aria-label", "Sessão");
    var sofa = el("div", "mmm-Painel");
    sofa.appendChild(el("h2", null, "No sofá"));
    var lista = el("ul", "mmm-Painel-lista");
    (estado.presencas || []).forEach(function (p) {
      var li = el("li", "mmm-Painel-linha");
      li.appendChild(avatar(p));
      li.appendChild(el("span", null, p.apelido));
      var sit = p.id === estado.eu.id ? "votando" : p.situacao === "PRONTO" ? "pronto" : p.situacao === "SAIU" ? "saiu"
        : p.situacao === "CONVIDADO" ? "ainda não abriu" : "votando escondido";
      li.appendChild(el("small", null, sit));
      lista.appendChild(li);
    });
    sofa.appendChild(lista);
    a.appendChild(sofa);
    var poderes = el("div", "mmm-Painel");
    poderes.appendChild(el("h2", null, "Seus poderes"));
    [["SUPER", "estrela", "Super: garante vaga na final"], ["VETO", "veto", "Veto: tira um título do jogo"]].forEach(function (x) {
      var l = el("div", "mmm-Painel-linha mmm-Painel-linha--" + x[0].toLowerCase());
      l.appendChild(icone(x[1]));
      l.appendChild(el("span", null, x[2]));
      var n = el("small", null, String(deck.poder[x[0]]));
      n.dataset.poder = x[0];
      l.appendChild(n);
      poderes.appendChild(l);
    });
    a.appendChild(poderes);
    var teclas = el("div", "mmm-Painel mmm-Teclas");
    teclas.appendChild(el("h2", null, "Teclado"));
    [[["←", " não quero "], ["→", " quero"]], [["S", " super "], ["V", " veto "], ["espaço", " virar"]], [["Backspace", " desfaz o último"]]].forEach(function (linha) {
      var d = el("div");
      linha.forEach(function (t) {
        d.appendChild(el("kbd", null, t[0]));
        d.appendChild(document.createTextNode(t[1]));
      });
      teclas.appendChild(d);
    });
    a.appendChild(teclas);
    return a;
  }

  function telaBaralho(mudouPosicao) {
    var s = tela === "baralho" ? mesa.firstChild : null;
    if (s && !mudouPosicao) {
      atualizarPoderes(s);
      var velha = s.querySelector(".mmm-Lateral");
      if (velha) { velha.replaceWith(lateral()); }
      return;
    }
    s = secao("mmm-Baralho");
    s.appendChild(titulo1("Suas cartas", true));
    var cab = el("div", "mmm-JogoCab");
    var desf = botao("mmm-BotaoIcone", [icone("desfazer")], "desfazer");
    desf.dataset.foco = "desfazer";
    desf.setAttribute("aria-label", "Desfazer o último voto");
    desf.setAttribute("aria-keyshortcuts", "Backspace");
    cab.appendChild(desf);
    var prog = el("div", "mmm-Progresso");
    prog.setAttribute("aria-hidden", "true");
    prog.appendChild(el("i"));
    cab.appendChild(prog);
    cab.appendChild(el("div", "mmm-Progresso-num"));
    if (relogio.seg) { cab.appendChild(montarRelogio()); }
    s.appendChild(cab);
    var corpo = el("div", "mmm-JogoCorpo");
    var area = el("div", "mmm-Baralho-mesa");
    area.appendChild(el("div", "mmm-Pilha"));
    corpo.appendChild(area);
    corpo.appendChild(lateral());
    s.appendChild(corpo);
    var acoes = el("div", "mmm-Acoes");
    acoes.setAttribute("role", "group");
    acoes.setAttribute("aria-label", "Seu voto nesta carta");
    [["NAO", "x", "Não", "ArrowLeft", true], ["VETO", "veto", "Veto", "V"], ["SUPER", "estrela", "Super", "S"], ["QUERO", "coracao", "Quero", "ArrowRight", true]].forEach(function (x) {
      var bola = el("span", "mmm-Acao-bola");
      bola.appendChild(icone(x[1]));
      if (x[0] === "SUPER" || x[0] === "VETO") { bola.appendChild(el("span", "mmm-Acao-ficha", "1")); }
      var b = botao("mmm-Acao mmm-Acao--" + x[0].toLowerCase() + (x[4] ? " is-grande" : ""), [bola, el("span", "mmm-Acao-rotulo", x[2])]);
      b.dataset.voto = x[0];
      b.dataset.foco = "voto-" + x[0];
      b.setAttribute("aria-keyshortcuts", x[3]);
      if (x[0] === "NAO") { b.setAttribute("aria-label", "Não quero"); }
      if (x[0] === "QUERO") { b.setAttribute("aria-label", "Quero"); }
      acoes.appendChild(b);
    });
    s.appendChild(acoes);
    mostrar("baralho", s);
    desenharPilha(s);
  }

  // porTempo: o relógio da carta zerou (o Não sai como o do arraste para a esquerda)
  function votar(voto, porTempo) {
    if (tela !== "baralho" || deck.animando || (relogio.saindo && !porTempo)) { return; }
    var lista = ordem();
    var c = lista[deck.posicao];
    if (!c) { return; }
    if ((voto === "SUPER" || voto === "VETO") && !deck.poder[voto]) {
      mmm.toast(voto === "SUPER" ? "Você já usou o seu super." : "Você já usou o seu veto.");
      return;
    }
    var carta = cartaDoTopo();
    // a carta sai com o tempo que tinha: o Desfazer a devolve assim
    consumirRelogio();
    pararRelogio();
    if (carta) { carta.dataset.saiu = "1"; }
    deck.animando = true;
    // a pilha anda junto com a saída: as de trás sobem já, pela transição do CSS, e o fim aproveita as mesmas cartas (sem
    // isso, a de trás esperaria a saída acabar e pularia para a frente)
    if (carta && carta.parentNode && !reduz.matches) { carta.parentNode.dataset.anda = "1"; }
    deck.meus[c.id] = voto;
    if (deck.poder[voto] !== undefined) { deck.poder[voto]--; }
    mmm.jogo.votar(c.id, voto);
    mmm.som(voto.toLowerCase());
    mmm.vibrar(voto === "QUERO" || voto === "SUPER" ? 18 : 10);
    var fim = function () {
      deck.animando = false;
      deck.posicao++;
      if (deck.posicao >= lista.length || estadoNaFila) {
        // o último voto (a espera aparece já, e o servidor confirma ou revela) ou um estado que chegou durante a
        // animação: a tela inteira segue o que vale agora
        estadoNaFila = false;
        desenhar();
        if (tela !== "baralho" || deck.posicao >= lista.length) { return; }
      }
      desenharPilha(mesa.firstChild);
    };
    if (reduz.matches || !carta) {
      fim();
      return;
    }
    var destino = { QUERO: [1, 0], NAO: [-1, 0], SUPER: [0, -1], VETO: [0, 1] }[voto];
    var carimbo = carta.querySelector(".mmm-Carimbo--" + (voto === "NAO" ? "nao" : voto.toLowerCase()));
    if (carimbo) { carimbo.style.opacity = "1"; }
    carta.style.transition = "transform .38s cubic-bezier(.3,.7,.4,1), opacity .38s";
    var w = carta.offsetWidth;
    carta.style.transform = "translate(" + (destino[0] * w * 1.5) + "px, " + (destino[1] * w * 1.4) + "px) rotate(" + (destino[0] * 22) + "deg)";
    carta.style.opacity = "0";
    window.setTimeout(fim, 300);
  }

  function desfazer() {
    if (tela !== "baralho" || deck.animando || deck.posicao === 0 || relogio.saindo) { return; }
    var c = ordem()[deck.posicao - 1];
    if (relogioZerou(c.id)) {
      mmm.toast("O tempo de " + c.nome + " acabou: ela fica como Não.");
      return;
    }
    // a carta de agora guarda o tempo que tem; a desfeita volta com o que tinha quando saiu (e o aviso dos últimos
    // segundos de novo)
    consumirRelogio();
    pararRelogio();
    if (relogio.cartas[String(c.id)]) { relogio.cartas[String(c.id)].f = false; }
    var v = deck.meus[c.id];
    if (deck.poder[v] !== undefined) { deck.poder[v]++; }
    delete deck.meus[c.id];
    deck.posicao--;
    mmm.jogo.desfazer(c.id);
    desenharPilha(mesa.firstChild);
    mmm.toast("Voto desfeito");
  }

  // arraste: para os lados quero e não; para cima super e para baixo veto
  function prepararArrasto(carta) {
    var x0 = 0;
    var y0 = 0;
    var dx = 0;
    var dy = 0;
    var id = null;
    var t0 = 0;
    var carimbo = {};
    VOTOS.forEach(function (k) { carimbo[k] = carta.querySelector(".mmm-Carimbo--" + (k === "NAO" ? "nao" : k.toLowerCase())); });
    function limpar() {
      VOTOS.forEach(function (k) { if (carimbo[k]) { carimbo[k].style.opacity = ""; } });
    }
    carta.addEventListener("pointerdown", function (e) {
      if ((e.pointerType === "mouse" && e.button !== 0) || e.target.closest("button, a") || deck.animando || carta.classList.contains("is-virada")
        || carta.dataset.pos !== "0") { return; }
      id = e.pointerId;
      arrasto = { carta: carta, id: id, cancelar: function () { id = null; limpar(); } };
      x0 = e.clientX;
      y0 = e.clientY;
      dx = 0;
      dy = 0;
      t0 = performance.now();
      carta.setPointerCapture(id);
      carta.style.transition = "none";
    });
    carta.addEventListener("pointermove", function (e) {
      if (e.pointerId !== id) { return; }
      dx = e.clientX - x0;
      dy = e.clientY - y0;
      var vertical = Math.abs(dy) > Math.abs(dx);
      carta.style.transform = "translate(" + dx + "px, " + (vertical ? dy : dy * 0.25) + "px) rotate(" + (dx * 0.06) + "deg)";
      var limX = carta.offsetWidth * 0.3;
      var limY = carta.offsetHeight * 0.2;
      var f = function (v) { return String(Math.max(0, Math.min(1, v))); };
      carimbo.QUERO.style.opacity = vertical ? "0" : f(dx / limX);
      carimbo.NAO.style.opacity = vertical ? "0" : f(-dx / limX);
      carimbo.SUPER.style.opacity = vertical && deck.poder.SUPER ? f(-dy / limY) : "0";
      carimbo.VETO.style.opacity = vertical && deck.poder.VETO ? f(dy / limY) : "0";
    });
    function soltar(e) {
      if (e.pointerId !== id) { return; }
      id = null;
      if (arrasto && arrasto.carta === carta) { arrasto = null; }
      // a carta já saiu (o relógio zerou no meio do arraste): o toque não vale para a carta seguinte
      if (carta.dataset.saiu) { return; }
      var dt = Math.max(1, performance.now() - t0);
      var vertical = Math.abs(dy) > Math.abs(dx);
      var voto = null;
      if (e.type === "pointerup") {
        if (!vertical && (Math.abs(dx) > carta.offsetWidth * 0.3 || (Math.abs(dx) > 40 && Math.abs(dx) / dt > 0.6))) {
          voto = dx > 0 ? "QUERO" : "NAO";
        } else if (vertical && (Math.abs(dy) > carta.offsetHeight * 0.2 || (Math.abs(dy) > 40 && Math.abs(dy) / dt > 0.6))) {
          voto = dy < 0 ? "SUPER" : "VETO";
        }
      }
      if (voto && (voto === "QUERO" || voto === "NAO" || deck.poder[voto])) {
        votar(voto);
        return;
      }
      if (voto) { mmm.toast(voto === "SUPER" ? "Você já usou o seu super." : "Você já usou o seu veto."); }
      carta.style.transition = "transform .35s cubic-bezier(.2,1.4,.4,1)";
      carta.style.transform = "";
      limpar();
      if (e.type === "pointerup" && Math.abs(dx) < 6 && Math.abs(dy) < 6) { virar(carta); }
    }
    carta.addEventListener("pointerup", soltar);
    carta.addEventListener("pointercancel", soltar);
  }

  /* ---------- relógio de cada carta (só no baralho) ---------- */
  // O tempo corre no aparelho, na carta do topo, pelo relógio do sistema, também com o app escondido ou fechado: na
  // volta, a carta que zerou vira Não (só ela: a seguinte começa quando aparece). A sinopse aberta segura o relógio por
  // até 10 s em cada carta. O Desfazer devolve a carta com o tempo que ela tinha quando saiu, e a carta que zerou não
  // volta. O que cada carta ainda tem fica no localStorage do aparelho: recarregar a página não dá tempo a mais.
  function lerRelogio() {
    var g = null;
    try {
      // só a sessão de agora fica guardada
      for (var i = window.localStorage.length - 1; i >= 0; i--) {
        var k = window.localStorage.key(i);
        if (k && k.indexOf("mmm-relogio-") === 0 && k !== CHAVE_RELOGIO) { window.localStorage.removeItem(k); }
      }
      g = JSON.parse(window.localStorage.getItem(CHAVE_RELOGIO) || "null");
    } catch (e) {
      g = null;
    }
    if (g && g.cartas && typeof g.cartas === "object") { relogio.cartas = g.cartas; }
    // a carta que corria quando a página saiu: o tempo de fora conta para ela
    if (g && g.topo && g.topo.id && Number(g.topo.t)) { relogio.volta = { id: String(g.topo.id), t: Number(g.topo.t) }; }
  }

  function salvarRelogio() {
    relogio.salvoEm = Date.now();
    try {
      window.localStorage.setItem(CHAVE_RELOGIO, JSON.stringify({ cartas: relogio.cartas, topo: relogio.id ? { id: relogio.id, t: relogio.t } : null }));
    } catch (e) {
      /* sem storage: o relógio vale enquanto a página está aberta */
    }
  }

  function esquecerRelogio() {
    try { window.localStorage.removeItem(CHAVE_RELOGIO); } catch (e) { /* nada guardado */ }
  }

  function cartaRelogio(id) {
    var k = String(id);
    var d = relogio.cartas[k];
    if (!d || typeof d.r !== "number") {
      d = relogio.cartas[k] = { r: relogio.seg * 1000, p: PAUSA_SINOPSE, z: false, f: false };
    }
    return d;
  }

  function relogioZerou(id) {
    var d = relogio.cartas[String(id)];
    return !!relogio.seg && !!d && d.z === true;
  }

  function montarRelogio() {
    var r = el("div", "mmm-Relogio");
    r.setAttribute("role", "timer");
    var anel = el("span", "mmm-Relogio-anel");
    anel.setAttribute("aria-hidden", "true");
    r.appendChild(anel);
    var num = el("span", "mmm-Relogio-num");
    num.setAttribute("aria-hidden", "true");
    r.appendChild(num);
    var un = el("span", "mmm-Relogio-un", "s");
    un.setAttribute("aria-hidden", "true");
    r.appendChild(un);
    var lendo = el("span", "mmm-Relogio-lendo", "lendo");
    lendo.setAttribute("aria-hidden", "true");
    r.appendChild(lendo);
    return r;
  }

  function desenharRelogio() {
    var r = mesa.querySelector(".mmm-Relogio");
    if (!r || !relogio.id) { return; }
    var d = cartaRelogio(relogio.id);
    var seg = Math.ceil(d.r / 1000);
    var lendo = deck.virada && d.p > 0 && !d.z;
    var urgente = !lendo && d.r <= URGENTE;
    r.style.setProperty("--mmm-relogio", String(Math.max(0, Math.min(1, d.r / (relogio.seg * 1000)))));
    r.classList.toggle("is-urgente", urgente);
    r.classList.toggle("is-lendo", lendo);
    if (mesa.firstChild && mesa.firstChild.classList) { mesa.firstChild.classList.toggle("is-urgente", urgente); }
    var num = r.querySelector(".mmm-Relogio-num");
    if (num.textContent !== String(seg)) { num.textContent = String(seg); }
    var rotulo = (lendo ? "Relógio parado enquanto você lê a sinopse: " : "Tempo para esta carta: ") + tempoFalado(seg) + ".";
    if (r.getAttribute("aria-label") !== rotulo) { r.setAttribute("aria-label", rotulo); }
  }

  // a carta do topo passa a correr; a que volta ao topo (Desfazer, recarga) segue de onde parou
  function relogioNaCarta(id) {
    if (!relogio.seg || tela !== "baralho") {
      pararRelogio();
      return;
    }
    var k = String(id);
    if (relogio.id === k && relogio.timer) {
      desenharRelogio();
      return;
    }
    window.clearInterval(relogio.timer);
    relogio.id = k;
    relogio.t = Date.now();
    var d = cartaRelogio(k);
    // zerou e o Não não chegou a sair (recusa, estado que voltou a carta): vai de novo
    if (d.z && d.r <= 0) { d.z = false; }
    if (relogio.volta) {
      // a página voltou (recarga, app reaberto) com esta carta no topo: o tempo de fora conta
      if (relogio.volta.id === k && relogio.volta.t <= relogio.t && !d.z) {
        d.r = Math.max(0, d.r - (relogio.t - relogio.volta.t));
        if (d.r <= 0) { relogio.escondido = true; }
      }
      relogio.volta = null;
    }
    relogio.timer = window.setInterval(passoRelogio, 200);
    salvarRelogio();
    passoRelogio();
  }

  function pararRelogio() {
    window.clearInterval(relogio.timer);
    relogio.timer = null;
    if (relogio.id) {
      relogio.id = null;
      salvarRelogio();
    }
  }

  // o tempo desde o último passo sai da carta que corre (a sinopse aberta gasta antes a pausa da carta); não vota
  function consumirRelogio() {
    if (!relogio.id) { return null; }
    var agora = Date.now();
    var dt = Math.max(0, agora - relogio.t);
    relogio.t = agora;
    var d = cartaRelogio(relogio.id);
    if (d.z) { return d; }
    if (deck.virada && d.p > 0) {
      var usa = Math.min(d.p, dt);
      d.p -= usa;
      dt -= usa;
    }
    d.r = Math.max(0, d.r - dt);
    return d;
  }

  // voltou: o app acabou de voltar à frente (o tempo escondido entra agora)
  function passoRelogio(voltou) {
    var d = consumirRelogio();
    if (!d || d.z) { return; }
    var agora = relogio.t;
    if (d.r <= 0 && voltou === true) { relogio.escondido = true; }
    if (document.visibilityState === "hidden") {
      // escondido não desenha nem vota: a carta que zerou vira Não quando o app volta à frente
      if (d.r <= 0) { relogio.escondido = true; }
      if (agora - relogio.salvoEm > 1000) { salvarRelogio(); }
      return;
    }
    desenharRelogio();
    // os últimos segundos, uma vez por carta, para o leitor de tela (a sinopse aberta e parada não conta)
    if (!d.f && d.r > 0 && d.r <= URGENTE && !(deck.virada && d.p > 0)) {
      d.f = true;
      var n = Math.ceil(d.r / 1000);
      falarRelogio.textContent = "";
      window.setTimeout(function () { falarRelogio.textContent = "Faltam " + n + " segundos para esta carta."; }, 40);
    }
    if (d.r <= 0) { esgotar(); }
    if (agora - relogio.salvoEm > 1000) { salvarRelogio(); }
  }

  // o relógio da carta zerou: um Não pela mesma fila de jogadas, com a saída para a esquerda
  function esgotar() {
    var k = relogio.id;
    var d = cartaRelogio(k);
    // com outra carta saindo ou um diálogo aberto o voto espera (o relógio já está em zero)
    if (d.z || deck.animando || relogio.saindo || tela !== "baralho" || dialogoAberto()) { return; }
    var lista = ordem();
    var c = lista[deck.posicao];
    if (!c || String(c.id) !== k) { return; }
    d.z = true;
    relogio.saindo = true;
    var fechado = relogio.escondido;
    relogio.escondido = false;
    salvarRelogio();
    var aviso = fechado ? "O tempo de " + c.nome + " acabou enquanto o app estava fechado: ficou como Não."
      : "O tempo acabou: " + c.nome + " ficou como Não.";
    mmm.toast(aviso);
    // o anúncio vai junto com o da carta seguinte (ou sai já, se era a última)
    if (deck.posicao + 1 < lista.length) { relogio.aviso = aviso; } else { anunciar(aviso); }
    var carta = cartaDoTopo();
    // arraste em curso: a carta sai assim mesmo, e o dedo que solta depois não vota na seguinte
    if (arrasto && carta && arrasto.carta === carta) {
      try { carta.releasePointerCapture(arrasto.id); } catch (e) { /* o ponteiro já soltou */ }
      arrasto.cancelar();
      arrasto = null;
    }
    var sair = function () {
      relogio.saindo = false;
      if (tela === "baralho" && ordem()[deck.posicao] === c) { votar("NAO", true); }
    };
    // a sinopse aberta fecha antes, para a pessoa ver qual carta saiu
    if (carta && carta.classList.contains("is-virada")) {
      virar(carta, true);
      window.setTimeout(sair, reduz.matches ? 0 : 450);
      return;
    }
    sair();
  }

  document.addEventListener("visibilitychange", function () {
    if (!relogio.id) { return; }
    passoRelogio(document.visibilityState === "visible");
    if (document.visibilityState === "hidden") { salvarRelogio(); }
  });
  window.addEventListener("pagehide", function () {
    if (relogio.id) {
      passoRelogio();
      salvarRelogio();
    }
  });

  /* ---------- espera: o sofá, quem falta e o que dá para fazer enquanto isso ---------- */
  function semSinal(p) {
    if (p.robo === true) { return null; }
    if (p.segSemSinal === undefined || p.segSemSinal === null) { return p.situacao === "CONVIDADO" ? "ainda não abriu" : null; }
    // entre um estado e outro o número conta sozinho, sem pedido a mais
    var s = Number(p.segSemSinal) + Math.floor((Date.now() - estadoEm) / 1000);
    // ler uma sinopse com calma não é queda: só depois de 5 minutos (o "Só falta você" do servidor usa o mesmo)
    if (s < 300) { return null; }
    return "sem sinal há " + Math.floor(s / 60) + " min";
  }

  window.setInterval(function () {
    raiz.querySelectorAll("li[data-sinal]").forEach(function (li) {
      var p = pessoas[li.dataset.sinal];
      var texto = p ? semSinal(p) : null;
      var s = li.querySelector(".mmm-PessoaEspera-sinal");
      if (!texto) {
        if (s) { s.remove(); }
        return;
      }
      if (!s) {
        s = el("span", "mmm-PessoaEspera-sinal");
        li.insertBefore(s, li.querySelector("button"));
      }
      s.textContent = texto;
    });
  }, 30000);

  function cronometro(p) {
    if (p.segBaralho === undefined || p.segBaralho === null) { return null; }
    return Number(p.segBaralho) + Math.floor((Date.now() - estadoEm) / 1000);
  }

  // o cronômetro anda a cada segundo, sem pedido ao servidor
  window.setInterval(function () {
    raiz.querySelectorAll("[data-cronometro]").forEach(function (c) {
      var p = pessoas[c.dataset.cronometro];
      var s = p ? cronometro(p) : null;
      if (s === null) { return; }
      var v = c.querySelector(".mmm-PessoaEspera-tempoValor");
      if (v) { v.replaceWith(tempoDuplo("mmm-PessoaEspera-tempoValor", s)); }
    });
  }, 1000);

  function rotuloSituacao(p, deve) {
    if (p.situacao === "SAIU") { return "Saiu"; }
    if (estado.status === "VOTANDO") {
      if (p.situacao === "PRONTO" || prontoAqui(p)) { return "Pronto"; }
      return p.situacao === "CONVIDADO" ? "Chamado" : "Votando…";
    }
    return deve ? "Escolhendo…" : "Pronto";
  }

  function listaSofa(comAcoes) {
    var deve = devendo().map(function (p) { return p.id; });
    var lista = el("ul", "mmm-Esperando");
    (estado.presencas || []).forEach(function (p) {
      var falta = deve.indexOf(p.id) >= 0;
      var li = el("li", "mmm-PessoaEspera" + (p.situacao === "SAIU" ? " is-saiu" : falta ? " is-votando" : " is-pronto"));
      li.appendChild(avatar(p));
      var nome = el("span", "mmm-PessoaEspera-nome", p.apelido + (p.id === estado.eu.id ? " (você)" : ""));
      li.appendChild(nome);
      li.appendChild(el("span", "mmm-PessoaEspera-situacao", rotuloSituacao(p, falta) + (p.robo === true ? " · simulado" : "")));
      var sinal = falta ? semSinal(p) : null;
      if (sinal) { li.appendChild(el("span", "mmm-PessoaEspera-sinal", sinal)); }
      if (falta) { li.dataset.sinal = String(p.id); }
      // há quanto tempo quem ainda vota abriu o baralho: conta no aparelho entre um estado e outro
      var crono = falta && estado.status === "VOTANDO" ? cronometro(p) : null;
      if (crono !== null) {
        var tc = el("span", "mmm-PessoaEspera-tempo");
        tc.dataset.cronometro = String(p.id);
        tc.appendChild(icone("relogio"));
        tc.appendChild(el("span", "mmm-Sr", "há "));
        tc.appendChild(tempoDuplo("mmm-PessoaEspera-tempoValor", crono));
        li.appendChild(tc);
      }
      if (comAcoes && falta && p.id !== estado.eu.id && p.robo !== true && estou()) {
        var t = botao("mmm-JogoBotao mmm-JogoBotao--mini", ["Tirar do sofá"], "remover");
        t.dataset.membro = String(p.id);
        t.dataset.nome = p.apelido;
        t.dataset.foco = "remover-" + p.id;
        t.setAttribute("aria-label", "Tirar " + p.apelido + " do sofá");
        li.appendChild(t);
      }
      lista.appendChild(li);
    });
    return lista;
  }

  // cutucar, sair e voltar, encerrar: o servidor confere cada um (quem pode, uma vez por minuto)
  function acoesDaEspera() {
    var b = el("div", "mmm-Botoes");
    var outros = devendo().filter(function (p) { return p.id !== estado.eu.id && p.robo !== true; });
    if (!DEMO && estou() && outros.length) {
      var c = botao("mmm-JogoBotao", [icone("relogio"), "Cutucar quem falta"], "cutucar");
      c.dataset.foco = "cutucar";
      if (Date.now() < cutucadaAte) {
        c.setAttribute("aria-disabled", "true");
        c.classList.add("is-disabled");
      }
      b.appendChild(c);
    }
    var sit = situacao();
    if (estado.status === "VOTANDO" && (sit === "SAIU" || sit === "ESPECTADOR")) {
      var v = botao("mmm-JogoBotao mmm-JogoBotao--pri", ["Voltar para o sofá"], "entrar");
      v.dataset.foco = "entrar";
      b.appendChild(v);
    } else if (estou() && !DEMO) {
      var s = botao("mmm-JogoBotao", ["Sair do sofá"], "sair");
      s.dataset.foco = "sair";
      b.appendChild(s);
    }
    var criadorSaiu = (estado.presencas || []).some(function (p) { return p.id === estado.criador && p.situacao === "SAIU"; });
    if (estado.criador === estado.eu.id || (criadorSaiu && estou())) {
      var e = botao("mmm-JogoBotao mmm-JogoBotao--perigo", ["Encerrar a sessão"], "cancelar");
      e.dataset.foco = "cancelar";
      b.appendChild(e);
    }
    b.appendChild(link("mmm-JogoBotao mmm-JogoBotao--link", URL_INICIO, ["Lista do grupo"]));
    return b;
  }

  function telaEspera() {
    var s = secao("mmm-Centro mmm-Espera");
    var sit = situacao();
    var assistindo = sit === "SAIU" || sit === "ESPECTADOR";
    s.appendChild(titulo1(assistindo ? "A TURMA ESTÁ VOTANDO" : "ESPERANDO A TURMA"));
    s.appendChild(listaSofa(true));
    s.appendChild(el("p", "mmm-Centro-texto", assistindo
      ? (sit === "SAIU" ? "Você saiu do sofá. Seus votos ficaram guardados: dá para voltar enquanto a turma vota." : "A turma está votando. Entre no sofá para votar também.")
      : "Ninguém vê o voto do outro. As cartas viram juntas quando todo mundo terminar."));
    s.appendChild(acoesDaEspera());
    mostrar("espera", s);
  }

  /* ---------- revelação ---------- */
  function finalistas() {
    return (estado.cartas || []).filter(function (c) { return c.finalista === true; })
      .sort(function (a, b) { return (a.posicaoFinal || 99) - (b.posicaoFinal || 99); });
  }

  function resumoRevelacao() {
    var fins = finalistas();
    if (estado.status === "SEM_RESULTADO" || !fins.length) { return "Ninguém quis nada. Hora de afrouxar os filtros."; }
    var matches = (estado.cartas || []).filter(function (c) { return c.match === true; }).length;
    if (estado.motivo === "SEM_MATCH") { return "Ninguém deu match. " + (fins.length === 1 ? "O mais votado vai direto." : "Os " + fins.length + " mais votados vão para a final."); }
    if (fins.length === 1) { return "Só um título passou. Nem precisa de final."; }
    var supers = fins.length - fins.filter(function (c) { return c.match === true; }).length;
    return fins.length + " vão para a final: " + matches + (matches === 1 ? " match" : " matches") + (supers ? " e " + supers + " por super" : "") + ".";
  }

  function miniRevelada(rc) {
    var c = porId[rc.id];
    var li = el("li", "mmm-Mini" + (rc.finalista === true ? "" : " is-fora"));
    var gira = el("div", "mmm-Mini-gira");
    gira.appendChild(el("div", "mmm-Mini-face mmm-Mini-costas"));
    var frente = el("div", "mmm-Mini-face mmm-Mini-frente");
    frente.appendChild(poster(c, ["w185", "w342"], "(min-width: 700px) 124px, 30vw", c ? c.nome : "", "mmm-Mini-poster"));
    var fita = null;
    if (Number(rc.veto) > 0) { fita = ["veto", "VETO"]; } else if (rc.match === true) { fita = ["match", "MATCH"]; } else if (rc.finalista === true && Number(rc.super) > 0) { fita = ["super", "SUPER"]; }
    if (fita) { frente.appendChild(el("span", "mmm-Fita mmm-Fita--" + fita[0], fita[1])); }
    gira.appendChild(frente);
    li.appendChild(gira);
    var votos = el("div", "mmm-Votos");
    var legenda = [];
    Object.keys(rc.votos || {}).forEach(function (id) {
      var v = rc.votos[id];
      var p = pessoas[id];
      var x = el("span", "mmm-Voto");
      x.dataset.v = String(v).toLowerCase();
      x.appendChild(avatar(p, true));
      var i = el("i");
      i.appendChild(icone(ICONE_VOTO[v] || "x"));
      x.appendChild(i);
      votos.appendChild(x);
      legenda.push((p ? p.apelido : "?") + ": " + (ROTULO_VOTO[v] || v));
    });
    votos.setAttribute("role", "img");
    votos.setAttribute("aria-label", legenda.join(", "));
    li.appendChild(votos);
    return li;
  }

  function botaoDaRevelacao() {
    var fins = finalistas();
    if (estado.status === "SEM_RESULTADO" || !fins.length) {
      return link("mmm-JogoBotao mmm-JogoBotao--pri", URL_ABERTURA, ["Voltar à abertura"]);
    }
    if (situacao() !== "PRONTO") { return el("p", "mmm-Sintonia", "Quem votou leva a turma para a final."); }
    var b = botao("mmm-JogoBotao mmm-JogoBotao--pri", [fins.length === 1 ? "Ver o ingresso" : "Para a final"], "avancar");
    b.dataset.foco = "avancar";
    return b;
  }

  // quanto tempo cada um levou no baralho (de abrir à última carta) e quem foi o mais rápido; os simulados da demo
  // vêm marcados. O tempo só chega do servidor depois da votação
  function blocoTempos() {
    var lista = (estado.presencas || []).filter(function (p) { return p.tempoBaralho !== undefined && p.tempoBaralho !== null; })
      .sort(function (a, b) { return Number(a.tempoBaralho) - Number(b.tempoBaralho) || String(a.apelido).localeCompare(String(b.apelido)); });
    if (!lista.length) { return null; }
    var s = el("section", "mmm-Tempos");
    s.setAttribute("aria-labelledby", "mmm-tempos-titulo");
    var h = el("h2", "mmm-Tempos-titulo", "Tempo no baralho");
    h.id = "mmm-tempos-titulo";
    s.appendChild(h);
    var menor = Number(lista[0].tempoBaralho);
    var rapidos = lista.length > 1 ? lista.filter(function (p) { return Number(p.tempoBaralho) === menor; }) : [];
    var quem = function (p) { return p.id === estado.eu.id ? "Você" : p.apelido; };
    if (rapidos.length) {
      var d = el("p", "mmm-Tempos-destaque");
      d.appendChild(icone("raio"));
      var texto = rapidos.length === 1
        ? (rapidos[0].id === estado.eu.id ? "Você foi quem votou mais rápido: " : rapidos[0].apelido + " foi quem votou mais rápido: ")
        : nomes(rapidos.map(quem)) + " empataram como os mais rápidos: ";
      d.appendChild(document.createTextNode(texto));
      d.appendChild(tempoDuplo("mmm-Tempos-destaqueTempo", menor));
      d.appendChild(document.createTextNode("."));
      s.appendChild(d);
    }
    var ol = el("ol", "mmm-Tempos-lista");
    lista.forEach(function (p) {
      var li = el("li", "mmm-Tempos-item" + (rapidos.indexOf(p) >= 0 ? " is-rapido" : ""));
      li.appendChild(avatar(p, true));
      // na demo o apelido já é "Você"
      var nome = el("span", "mmm-Tempos-nome", p.apelido + (p.id === estado.eu.id && !/^voc[eê]$/i.test(String(p.apelido || "").trim()) ? " (você)" : ""));
      if (p.robo === true) { nome.appendChild(el("small", "mmm-Tempos-simulado", " simulado")); }
      li.appendChild(nome);
      li.appendChild(tempoDuplo("mmm-Tempos-tempo", p.tempoBaralho));
      ol.appendChild(li);
    });
    s.appendChild(ol);
    return s;
  }

  function telaRevelacao() {
    var chave = estado.sessao + ":" + estado.status;
    var s = tela === "revelacao" ? mesa.firstChild : null;
    var animar = revelada !== estado.sessao;
    if (s && s.dataset.chave === chave) {
      // a mesma revelação: só o botão e o rodapé acompanham (o PRONTO de quem leva para a final)
      var velho = s.querySelector(".mmm-RodapeJogo > :last-child");
      if (velho && !s.classList.contains("is-virando")) { velho.replaceWith(botaoDaRevelacao()); }
      return;
    }
    s = secao("mmm-Revelacao");
    s.dataset.chave = chave;
    var cab = el("div", "mmm-Revelacao-cab");
    cab.appendChild(titulo1("AS CARTAS NA MESA"));
    var resumo = el("p", "mmm-Revelacao-resumo");
    resumo.setAttribute("aria-live", "polite");
    cab.appendChild(resumo);
    s.appendChild(cab);
    var grade = el("ul", "mmm-Reveladas");
    (estado.cartas || []).forEach(function (rc) { grade.appendChild(miniRevelada(rc)); });
    s.appendChild(grade);
    var tempos = blocoTempos();
    if (tempos) { s.appendChild(tempos); }
    var pe = el("div", "mmm-RodapeJogo");
    var sint = el("div", "mmm-Sintonia");
    sint.appendChild(document.createTextNode("Sintonia da turma: "));
    var b = el("b", null, "…");
    sint.appendChild(b);
    pe.appendChild(sint);
    var acao = botaoDaRevelacao();
    pe.appendChild(acao);
    s.appendChild(pe);
    mostrar("revelacao", s);
    var final = function () {
      s.classList.remove("is-virando");
      b.textContent = estado.sintonia !== undefined && estado.sintonia !== null ? estado.sintonia + "%" : "—";
      resumo.textContent = resumoRevelacao();
      var velho = s.querySelector(".mmm-RodapeJogo > :last-child");
      if (velho) { velho.replaceWith(botaoDaRevelacao()); }
      if ((estado.cartas || []).some(function (c) { return c.match === true; })) { mmm.som("match"); }
    };
    var minis = grade.querySelectorAll(".mmm-Mini");
    if (!animar || reduz.matches) {
      minis.forEach(function (m) { m.classList.add("is-aberta"); });
      revelada = estado.sessao;
      final();
      return;
    }
    revelada = estado.sessao;
    s.classList.add("is-virando");
    resumo.textContent = "Virando as cartas…";
    acao.hidden = true;
    minis.forEach(function (m, n) {
      window.setTimeout(function () { m.classList.add("is-aberta"); mmm.som("vira"); }, 250 + n * 130);
    });
    window.setTimeout(final, 250 + minis.length * 130 + 450);
  }

  /* ---------- final: duelos ---------- */
  function lado(c, letra, escolhido) {
    var b = el("button", "mmm-Lado" + (escolhido ? " is-escolhido" : ""));
    b.type = "button";
    b.dataset.lado = letra;
    b.dataset.foco = "lado-" + letra;
    b.setAttribute("aria-pressed", String(!!escolhido));
    b.setAttribute("aria-label", "Prefiro " + (c ? c.nome : "este"));
    var capa = el("span", "mmm-Lado-capa");
    capa.appendChild(poster(c, ["w185", "w342", "w500"], "(max-aspect-ratio: 4/5) 46vw, 30vw", "", "mmm-Lado-poster"));
    capa.appendChild(el("span", "mmm-Lado-votos"));
    b.appendChild(capa);
    var t = el("span", "mmm-Lado-texto");
    t.appendChild(el("span", "mmm-Lado-nome", c ? c.nome : ""));
    if (c) { t.appendChild(el("span", "mmm-Lado-meta", [c.ano, duracao(c)].filter(Boolean).join(" · "))); }
    b.appendChild(t);
    return b;
  }

  function chaveFinal(total, feitos) {
    var k = el("div", "mmm-ChaveFinal");
    k.setAttribute("aria-hidden", "true");
    for (var i = 0; i < total; i++) { k.appendChild(el("span", i < feitos ? "is-feito" : i === feitos ? "is-agora" : null)); }
    return k;
  }

  function dicaDoDuelo(atual) {
    var p = el("div", "mmm-Final-dica");
    if (situacao() !== "PRONTO") {
      p.appendChild(el("p", null, "Quem votou o baralho escolhe os duelos. Você acompanha daqui."));
      return p;
    }
    if (!atual.meuVoto) {
      p.appendChild(el("p", null, "Toque no que você prefere. Vence a maioria."));
      return p;
    }
    var faltam = devendo().filter(function (x) { return x.id !== estado.eu.id; });
    p.appendChild(el("p", null, faltam.length ? "Seu voto foi. Esperando " + nomes(faltam.map(function (x) { return x.apelido; })) + "." : "Seu voto foi."));
    if (faltam.length) {
      p.appendChild(listaSofa(true));
      p.appendChild(acoesDaEspera());
    }
    return p;
  }

  function telaDuelo() {
    var d = estado.duelos || {};
    var atual = d.atual;
    if (!atual) { return telaCarregando("Preparando o próximo duelo…"); }
    var s = tela === "duelo" ? mesa.firstChild : null;
    if (s && dueloNaTela === atual.id) {
      // o mesmo duelo: o meu voto e quem já votou mudam; o resto fica (o foco também)
      s.querySelectorAll(".mmm-Lado").forEach(function (b) {
        var meu = atual.meuVoto === b.dataset.lado;
        b.classList.toggle("is-escolhido", meu);
        b.setAttribute("aria-pressed", String(meu));
      });
      var velha = s.querySelector(".mmm-Final-dica");
      var foco = document.activeElement && velha.contains(document.activeElement) ? document.activeElement.dataset.foco : null;
      var nova = dicaDoDuelo(atual);
      velha.replaceWith(nova);
      if (foco) {
        var alvo = nova.querySelector('[data-foco="' + foco + '"]');
        if (alvo) { alvo.focus({ preventScroll: true }); }
      }
      return;
    }
    dueloNaTela = atual.id;
    var a = porId[atual.a];
    var b = porId[atual.b];
    s = secao("mmm-Final");
    s.dataset.duelo = String(atual.id);
    var cab = el("div", "mmm-Final-cab");
    cab.appendChild(el("small", null, (atual.rodada || "Final") + " · duelo " + atual.numero + " de " + d.total));
    cab.appendChild(titulo1("QUAL DOS DOIS?"));
    s.appendChild(cab);
    var duelo = el("div", "mmm-Duelo");
    duelo.setAttribute("role", "group");
    duelo.setAttribute("aria-label", "Escolha um dos dois");
    duelo.appendChild(lado(a, "A", atual.meuVoto === "A"));
    var vs = el("span", "mmm-Versus", "VS");
    vs.setAttribute("aria-hidden", "true");
    duelo.appendChild(vs);
    duelo.appendChild(lado(b, "B", atual.meuVoto === "B"));
    if (situacao() !== "PRONTO") { duelo.querySelectorAll(".mmm-Lado").forEach(function (x) { x.setAttribute("aria-disabled", "true"); x.classList.add("is-assistindo"); }); }
    s.appendChild(duelo);
    // bye: com número ímpar o mais bem colocado passa direto (o servidor diz quem, quando manda)
    if (atual.bye && porId[atual.bye]) { s.appendChild(el("p", "mmm-Final-bye", porId[atual.bye].nome + " passou direto para a próxima rodada.")); }
    s.appendChild(chaveFinal(Number(d.total) || 0, Number(d.feitos) || 0));
    s.appendChild(dicaDoDuelo(atual));
    // o foco não volta ao lado de mesmo nome: no navegador o anel parecia uma escolha já feita no duelo novo
    mostrar("duelo", s, true);
    anunciar("Duelo: " + (a ? a.nome : "") + " contra " + (b ? b.nome : "") + ".");
  }

  // o duelo que acabou de fechar: quem votou em quem e o vencedor (com a moeda no empate) antes do próximo
  function animarResultado(u, depois) {
    travada = true;
    var s = mesa.firstChild;
    if (!(tela === "duelo" && dueloNaTela === u.id)) {
      s = secao("mmm-Final");
      var cab = el("div", "mmm-Final-cab");
      cab.appendChild(el("small", null, "Duelo " + u.numero));
      cab.appendChild(titulo1("QUAL DOS DOIS?"));
      s.appendChild(cab);
      var duelo = el("div", "mmm-Duelo");
      duelo.appendChild(lado(porId[u.a], "A", false));
      var vs = el("span", "mmm-Versus", "VS");
      vs.setAttribute("aria-hidden", "true");
      duelo.appendChild(vs);
      duelo.appendChild(lado(porId[u.b], "B", false));
      s.appendChild(duelo);
      s.appendChild(el("div", "mmm-Final-dica"));
      mostrar("duelo", s);
      dueloNaTela = u.id;
    }
    var h = s.querySelector("h1");
    var ladoVence = u.vencedor === u.a ? "A" : "B";
    s.querySelectorAll(".mmm-Lado").forEach(function (b) {
      b.setAttribute("aria-disabled", "true");
      var caixa = b.querySelector(".mmm-Lado-votos");
      caixa.textContent = "";
      Object.keys(u.votos || {}).forEach(function (id) {
        if (u.votos[id] === b.dataset.lado) { caixa.appendChild(avatar(pessoas[id], true)); }
      });
    });
    var vence = porId[u.vencedor];
    var fechar = function () {
      s.querySelectorAll(".mmm-Lado").forEach(function (b) { b.classList.add(b.dataset.lado === ladoVence ? "is-escolhido" : "is-perdeu"); });
      anunciar("Venceu " + (vence ? vence.nome : "") + ".");
      mmm.som("tique");
      window.setTimeout(function () {
        travada = false;
        depois();
      }, reduz.matches ? 600 : 1300);
    };
    if (u.decisao === "MOEDA") {
      h.textContent = "EMPATE! MOEDA...";
      window.setTimeout(function () {
        var chance = u.chanceA !== undefined && u.chanceA !== null ? Math.round((ladoVence === "A" ? u.chanceA : 1 - u.chanceA) * 100) : null;
        mmm.toast("A moeda escolheu " + (vence ? vence.nome : "") + (chance !== null ? " (tinha " + chance + "% de chance)" : ""));
        fechar();
      }, reduz.matches ? 200 : 1100);
      return;
    }
    fechar();
  }

  /* ---------- final: roleta (o servidor sorteia; o aparelho só anima até o resultado dele) ---------- */
  var VELUDOS = ["#4a2d6b", "#2c1d45", "#5a2a52", "#22345a", "#3e2a63", "#4c2342", "#263d55", "#35214f"];

  function pararRoleta() {
    if (roleta && roleta.pisca) { window.clearInterval(roleta.pisca); }
    if (roleta) { roleta.pisca = null; }
  }

  function montarRoleta(cv, fatias) {
    var total = fatias.reduce(function (a, f) { return a + (Number(f.peso) || 0); }, 0) || 1;
    var ang = 0;
    var r = { cv: cv, rot: 0, luz: 0, vencedor: null, girando: false, girou: false, fatias: [] };
    fatias.forEach(function (f, i) {
      var tam = (Number(f.peso) || 0) / total * Math.PI * 2;
      var c = porId[f.carta];
      var im = null;
      if (c && CAMINHO_TMDB.test(c.poster || "")) {
        im = new Image();
        im.decoding = "async";
        im.onload = function () { if (roleta === r && !r.girando) { desenharRoleta(); } };
        im.src = CDN + "w185" + c.poster;
      }
      r.fatias.push({ carta: f.carta, ini: ang, tam: tam, cor: VELUDOS[i % VELUDOS.length], im: im, pct: Math.round((Number(f.peso) || 0) / total * 100) });
      ang += tam;
    });
    return r;
  }

  function desenharRoleta() {
    if (!roleta) { return; }
    var cv = roleta.cv;
    var ctx = cv.getContext("2d");
    var c = cv.width / 2;
    var R = c - 4;
    var Ri = R - 40;
    ctx.clearRect(0, 0, cv.width, cv.height);
    // aro de veludo com lâmpadas (o aro não gira, só as luzes correm)
    var aro = ctx.createRadialGradient(c, c, Ri, c, c, R);
    aro.addColorStop(0, "#2a1a3f");
    aro.addColorStop(0.5, "#4b3270");
    aro.addColorStop(1, "#2a1a3f");
    ctx.beginPath();
    ctx.arc(c, c, R, 0, Math.PI * 2);
    ctx.fillStyle = aro;
    ctx.fill();
    var nL = 32;
    for (var i = 0; i < nL; i++) {
      var a = i / nL * Math.PI * 2;
      var acesa = (i + roleta.luz) % 3 === 0;
      ctx.beginPath();
      ctx.arc(c + Math.cos(a) * (R - 20), c + Math.sin(a) * (R - 20), 7, 0, Math.PI * 2);
      ctx.fillStyle = acesa ? "#ffe7a3" : "#6e5833";
      ctx.shadowColor = acesa ? "rgba(255, 201, 74, .95)" : "transparent";
      ctx.shadowBlur = acesa ? 16 : 0;
      ctx.fill();
    }
    ctx.shadowBlur = 0;
    ctx.shadowColor = "transparent";
    ctx.save();
    ctx.translate(c, c);
    ctx.rotate(roleta.rot);
    roleta.fatias.forEach(function (f) {
      ctx.beginPath();
      ctx.moveTo(0, 0);
      ctx.arc(0, 0, Ri, f.ini, f.ini + f.tam);
      ctx.closePath();
      if (roleta.vencedor === f.carta) {
        var g = ctx.createRadialGradient(0, 0, Ri * 0.2, 0, 0, Ri);
        g.addColorStop(0, "#ffe7a3");
        g.addColorStop(1, "#f2a92b");
        ctx.fillStyle = g;
      } else {
        ctx.fillStyle = f.cor;
      }
      ctx.fill();
      // pôster em pé ao longo do raio, com o topo para fora
      var dist = Ri * 0.63;
      var h = Ri * 0.46;
      var w = h * 2 / 3;
      var cabe = 2 * dist * Math.sin(Math.min(f.tam, Math.PI) / 2) * 0.8;
      if (w > cabe) { w = cabe; h = w * 1.5; }
      if (w >= 24 && f.im && f.im.complete && f.im.naturalWidth) {
        ctx.save();
        ctx.rotate(f.ini + f.tam / 2);
        ctx.translate(dist, 0);
        ctx.rotate(Math.PI / 2);
        var raio = Math.max(4, w * 0.08);
        ctx.beginPath();
        if (ctx.roundRect) { ctx.roundRect(-w / 2, -h / 2, w, h, raio); } else { ctx.rect(-w / 2, -h / 2, w, h); }
        ctx.save();
        ctx.clip();
        ctx.drawImage(f.im, -w / 2, -h / 2, w, h);
        ctx.restore();
        ctx.lineWidth = 3;
        ctx.strokeStyle = roleta.vencedor === f.carta ? "#2b1a28" : "rgba(248, 237, 216, .8)";
        ctx.stroke();
        ctx.restore();
      }
      if (roleta.vencedor && roleta.vencedor !== f.carta) {
        ctx.beginPath();
        ctx.moveTo(0, 0);
        ctx.arc(0, 0, Ri, f.ini, f.ini + f.tam);
        ctx.closePath();
        ctx.fillStyle = "rgba(14, 8, 22, .6)";
        ctx.fill();
      }
    });
    // divisórias douradas entre as fatias
    ctx.strokeStyle = "rgba(255, 201, 74, .75)";
    ctx.lineWidth = 3;
    roleta.fatias.forEach(function (f) {
      ctx.beginPath();
      ctx.moveTo(0, 0);
      ctx.lineTo(Math.cos(f.ini) * Ri, Math.sin(f.ini) * Ri);
      ctx.stroke();
    });
    ctx.restore();
    ctx.beginPath();
    ctx.arc(c, c, Ri, 0, Math.PI * 2);
    ctx.lineWidth = 5;
    ctx.strokeStyle = "#ffc94a";
    ctx.stroke();
    // miolo: interrogação antes, exclamação quando a roleta decide
    ctx.beginPath();
    ctx.arc(c, c, Ri * 0.17, 0, Math.PI * 2);
    ctx.fillStyle = "#160f22";
    ctx.fill();
    ctx.lineWidth = 5;
    ctx.strokeStyle = "#ffc94a";
    ctx.stroke();
    ctx.fillStyle = "#ffc94a";
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.font = "400 " + Math.round(Ri * 0.15) + "px Bungee, 'Arial Black', sans-serif";
    ctx.fillText(roleta.vencedor ? "!" : "?", c, c + Ri * 0.01);
  }

  function legendaRoleta() {
    var ul = el("ul", "mmm-Legenda");
    roleta.fatias.slice().sort(function (a, b) { return b.pct - a.pct; }).forEach(function (f) {
      var c = porId[f.carta];
      var li = el("li", "mmm-Leg" + (roleta.vencedor === f.carta ? " is-vence" : ""));
      li.dataset.carta = String(f.carta);
      li.appendChild(poster(c, ["w92", "w185"], "20px", "", "mmm-Leg-poster"));
      li.appendChild(el("span", null, c ? c.nome : ""));
      li.appendChild(el("b", null, f.pct + "%"));
      ul.appendChild(li);
    });
    return ul;
  }

  function telaRoleta() {
    var rol = estado.roleta || {};
    var s = tela === "roleta" ? mesa.firstChild : null;
    if (s && roleta) {
      var velho = s.querySelector(".mmm-RodapeJogo > :last-child");
      if (velho && !roleta.girando) { velho.replaceWith(botaoGirar()); }
      return;
    }
    var fatias = rol.fatias || [];
    s = secao("mmm-Final mmm-Roleta");
    var cab = el("div", "mmm-Final-cab");
    cab.appendChild(el("small", null, fatias.length + " finalistas · mais votos, fatia maior"));
    cab.appendChild(titulo1("A ROLETA DECIDE"));
    s.appendChild(cab);
    var area = el("div", "mmm-RoletaArea");
    var palco = el("div", "mmm-RoletaPalco");
    var ponteiro = el("div", "mmm-RoletaPonteiro");
    ponteiro.setAttribute("aria-hidden", "true");
    palco.appendChild(ponteiro);
    var cv = el("canvas", "mmm-RoletaCanvas");
    cv.width = 720;
    cv.height = 720;
    palco.appendChild(cv);
    area.appendChild(palco);
    s.appendChild(area);
    pararRoleta();
    roleta = montarRoleta(cv, fatias);
    cv.setAttribute("role", "img");
    cv.setAttribute("aria-label", "Roleta com " + fatias.length + " finalistas: " + roleta.fatias.slice().sort(function (a, b) { return b.pct - a.pct; })
      .map(function (f) { return (porId[f.carta] ? porId[f.carta].nome : "") + ", " + f.pct + "%"; }).join("; "));
    s.appendChild(legendaRoleta());
    var pe = el("div", "mmm-RodapeJogo is-centro");
    pe.appendChild(botaoGirar());
    s.appendChild(pe);
    mostrar("roleta", s);
    desenharRoleta();
    // lâmpadas correndo devagar enquanto ninguém gira
    if (!reduz.matches) {
      roleta.pisca = window.setInterval(function () {
        if (!roleta || roleta.girando || roleta.vencedor || tela !== "roleta") { return; }
        roleta.luz++;
        desenharRoleta();
      }, 420);
    }
  }

  function botaoGirar() {
    if (situacao() !== "PRONTO") { return el("p", "mmm-Sintonia", "Quem votou o baralho gira a roleta."); }
    var b = botao("mmm-JogoBotao mmm-JogoBotao--pri", ["Girar a roleta"], "girar");
    b.dataset.foco = "girar";
    if (roleta && roleta.pedido) {
      b.setAttribute("aria-disabled", "true");
      b.classList.add("is-disabled");
    }
    return b;
  }

  function fatiaNoPonteiro(rot) {
    var a = (((-Math.PI / 2 - rot) % (Math.PI * 2)) + Math.PI * 2) % (Math.PI * 2);
    for (var i = 0; i < roleta.fatias.length; i++) {
      var f = roleta.fatias[i];
      if (a >= f.ini && a < f.ini + f.tam) { return i; }
    }
    return -1;
  }

  // gira até a fatia e o ponto que o servidor sorteou: todos os aparelhos param no mesmo lugar
  function girarAte(vencedora, fracao, depois) {
    var alvo = roleta.fatias.filter(function (f) { return f.carta === vencedora; })[0];
    if (!alvo) {
      depois();
      return;
    }
    travada = true;
    pararRoleta();
    roleta.girando = true;
    var b = mesa.querySelector('[data-acao="girar"]');
    if (b) {
      b.setAttribute("aria-disabled", "true");
      b.classList.add("is-disabled");
    }
    var meio = alvo.ini + alvo.tam * (fracao === undefined || fracao === null ? 0.5 : Number(fracao));
    var final = -Math.PI / 2 - meio + Math.PI * 2 * 6;
    var acabar = function () {
      roleta.girando = false;
      roleta.girou = true;
      roleta.vencedor = alvo.carta;
      roleta.rot = final;
      mesa.querySelectorAll(".mmm-Leg").forEach(function (l) { l.classList.toggle("is-vence", Number(l.dataset.carta) === alvo.carta); });
      var c = porId[alvo.carta];
      anunciar("A roleta escolheu " + (c ? c.nome : "") + ".");
      mmm.som("match");
      desenharRoleta();
      var n = 0;
      var festa = reduz.matches ? null : window.setInterval(function () {
        roleta.luz++;
        desenharRoleta();
        if (++n > 8) { window.clearInterval(festa); }
      }, 110);
      window.setTimeout(function () {
        if (festa) { window.clearInterval(festa); }
        travada = false;
        depois();
      }, reduz.matches ? 400 : 1500);
    };
    if (reduz.matches) {
      roleta.rot = final;
      acabar();
      return;
    }
    var dur = 4600;
    var t0 = performance.now();
    var ini = roleta.rot % (Math.PI * 2);
    var ultima = fatiaNoPonteiro(ini);
    var passo = function (agora) {
      var p = Math.min(1, (agora - t0) / dur);
      var e = 1 - Math.pow(1 - p, 4);
      roleta.rot = ini + (final - ini) * e;
      roleta.luz = Math.floor(agora / (70 + p * 260));
      desenharRoleta();
      var f = fatiaNoPonteiro(roleta.rot);
      if (f !== ultima) {
        ultima = f;
        mmm.som("tique");
      }
      if (p < 1) { window.requestAnimationFrame(passo); } else { acabar(); }
    };
    window.requestAnimationFrame(passo);
  }

  /* ---------- ingresso ---------- */
  var FRASE = {
    UNICO: "Só um título agradou a todos. Fácil.",
    DUELOS: "Venceu nos duelos.",
    ROLETA: "A roleta decidiu, os votos deram o peso.",
    MINHA_VEZ: "A carta Minha Vez decidiu."
  };

  function frase() {
    var res = estado.resultado || {};
    if (res.modo === "MINHA_VEZ") {
      var quem = pessoas[estado.criador];
      return quem ? "Carta Minha Vez: " + quem.apelido + " escolheu." : FRASE.MINHA_VEZ;
    }
    if (res.modo === "UNICO" && estado.motivo === "SEM_MATCH") { return "Ninguém deu match, mas só um título ficou de pé."; }
    return FRASE[res.modo] || "";
  }

  function blocoOnde(c) {
    var b = el("section", "mmm-OndeBloco");
    b.setAttribute("aria-labelledby", "mmm-onde-titulo");
    var h = el("h2", null, "Onde assistir agora");
    h.id = "mmm-onde-titulo";
    b.appendChild(h);
    var hoje = estado.servicosSessao || [];
    var servicos = (c && c.servicos) || [];
    var assin = servicos.filter(function (s) { return s.categoria === "ASSINATURA"; });
    var seus = assin.filter(function (s) { return !hoje.length || hoje.indexOf(s.codigo) >= 0; });
    var outros = assin.filter(function (s) { return seus.indexOf(s) < 0; });
    var lojas = servicos.filter(function (s) { return s.categoria === "LOJA"; });
    var linha = function (s, sub, seu) {
      var d = el("div", "mmm-Servico" + (seu ? " is-seu" : ""));
      d.appendChild(mmm.imagem(s.logo, "logo", "34px", ""));
      var t = el("div", null, s.nome);
      t.appendChild(el("small", null, sub));
      d.appendChild(t);
      return d;
    };
    seus.forEach(function (s) { b.appendChild(linha(s, hoje.length ? "um dos serviços de hoje" : "na assinatura", true)); });
    outros.forEach(function (s) { b.appendChild(linha(s, "na assinatura", false)); });
    if (!assin.length || estado.aluguel === true) { lojas.forEach(function (s) { b.appendChild(linha(s, "aluguel ou compra", false)); }); }
    if (!servicos.length) { b.appendChild(el("p", null, "Não está em nenhum serviço agora.")); }
    var botoes = el("div", "mmm-Botoes");
    var assistir = el("span", "mmm-Assistir-espera", "Procurando onde assistir…");
    assistir.dataset.assistir = "esperando";
    botoes.appendChild(assistir);
    if (c && /^[A-Za-z0-9_-]{6,20}$/.test(c.trailer || "")) {
      botoes.appendChild(mmm.linkExterno("mmm-JogoBotao", "https://www.youtube.com/watch?v=" + c.trailer, "Trailer"));
    }
    b.appendChild(botoes);
    var credito = el("p", "mmm-Credito", "Dados de onde assistir: JustWatch.");
    credito.dataset.credito = "";
    b.appendChild(credito);
    return b;
  }

  // o link sai do servidor (MMM_ASSISTIR): deep link do Streaming Availability quando há, senão a página do
  // TMDB; a demo só lê o que já está guardado. O link vira um <a> com target _blank (abrir depois de um pedido bloquearia).
  // Os aparelhos do sofá chegam ao ingresso juntos: no 429 o pedido volta sozinho, com o recuo do motor
  function pedirAssistir(c, bloco) {
    var lugar = bloco.querySelector("[data-assistir]");
    var credito = bloco.querySelector("[data-credito]");
    mmm.jogo.pedir("MMM_ASSISTIR", { x01: String(c.titulo), x02: String(SESSAO) }, 3).then(function (r) {
      if (!/^https:\/\//.test(r.url || "")) {
        lugar.replaceWith(el("p", "mmm-Assistir-sem", "Não achamos um link para abrir agora. Procure pelo nome no app do serviço."));
        return;
      }
      var sa = r.origem === "SA";
      var a = mmm.linkExterno("mmm-JogoBotao mmm-JogoBotao--pri mmm-Assistir",
        r.url, sa ? "Assistir" + (r.nome ? " na " + r.nome : "") : "Ver onde assistir");
      a.insertBefore(icone("play"), a.firstChild);
      a.dataset.origem = r.origem || "";
      lugar.replaceWith(a);
      if (sa) {
        credito.appendChild(document.createTextNode(" Links: Streaming Availability."));
      } else {
        credito.textContent = "Sem link direto do serviço agora: o botão abre a página do título no TMDB, com os dados de onde assistir da JustWatch.";
      }
    }, function (e) {
      lugar.replaceWith(el("p", "mmm-Assistir-sem", (e && e.recusado && e.message) || "Não deu para buscar o link agora. Procure pelo nome no app do serviço."));
    });
  }

  function blocoJustica(c) {
    var res = estado.resultado || {};
    var b = el("section", "mmm-Justica");
    b.setAttribute("aria-labelledby", "mmm-justica-titulo");
    var h = el("h2", null, "Placar de justiça");
    h.id = "mmm-justica-titulo";
    b.appendChild(h);
    var placar = res.placar || [];
    if (res.modo === "MINHA_VEZ" || !placar.length) {
      b.appendChild(el("p", null, "A carta Minha Vez decidiu: o placar fica como estava."));
      return b;
    }
    var rc = (estado.cartas || []).filter(function (x) { return c && x.id === c.id; })[0] || {};
    var votos = rc.votos || {};
    var queriam = placar.filter(function (p) { return votos[p.id] === "QUERO" || votos[p.id] === "SUPER"; });
    var supers = placar.filter(function (p) { return votos[p.id] === "SUPER"; });
    var cederam = placar.filter(function (p) { return p.cedeu === true; });
    var apelidos = function (l) { return nomes(l.map(function (p) { return p.apelido; })); };
    var texto = supers.length ? "O super de " + apelidos(supers) + " chegou ao fim."
      : queriam.length === placar.length ? "Todo mundo queria esse. Ninguém cedeu hoje."
        : queriam.length ? apelidos(queriam) + (queriam.length > 1 ? " queriam esse." : " queria esse.") : "";
    if (cederam.length && !(queriam.length === placar.length)) {
      texto += (texto ? " " : "") + apelidos(cederam) + (cederam.length > 1 ? " cederam desta vez." : " cedeu desta vez.");
    }
    if (texto) { b.appendChild(el("p", null, texto)); }
    var ul = el("ul", "mmm-Placar");
    placar.forEach(function (p) {
      var n = Number(p.seguidas) || 0;
      var li = el("li", "mmm-Placar-item" + (p.ganhouCarta === true ? " is-carta" : ""));
      li.appendChild(avatar(p, true));
      li.appendChild(document.createTextNode(p.apelido + " · cedeu " + n + (n === 1 ? " vez seguida" : " vezes seguidas")));
      ul.appendChild(li);
    });
    b.appendChild(ul);
    var ganhou = placar.filter(function (p) { return p.ganhouCarta === true; });
    if (ganhou.length) {
      ganhou.forEach(function (p) {
        var cv = el("p", "mmm-CartaVez");
        cv.appendChild(icone("estrela"));
        cv.appendChild(document.createTextNode(p.apelido + " ganhou a carta Minha Vez"));
        b.appendChild(cv);
      });
    } else {
      b.appendChild(el("p", "mmm-Justica-regra", "Quem ceder 3 vezes seguidas ganha a carta Minha Vez: escolhe direto numa próxima sessão."));
    }
    return b;
  }

  function telaIngresso() {
    if (tela === "ingresso" && ingresso === estado.sessao) { return; }
    var res = estado.resultado || {};
    var c = porTitulo[res.titulo];
    var s = secao("mmm-TelaIngresso");
    var wrap = el("div", "mmm-Ingresso-wrap");
    var cab = el("div", "mmm-Ingresso-cab");
    cab.appendChild(titulo1("DEU MATCH!"));
    cab.appendChild(el("p", null, frase()));
    wrap.appendChild(cab);

    var t = el("div", "mmm-Ingresso");
    var topo = el("div", "mmm-Ingresso-topo");
    topo.appendChild(poster(c, ["w185", "w342"], "96px", "", "mmm-Ingresso-poster"));
    var dados = el("div", "mmm-Ingresso-dados");
    dados.appendChild(el("div", "mmm-Ingresso-rotulo", (GRUPO ? GRUPO + " · " : "") + (c && c.tipo === "SERIE" ? "série" : "filme")));
    dados.appendChild(el("div", "mmm-Ingresso-titulo", c ? c.nome : ""));
    if (c) { dados.appendChild(linhaMeta(c)); }
    topo.appendChild(dados);
    t.appendChild(topo);
    var campos = el("div", "mmm-Ingresso-campos");
    [["Começa", horaIso(res.inicio) || "—"], ["Termina", res.fim ? horaIso(res.fim) || "—" : "Quando cansar"], ["Sala", "Sofá"]].forEach(function (x) {
      var d = el("div");
      d.appendChild(el("span", "mmm-Ingresso-rotulo", x[0]));
      d.appendChild(el("b", null, x[1]));
      campos.appendChild(d);
    });
    t.appendChild(campos);
    var picote = el("div", "mmm-Ingresso-picote");
    picote.setAttribute("aria-hidden", "true");
    t.appendChild(picote);
    var canhoto = el("div", "mmm-Ingresso-canhoto");
    var plateia = el("div");
    plateia.appendChild(el("div", "mmm-Ingresso-rotulo", "Na plateia"));
    var avs = el("div", "mmm-Avatares");
    var quem = (estado.presencas || []).filter(function (p) { return p.situacao !== "SAIU"; });
    quem.forEach(function (p) { avs.appendChild(avatar(p)); });
    avs.setAttribute("role", "img");
    avs.setAttribute("aria-label", nomes(quem.map(function (p) { return p.apelido; })));
    plateia.appendChild(avs);
    canhoto.appendChild(plateia);
    canhoto.appendChild(el("div", "mmm-Ingresso-codigo", "Nº " + String(SESSAO).padStart(8, "0")));
    t.appendChild(canhoto);
    wrap.appendChild(t);
    // o ingresso fica guardado: quem estava na plateia rasga quando quiser, aqui (mmm-ingresso.js) ou na lista, e dá a nota
    var dica = el("p", "mmm-Ingresso-dica", DEMO ? "Na lista do grupo, rasgue o ingresso e dê a sua nota."
      : "Depois do filme, rasgue o ingresso na lista do grupo e dê a sua nota.");
    dica.setAttribute("aria-live", "polite");
    wrap.appendChild(dica);
    if (mmm.ingresso && mmm.ingresso.anexar) { mmm.ingresso.anexar(t, SESSAO, dica); }

    var onde = blocoOnde(c);
    wrap.appendChild(onde);
    wrap.appendChild(blocoJustica(c));
    var botoes = el("div", "mmm-Botoes");
    var volta = link("mmm-JogoBotao", URL_INICIO, [icone("voltar"), "Voltar à lista"]);
    botoes.appendChild(volta);
    botoes.appendChild(link("mmm-JogoBotao mmm-JogoBotao--pri", URL_ABERTURA, ["Nova sessão"]));
    wrap.appendChild(botoes);
    s.appendChild(wrap);
    var primeira = ingresso !== estado.sessao;
    ingresso = estado.sessao;
    mostrar("ingresso", s);
    if (c) { pedirAssistir(c, onde); }
    anunciar("Deu match: " + (c ? c.nome : "") + ".");
    if (primeira) {
      mmm.som("match");
      // o navegador recusa vibrar antes do primeiro toque na página (ingresso aberto direto, pelo letreiro ou pelo aviso)
      if (!navigator.userActivation || navigator.userActivation.hasBeenActive) { mmm.vibrar([20, 40, 20]); }
      confete();
    }
  }

  /* ---------- confete (canvas por cima de tudo, sem nada com movimento reduzido) ---------- */
  function confete() {
    if (reduz.matches) { return; }
    var cv = el("canvas", "mmm-Confete");
    cv.setAttribute("aria-hidden", "true");
    document.body.appendChild(cv);
    var ctx = cv.getContext("2d");
    var dpr = Math.min(2, window.devicePixelRatio || 1);
    var W = window.innerWidth;
    var H = window.innerHeight;
    cv.width = W * dpr;
    cv.height = H * dpr;
    var cores = ["#ffc94a", "#f0566a", "#4fd6a6", "#72d4ff", "#ff94b8", "#f8edd8"];
    var ps = [];
    for (var i = 0; i < 140; i++) {
      ps.push({ x: W * (0.2 + Math.random() * 0.6), y: H * 0.35, vx: (Math.random() - 0.5) * 11, vy: -Math.random() * 13 - 4,
        r: 4 + Math.random() * 5, a: Math.random() * 6, va: (Math.random() - 0.5) * 0.3, cor: cores[Math.floor(Math.random() * cores.length)] });
    }
    var t0 = performance.now();
    var passo = function (agora) {
      var vivo = agora - t0 < 2600;
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      ctx.clearRect(0, 0, W, H);
      ps.forEach(function (p) {
        p.vy += 0.35;
        p.vx *= 0.99;
        p.x += p.vx;
        p.y += p.vy;
        p.a += p.va;
        ctx.save();
        ctx.translate(p.x, p.y);
        ctx.rotate(p.a);
        ctx.fillStyle = p.cor;
        ctx.fillRect(-p.r, -p.r / 2, p.r * 2, p.r);
        ctx.restore();
      });
      if (vivo) { window.requestAnimationFrame(passo); } else { cv.remove(); }
    };
    window.requestAnimationFrame(passo);
  }

  /* ---------- fim sem filme: cancelada, abandonada ---------- */
  function telaFim() {
    var s = secao("mmm-Centro mmm-Fim");
    var cancelada = estado.status === "CANCELADA";
    s.appendChild(titulo1(cancelada ? "SESSÃO ENCERRADA" : "A SESSÃO FICOU PARADA"));
    s.appendChild(el("p", "mmm-Centro-texto", cancelada
      ? "Quem convocou encerrou a sessão, ou não sobrou ninguém no sofá. A lista continua como estava."
      : "Ninguém mexeu na sessão por 3 horas e ela foi encerrada. A lista continua como estava."));
    var b = el("div", "mmm-Botoes");
    b.appendChild(link("mmm-JogoBotao", URL_INICIO, [icone("voltar"), "Voltar à lista"]));
    b.appendChild(link("mmm-JogoBotao mmm-JogoBotao--pri", URL_ABERTURA, ["Nova sessão"]));
    s.appendChild(b);
    mostrar("fim", s);
  }

  function telaCarregando(texto) {
    var s = secao("mmm-Centro mmm-Carregando");
    s.appendChild(titulo1(texto || "Abrindo a sessão…", true));
    s.appendChild(el("p", "mmm-Credito", texto || "Abrindo a sessão…"));
    mostrar("carregando", s);
  }

  /* ---------- encerrar pelo cabeçalho: quem convocou (ou quem ficou, se quem convocou saiu) em qualquer tela aberta ---------- */
  var botaoEncerrar = null;
  function podeEncerrar() {
    if (!estado || ["VOTANDO", "REVELADA", "FINAL"].indexOf(estado.status) < 0) { return false; }
    var criadorSaiu = (estado.presencas || []).some(function (p) { return p.id === estado.criador && p.situacao === "SAIU"; });
    return estado.criador === estado.eu.id || (criadorSaiu && estou());
  }
  function atualizarEncerrar() {
    var topo = raiz.querySelector(".mmm-Topo");
    if (!topo) { return; }
    if (!botaoEncerrar) {
      botaoEncerrar = botao("mmm-BotaoIcone mmm-BotaoIcone--perigo", [icone("x")], "cancelar");
      botaoEncerrar.setAttribute("aria-label", "Encerrar a sessão");
      botaoEncerrar.title = "Encerrar a sessão";
      topo.insertBefore(botaoEncerrar, topo.querySelector(".js-mmm-som"));
    }
    // na espera o encerrar já está entre as ações da tela
    botaoEncerrar.hidden = !podeEncerrar() || tela === "espera";
  }

  /* ---------- desenho: uma tela por estado ---------- */
  function desenhar() {
    if (!estado || !cartas || travada) { return; }
    var r = estado;
    pessoas = {};
    (r.presencas || []).forEach(function (p) { pessoas[p.id] = p; });
    window.setTimeout(atualizarEncerrar, 0);

    // o duelo que fechou (no meu voto ou no de outro aparelho) aparece antes do próximo ou do ingresso
    var u = r.duelos && r.duelos.ultimo;
    if (ultimoMostrado === undefined) {
      ultimoMostrado = u ? u.id : null;
    } else if (u && u.id !== ultimoMostrado && (tela === "duelo" || tela === "carregando")) {
      ultimoMostrado = u.id;
      animarResultado(u, desenhar);
      return;
    } else if (u) {
      ultimoMostrado = u.id;
    }

    switch (r.status) {
    case "VOTANDO":
      var sit = situacao();
      if (sit === "CONVIDADO" || sit === "VOTANDO") {
        var mudou = sincronizarBaralho();
        if (deck.posicao < ordem().length) {
          telaBaralho(mudou || tela !== "baralho");
          return;
        }
      }
      telaEspera();
      return;
    case "REVELADA":
    case "SEM_RESULTADO":
      telaRevelacao();
      return;
    case "FINAL":
      if (r.final === "ROLETA") { telaRoleta(); } else { telaDuelo(); }
      return;
    case "ENCERRADA":
      // quem estava na roleta vê o giro até o resultado que o servidor sorteou, como quem girou
      if (tela === "roleta" && roleta && !roleta.girou && r.roleta && r.roleta.vencedora) {
        girarAte(r.roleta.vencedora, r.roleta.fracao, desenhar);
        return;
      }
      telaIngresso();
      return;
    default:
      telaFim();
    }
  }

  /* ---------- eventos do motor ---------- */
  raiz.addEventListener("mmmestado", function (e) {
    var anterior = estado;
    estado = e.detail;
    estadoEm = Date.now();
    var seg = Number(estado.relogio) || 0;
    if (seg !== relogio.seg) {
      relogio.seg = seg;
      if (seg) { lerRelogio(); }
    }
    if (estado.status !== "VOTANDO") { esquecerRelogio(); }
    if (anterior && anterior.status !== estado.status) { deck.iniciado = false; }
    // durante a saída da carta o estado espera o fim da animação
    if (deck.animando) {
      estadoNaFila = true;
      return;
    }
    desenhar();
  });

  raiz.addEventListener("mmmrecusado", function (e) {
    var j = e.detail && e.detail.jogada;
    // a jogada recusada sai da fila e o motor pede o estado inteiro: a tela redesenha a partir dele
    if (j && (j.a === "VOTAR" || j.a === "DESFAZER")) { deck.iniciado = false; }
    // grupo trocado noutro aparelho: não vem estado novo (o motor parou), então a carta volta pelo que já se tem
    if (e.detail && e.detail.erro === "grupo") {
      if (deck.animando) { estadoNaFila = true; } else { desenhar(); }
      return;
    }
    if (j && j.a === "GIRAR" && roleta) {
      roleta.pedido = false;
      telaRoleta();
    }
  });

  var pausa = null;
  raiz.addEventListener("mmmpausa", function () {
    if (pausa) { return; }
    pausa = el("div", "mmm-Pausa");
    pausa.appendChild(el("p", null, "A sessão ficou meia hora sem mudança e parou de atualizar."));
    var b = botao("mmm-JogoBotao mmm-JogoBotao--pri", ["Atualizar"], "retomar");
    pausa.appendChild(b);
    raiz.insertBefore(pausa, mesa);
  });

  /* ---------- toques e teclas ---------- */
  function confirmar(texto, rotulo, estilo, fn) {
    // unsafe: o APEX escapa o texto, que leva o apelido (dado de quem usa o app)
    apex.message.confirm(texto, function (ok) { if (ok) { fn(); } },
      { unsafe: true, style: estilo || "information", confirmLabel: rotulo, cancelLabel: "Cancelar" });
  }

  raiz.addEventListener("click", function (e) {
    var b = e.target.closest("button");
    if (!b || !raiz.contains(b)) { return; }
    if (b.dataset.voto) {
      if (b.getAttribute("aria-disabled") === "true") {
        mmm.toast(b.dataset.voto === "SUPER" ? "Você já usou o seu super." : "Você já usou o seu veto.");
        return;
      }
      votar(b.dataset.voto);
      return;
    }
    if (b.dataset.lado) {
      var atual = estado && estado.duelos && estado.duelos.atual;
      if (!atual || b.getAttribute("aria-disabled") === "true" || travada) { return; }
      if (atual.meuVoto === b.dataset.lado) { return; }
      mesa.querySelectorAll(".mmm-Lado").forEach(function (x) {
        var meu = x === b;
        x.classList.toggle("is-escolhido", meu);
        x.setAttribute("aria-pressed", String(meu));
      });
      mmm.som("tique");
      mmm.jogo.votarDuelo(atual.id, b.dataset.lado);
      return;
    }
    var acao = b.dataset.acao;
    if (!acao) { return; }
    if (b.getAttribute("aria-disabled") === "true") {
      if (acao === "cutucar") { mmm.toast("Espere um minuto para cutucar de novo."); }
      if (acao === "desfazer") { desfazer(); }
      return;
    }
    switch (acao) {
    case "desfazer":
      desfazer();
      break;
    case "virar":
      virar(b.closest(".mmm-Carta"));
      break;
    case "avancar":
      b.setAttribute("aria-disabled", "true");
      b.classList.add("is-disabled");
      mmm.jogo.jogar("AVANCAR");
      break;
    case "girar":
      roleta.pedido = true;
      b.setAttribute("aria-disabled", "true");
      b.classList.add("is-disabled");
      mmm.jogo.jogar("GIRAR");
      break;
    case "cutucar":
      cutucadaAte = Date.now() + 60000;
      b.setAttribute("aria-disabled", "true");
      b.classList.add("is-disabled");
      mmm.jogo.jogar("CUTUCAR");
      mmm.toast("Cutucada enviada para quem falta.");
      window.setTimeout(function () { if (estado) { desenhar(); } }, 60500);
      break;
    case "remover":
      confirmar("Tirar " + (b.dataset.nome || "esta pessoa") + " do sofá? Quem ficou segue sem esperar.", "Tirar do sofá", "danger", function () {
        mmm.jogo.jogar("REMOVER", b.dataset.membro);
      });
      break;
    case "sair":
      confirmar(humanosNoSofa().length <= 1 ? "Você é a única pessoa no sofá: sair encerra a sessão. Sair mesmo assim?"
        : estado.status === "VOTANDO" ? "Sair do sofá? Seus votos ficam guardados e dá para voltar enquanto a turma vota."
          : "Sair do sofá? Você continua vendo a sessão, mas sem votar.", "Sair do sofá", "warning", function () {
        mmm.jogo.jogar("SAIR");
      });
      break;
    case "entrar":
      mmm.jogo.jogar("ENTRAR");
      break;
    case "cancelar":
      confirmar("Encerrar a sessão para todo mundo? Ninguém escolhe nada desta vez.", "Encerrar", "danger", function () {
        mmm.jogo.jogar("CANCELAR");
      });
      break;
    case "retomar":
      if (pausa) { pausa.remove(); }
      pausa = null;
      mmm.jogo.retomar();
      break;
    }
  });

  // a confirmação do APEX é fixa na tela (offsetParent nulo): aberta é a que ocupa lugar
  function dialogoAberto() {
    return Array.prototype.some.call(document.querySelectorAll(".ui-dialog"), function (d) { return d.getClientRects().length > 0; });
  }

  document.addEventListener("keydown", function (e) {
    if (tela !== "baralho" || dialogoAberto() || relogio.saindo || e.ctrlKey || e.metaKey || e.altKey) { return; }
    if (e.target.closest && e.target.closest("input, textarea, select")) { return; }
    var mapa = { ArrowRight: "QUERO", ArrowLeft: "NAO", s: "SUPER", S: "SUPER", v: "VETO", V: "VETO" };
    if (mapa[e.key]) {
      e.preventDefault();
      votar(mapa[e.key]);
    } else if (e.key === " " && !(e.target.closest && e.target.closest("button, a"))) {
      e.preventDefault();
      virar(cartaDoTopo());
    } else if (e.key === "Backspace") {
      e.preventDefault();
      desfazer();
    }
  });

  /* ---------- começo: as cartas vêm uma vez (o ENTRAR do motor já está na fila) ---------- */
  telaCarregando();
  function carregarCartas() {
    mmm.jogo.cartas().then(function (r) {
      guardarCartas(r.cartas);
      desenhar();
    }, function (e) {
      var s = secao("mmm-Centro mmm-Fim");
      s.appendChild(titulo1("NÃO DEU PARA ABRIR"));
      s.appendChild(el("p", "mmm-Centro-texto", (e && e.recusado && e.message) || "As cartas não chegaram. Confira a internet e tente de novo."));
      var b = el("div", "mmm-Botoes");
      var de = botao("mmm-JogoBotao mmm-JogoBotao--pri", ["Tentar de novo"]);
      de.addEventListener("click", function () {
        telaCarregando();
        carregarCartas();
      });
      b.appendChild(de);
      b.appendChild(link("mmm-JogoBotao", URL_INICIO, ["Voltar à lista"]));
      s.appendChild(b);
      mostrar("erro", s);
    });
  }
  carregarCartas();
});
