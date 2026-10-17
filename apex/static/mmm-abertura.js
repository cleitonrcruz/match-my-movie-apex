// Match My Movie: página 20, Hora do Cinema (#APP_FILES#mmm-abertura.js?v=N nas File URLs, depois do mmm-jogo.js).
// As perguntas da abertura montadas em DOM, com o texto sempre por textContent; quem
// conta e quem dá as cartas é o servidor (mmm.jogo.contar e mmm.jogo.darCartas: MMM_JOGO com CONTAGENS e CRIAR).
// APEX_JSON omite a chave com valor nulo: dica, ícone e logo podem não vir.
apex.jQuery(function () {
  "use strict";

  var mmm = window.mmm;
  var raiz = document.getElementById("mmm-abertura");
  if (!mmm || !mmm.jogo || !mmm.jogo.darCartas || !raiz) { return; }

  var el = mmm.el;
  var SVG = "http://www.w3.org/2000/svg";
  var MAX_CARTAS = 15;
  var contagem = document.getElementById("mmm-abertura-contagem");
  var motivoEl = document.getElementById("mmm-abertura-motivo");
  var botaoDar = document.getElementById("mmm-dar-cartas");

  function lerJson(item, padrao) {
    try {
      var v = JSON.parse($v(item) || "null");
      return v === null ? padrao : v;
    } catch (e) {
      return padrao;
    }
  }

  // o servidor manda o que a tela pode oferecer: quem pode ir para o sofá, o que o grupo assina e quantos de cada tipo
  var membros = lerJson("P20_MEMBROS", []);
  var qtdTipo = lerJson("P20_QTD_TIPO", {});
  var servicosGrupo = String($v("P20_SERVICOS_GRUPO") || "").split(":").filter(Boolean);

  // sem pressa e maratona vão como nulo (o servidor só aceita 105 e 150, 1 e 3)
  var TEMPOS = {
    FILME: [{ v: 105, rotulo: "Até 1h45", sub: "filme curto" }, { v: 150, rotulo: "Até 2h30", sub: "a maioria" }, { v: null, rotulo: "Sem pressa", sub: "tudo vale" }],
    SERIE: [{ v: 1, rotulo: "1 episódio", sub: "e cama" }, { v: 3, rotulo: "2 ou 3", sub: "episódios" }, { v: null, rotulo: "Maratona", sub: "até cansar" }]
  };
  var RECORTES = [
    { k: "nacional", nome: "Nacional", icone: "bandeira" },
    { k: "aclamado", nome: "Aclamados", icone: "trofeu" },
    { k: "lancamento", nome: "Lançamentos", icone: "brilho" },
    { k: "classico", nome: "Clássicos", icone: "rolo" }
  ];
  var REGRAS = [{ v: "TODOS", rotulo: "Todos querem", sub: "mais exigente" }, { v: "MAIORIA", rotulo: "A maioria quer", sub: "mais fácil" }];
  var FINAIS = [{ v: "DUELOS", rotulo: "Duelos", sub: "mata-mata" }, { v: "ROLETA", rotulo: "Roleta", sub: "pesa os votos" }];
  // relógio de cada carta no baralho (20 s marcado de início); sem relógio vai como nulo
  var RELOGIOS = [{ v: null, rotulo: "Sem relógio", sub: "sem pressa" }, { v: 10, rotulo: "10 s", sub: "rapidinho" },
    { v: 20, rotulo: "20 s", sub: "o normal" }, { v: 30, rotulo: "30 s", sub: "com calma" }];

  var eu = membros.filter(function (m) { return m.eu === true; })[0] || null;
  var estado = {
    tipo: null,
    tempo: { FILME: 150, SERIE: 1 },
    climas: new Set(),
    recortes: new Set(),
    servicos: new Set(),
    aluguel: false,
    crianca: false,
    regra: "TODOS",
    final: "DUELOS",
    relogio: 20,
    // todo mundo começa no sofá; quem convoca não sai (o servidor sempre o põe)
    presentes: new Set(membros.map(function (m) { return Number(m.id); }))
  };
  var resposta = null;       // última contagem que voltou do servidor
  var pedido = 0;            // só a contagem do último pedido desenha
  var contando = false;
  var falhou = false;        // a contagem não voltou (rede ou recusa): o rodapé oferece contar de novo
  var dando = false;

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

  function botao(classe, filhos, dados) {
    var b = el("button", classe);
    b.type = "button";
    (filhos || []).forEach(function (f) { if (f) { b.appendChild(typeof f === "string" ? document.createTextNode(f) : f); } });
    Object.keys(dados || {}).forEach(function (k) { b.dataset[k] = dados[k]; });
    return b;
  }

  function apertado(b, sim) { b.setAttribute("aria-pressed", String(!!sim)); }

  function pergunta(id, titulo, dica) {
    var s = el("section", "mmm-Pergunta");
    s.id = "mmm-pergunta-" + id;
    var h = el("h2", "mmm-Pergunta-titulo");
    h.id = "mmm-pergunta-" + id + "-titulo";
    h.appendChild(el("span", "mmm-Pergunta-texto", titulo));
    if (dica !== undefined) {
      var d = el("span", "mmm-Pergunta-dica", dica);
      h.appendChild(d);
    }
    s.setAttribute("aria-labelledby", h.id);
    s.appendChild(h);
    return s;
  }

  function grupo(classe, rotuloId) {
    var g = el("div", classe);
    g.setAttribute("role", "group");
    if (rotuloId) { g.setAttribute("aria-labelledby", rotuloId); }
    return g;
  }

  function segmento(opcoes, chave, rotuloId) {
    var g = grupo("mmm-Segmento", rotuloId);
    opcoes.forEach(function (o) {
      var b = botao("mmm-Segmento-opcao", [o.rotulo, el("small", null, o.sub)], { [chave]: o.v === null ? "" : String(o.v) });
      g.appendChild(b);
    });
    return g;
  }

  function chave(id, titulo, sub) {
    var c = el("div", "mmm-Chave");
    var t = el("div", "mmm-Chave-texto");
    var s = el("strong", null, titulo);
    s.id = "mmm-chave-" + id;
    t.appendChild(s);
    t.appendChild(el("span", null, sub));
    var b = botao("mmm-Interruptor", [], { chave: id });
    b.setAttribute("role", "switch");
    b.setAttribute("aria-checked", "false");
    b.setAttribute("aria-labelledby", s.id);
    c.appendChild(t);
    c.appendChild(b);
    return c;
  }

  /* ---------- hora da sessão, no fuso de Brasília (o ingresso usa a mesma conta do servidor) ---------- */
  var RELOGIO = new Intl.DateTimeFormat("pt-BR", { timeZone: "America/Sao_Paulo", hour: "2-digit", minute: "2-digit", hourCycle: "h23" });
  function minutosAgora() {
    var p = {};
    RELOGIO.formatToParts(new Date()).forEach(function (x) { p[x.type] = x.value; });
    return Number(p.hour) * 60 + Number(p.minute);
  }
  function hhmm(min) {
    var m = ((min % 1440) + 1440) % 1440;
    return String(Math.floor(m / 60)).padStart(2, "0") + "h" + String(m % 60).padStart(2, "0");
  }
  // próximo múltiplo de 5 minutos com pelo menos 5 de folga (MMM_PKG_JOGO.finalizar)
  function inicioSessao() {
    var agora = minutosAgora();
    var h = Math.floor(agora / 60) * 60;
    return h + Math.ceil((agora - h + 5) / 5) * 5;
  }

  /* ---------- montagem ---------- */
  var sub = el("p", "mmm-Abertura-sub", "Poucas perguntas e as cartas saem da lista do grupo.");

  // 1. filme ou série, com o "N na lista" antes de escolher
  var pTipo = pergunta("tipo", "O que vai ser hoje?");
  var tipos = grupo("mmm-Tipos", "mmm-pergunta-tipo-titulo");
  var nFilme = Number(qtdTipo.filme) || 0;
  var nSerie = Number(qtdTipo.serie) || 0;
  [["FILME", "Filme", "rolo", nFilme], ["SERIE", "Série", "tv", nSerie]].forEach(function (t) {
    var texto = el("span", "mmm-Tipo-texto");
    texto.appendChild(el("b", null, t[1]));
    texto.appendChild(el("small", null, t[3] + " na lista"));
    tipos.appendChild(botao("mmm-Tipo", [icone(t[2]), texto], { tipo: t[0] }));
  });
  pTipo.appendChild(tipos);

  // 2. quem está no sofá (os simulados da demo vêm marcados)
  var pSofa = pergunta("sofa", "Quem está no sofá?");
  var sofa = grupo("mmm-Opcoes", "mmm-pergunta-sofa-titulo");
  membros.forEach(function (m) {
    var nome = el("span", "mmm-Pessoa-nome", m.apelido);
    var b = botao("mmm-Pessoa", [mmm.avatar(m.apelido, m.cor), nome], { membro: String(m.id) });
    if (m.eu === true) {
      // na demo o apelido já é "Você"
      if (!/^voc[eê]$/i.test(String(m.apelido || "").trim())) { b.appendChild(el("small", "mmm-Pessoa-marca", "você")); }
      // quem convoca está sempre no sofá: o botão fica com o foco, mas não muda
      b.setAttribute("aria-disabled", "true");
      b.classList.add("is-fixo");
    } else if (m.robo === true) {
      b.appendChild(el("small", "mmm-Pessoa-marca", "simulado"));
    }
    sofa.appendChild(b);
  });
  pSofa.appendChild(sofa);
  // sozinho também dá: o aviso só conta como fica
  var notaSofa = el("p", "mmm-Pergunta-nota", membros.length > 1 ? "Só você no sofá: as cartas e a escolha ficam com você." :
    "Só você no grupo por enquanto: as cartas e a escolha ficam com você. Para jogar em turma, convide alguém em Membros e convite.");
  notaSofa.hidden = true;
  pSofa.appendChild(notaSofa);

  // 3. tempo (o rótulo e as opções mudam com o tipo)
  var pTempo = pergunta("tempo", "Quanto tempo vocês têm?", "");
  var dicaTempo = pTempo.querySelector(".mmm-Pergunta-dica");
  var tempo = grupo("mmm-Segmento", "mmm-pergunta-tempo-titulo");
  pTempo.appendChild(tempo);

  // 4. clima, com a contagem de cada um (MMM_CLIMA: clima novo aparece sem mexer aqui)
  var pClima = pergunta("clima", "Qual o clima?", "pode marcar mais de um");
  var climas = grupo("mmm-Climas", "mmm-pergunta-clima-titulo");
  pClima.appendChild(climas);

  // 5. recortes
  var pRecorte = pergunta("recorte", "Algum recorte?", "opcional");
  var recortes = grupo("mmm-Opcoes", "mmm-pergunta-recorte-titulo");
  RECORTES.forEach(function (r) {
    recortes.appendChild(botao("mmm-Opcao", [icone(r.icone), r.nome, el("span", "mmm-Opcao-sub")], { recorte: r.k }));
  });
  pRecorte.appendChild(recortes);

  // 6. onde, com os serviços que o grupo assina já marcados, e o aluguel
  var pOnde = pergunta("onde", "Onde vamos assistir?");
  var onde = grupo("mmm-Opcoes", "mmm-pergunta-onde-titulo");
  pOnde.appendChild(onde);
  pOnde.appendChild(chave("aluguel", "Aluguel também vale", "Google Play, loja da Apple, aluguel na Amazon"));

  // 7. criança
  var pCrianca = el("section", "mmm-Pergunta");
  pCrianca.id = "mmm-pergunta-crianca";
  pCrianca.appendChild(chave("crianca", "Tem criança no sofá", "Só classificação Livre, 10 e 12 anos"));

  // 8. relógio por carta (só no baralho: os duelos da final não têm relógio)
  var pRelogio = pergunta("relogio", "Relógio por carta");
  pRelogio.appendChild(segmento(RELOGIOS, "relogio", "mmm-pergunta-relogio-titulo"));
  pRelogio.appendChild(el("p", "mmm-Pergunta-nota", "Cada um tem esse tempo em cada carta. Se acabar, a carta conta como Não. Os duelos da final não têm relógio."));

  // 9. regra e 10. final
  var pRegra = pergunta("regra", "Quando dá match?");
  pRegra.appendChild(segmento(REGRAS, "regra", "mmm-pergunta-regra-titulo"));
  var pFinal = pergunta("final", "Como é a final?");
  pFinal.appendChild(segmento(FINAIS, "final", "mmm-pergunta-final-titulo"));

  var depoisDoTipo = [pSofa, pTempo, pClima, pRecorte, pOnde, pCrianca, pRelogio, pRegra, pFinal];
  raiz.textContent = "";
  [sub, pTipo].concat(depoisDoTipo).forEach(function (p) { raiz.appendChild(p); });

  /* ---------- desenho do estado ---------- */
  function desenharTempo() {
    var t = estado.tipo;
    pTempo.querySelector(".mmm-Pergunta-texto").textContent = t === "SERIE" ? "Quantos episódios hoje?" : "Quanto tempo vocês têm?";
    tempo.textContent = "";
    if (!t) { return; }
    TEMPOS[t].forEach(function (o) {
      var b = botao("mmm-Segmento-opcao", [o.rotulo, el("small", null, o.sub)], { tempo: o.v === null ? "" : String(o.v) });
      apertado(b, estado.tempo[t] === o.v);
      tempo.appendChild(b);
    });
    var ini = inicioSessao();
    var lim = estado.tempo.FILME;
    dicaTempo.textContent = t === "FILME" && lim ? "começando às " + hhmm(ini) + ", termina até " + hhmm(ini + lim) : "começando às " + hhmm(ini);
  }

  function desenharEscolhas() {
    tipos.querySelectorAll("[data-tipo]").forEach(function (b) { apertado(b, b.dataset.tipo === estado.tipo); });
    depoisDoTipo.forEach(function (p) { p.hidden = !estado.tipo; });
    sofa.querySelectorAll("[data-membro]").forEach(function (b) { apertado(b, estado.presentes.has(Number(b.dataset.membro))); });
    notaSofa.hidden = estado.presentes.size !== 1;
    climas.querySelectorAll("[data-clima]").forEach(function (b) { apertado(b, estado.climas.has(b.dataset.clima)); });
    recortes.querySelectorAll("[data-recorte]").forEach(function (b) { apertado(b, estado.recortes.has(b.dataset.recorte)); });
    onde.querySelectorAll("[data-servico]").forEach(function (b) {
      apertado(b, b.dataset.servico ? estado.servicos.has(b.dataset.servico) : !estado.servicos.size);
    });
    raiz.querySelectorAll("[data-regra]").forEach(function (b) { apertado(b, b.dataset.regra === estado.regra); });
    raiz.querySelectorAll("[data-final]").forEach(function (b) { apertado(b, b.dataset.final === estado.final); });
    raiz.querySelectorAll("[data-relogio]").forEach(function (b) { apertado(b, (b.dataset.relogio ? Number(b.dataset.relogio) : null) === estado.relogio); });
    raiz.querySelectorAll("[data-chave]").forEach(function (b) { b.setAttribute("aria-checked", String(!!estado[b.dataset.chave])); });
  }

  // clima, recorte e serviço chegam do servidor com a contagem já com os outros filtros
  function desenharContagens(r) {
    climas.textContent = "";
    (r.climas || []).forEach(function (c) {
      var n = Number(c.qtd) || 0;
      var texto = el("span", "mmm-Clima-texto");
      texto.appendChild(el("b", null, c.nome));
      if (c.dica) { texto.appendChild(el("small", null, c.dica)); }
      var qtd = el("span", "mmm-Clima-qtd", String(n));
      qtd.setAttribute("aria-label", n === 1 ? "1 título" : n + " títulos");
      var b = botao("mmm-Clima", [c.icone ? icone(c.icone) : el("span", "mmm-Icone"), texto, qtd], { clima: c.codigo });
      b.disabled = !n && !estado.climas.has(c.codigo);
      climas.appendChild(b);
    });

    recortes.querySelectorAll("[data-recorte]").forEach(function (b) {
      var n = Number((r.recortes || {})[b.dataset.recorte]) || 0;
      var s = b.querySelector(".mmm-Opcao-sub");
      s.textContent = String(n);
      s.setAttribute("aria-label", n === 1 ? "1 título" : n + " títulos");
      b.disabled = !n && !estado.recortes.has(b.dataset.recorte);
    });

    onde.textContent = "";
    onde.appendChild(botao("mmm-Opcao", ["Tanto faz"], { servico: "" }));
    // os do grupo primeiro: são os que a turma assina
    var lista = (r.servicos || []).slice().sort(function (a, b) {
      return (servicosGrupo.indexOf(a.codigo) < 0) - (servicosGrupo.indexOf(b.codigo) < 0);
    });
    lista.forEach(function (s) {
      var n = Number(s.qtd) || 0;
      var logo = mmm.imagem(s.logo, "logo", "22px", "");
      logo.classList.add("mmm-Opcao-logo");
      var q = el("span", "mmm-Opcao-sub", String(n));
      q.setAttribute("aria-label", n === 1 ? "1 título" : n + " títulos");
      var b = botao("mmm-Opcao", [logo, s.nome, q], { servico: s.codigo });
      if (servicosGrupo.indexOf(s.codigo) >= 0) { b.classList.add("is-doGrupo"); b.title = "Vocês assinam"; }
      onde.appendChild(b);
    });
    desenharEscolhas();
  }

  /* ---------- rodapé: contagem e motivo ---------- */
  function cartasNaMesa() {
    return resposta ? Math.min(Number(resposta.cartas) || 0, MAX_CARTAS) : 0;
  }

  function motivo() {
    if (!estado.tipo) { return "Escolha filme ou série para dar as cartas."; }
    // quem dá as cartas está sempre no sofá; vazio só se a lista de membros não veio
    if (!estado.presentes.size || !eu) { return "Ninguém no sofá: recarregue a página para marcar quem vai assistir."; }
    if (contando || !resposta) { return null; }
    var n = Number(resposta.candidatos) || 0;
    if (n === 0) {
      return (estado.tipo === "FILME" ? "Nenhum filme" : "Nenhuma série") + " da lista passa nesses filtros. Tire um clima, um recorte ou um serviço.";
    }
    if (n === 1) { return "Só um título passa nesses filtros. Afrouxe algum para ter jogo."; }
    return null;
  }

  function desenharRodape() {
    contagem.textContent = "";
    if (!estado.tipo) {
      contagem.textContent = "Escolha filme ou série";
    } else if (falhou) {
      contagem.textContent = "Não deu para contar agora.";
      var de = botao("mmm-Contagem-denovo", ["Contar de novo"]);
      de.addEventListener("click", contar);
      contagem.appendChild(de);
    } else if (contando || !resposta) {
      contagem.textContent = "Contando as cartas…";
    } else {
      var n = cartasNaMesa();
      contagem.appendChild(el("b", null, String(n)));
      contagem.appendChild(document.createTextNode(n === 1 ? " carta no baralho" : " cartas no baralho"));
    }
    var m = estado.tipo ? motivo() : null;
    motivoEl.textContent = m || "";
    motivoEl.hidden = !m;
    var parado = !estado.tipo || contando || falhou || !resposta || !!m || dando;
    // aria-disabled e não disabled: o botão continua com o foco e o toque explica o motivo
    botaoDar.setAttribute("aria-disabled", String(parado));
    botaoDar.classList.toggle("is-disabled", parado);
  }

  /* ---------- servidor ---------- */
  function filtros() {
    return {
      tipo: estado.tipo,
      tempo: estado.tipo ? estado.tempo[estado.tipo] : null,
      climas: estado.climas,
      recortes: estado.recortes,
      servicos: estado.servicos,
      aluguel: estado.aluguel,
      crianca: estado.crianca,
      regra: estado.regra,
      final: estado.final,
      relogio: estado.relogio,
      presentes: estado.presentes
    };
  }

  var avisados = false;
  function contar() {
    if (!estado.tipo) { return; }
    var meu = ++pedido;
    contando = true;
    falhou = false;
    desenharRodape();
    mmm.jogo.contar(filtros(), function (r) {
      if (meu !== pedido) { return; }
      contando = false;
      resposta = r;
      // serviços do grupo que não têm título deste tipo saem da escolha; clima ou recorte marcado que ficou sem
      // título também sai (ex.: "Roer as unhas" depois de "Tem criança"), com aviso
      var codigos = (r.servicos || []).map(function (s) { return s.codigo; });
      var sairam = [];
      estado.servicos.forEach(function (c) { if (codigos.indexOf(c) < 0) { estado.servicos.delete(c); sairam.push(null); } });
      (r.climas || []).forEach(function (c) {
        if (estado.climas.has(c.codigo) && !Number(c.qtd)) { estado.climas.delete(c.codigo); sairam.push(c.nome); }
      });
      RECORTES.forEach(function (x) {
        if (estado.recortes.has(x.k) && !Number((r.recortes || {})[x.k])) { estado.recortes.delete(x.k); sairam.push(x.nome); }
      });
      desenharContagens(r);
      desenharRodape();
      var nomes = sairam.filter(Boolean);
      if (nomes.length && !avisados) {
        mmm.toast(nomes.join(" e ") + (nomes.length > 1 ? " saíram" : " saiu") + " da seleção: nenhum título passa com esses filtros.");
      }
      // o que saiu muda a conta: pede de novo, já sem eles
      avisados = sairam.length > 0;
      if (sairam.length) { contar(); }
    }, function () {
      if (meu !== pedido) { return; }
      contando = false;
      falhou = true;
      desenharRodape();
    });
  }

  /* ---------- toques ---------- */
  function alternar(conjunto, v) {
    if (conjunto.has(v)) { conjunto.delete(v); } else { conjunto.add(v); }
  }

  raiz.addEventListener("click", function (e) {
    var b = e.target.closest("button");
    if (!b || b.disabled || !raiz.contains(b)) { return; }
    var d = b.dataset;
    if (d.tipo) {
      if (estado.tipo !== d.tipo) {
        // cada tipo tem os seus climas e serviços: troca de tipo começa de novo
        estado.climas.clear();
        estado.recortes.clear();
        estado.servicos = new Set(servicosGrupo);
        resposta = null;
        climas.textContent = "";
        onde.textContent = "";
      }
      estado.tipo = d.tipo;
      desenharTempo();
    } else if (d.membro) {
      if (b.getAttribute("aria-disabled") === "true") {
        mmm.toast("Quem dá as cartas está sempre no sofá.");
        return;
      }
      alternar(estado.presentes, Number(d.membro));
    } else if (d.clima) {
      alternar(estado.climas, d.clima);
    } else if (d.recorte) {
      alternar(estado.recortes, d.recorte);
    } else if (d.servico !== undefined) {
      if (!d.servico) { estado.servicos.clear(); } else { alternar(estado.servicos, d.servico); }
    } else if (d.tempo !== undefined) {
      estado.tempo[estado.tipo] = d.tempo ? Number(d.tempo) : null;
      desenharTempo();
    } else if (d.regra) {
      estado.regra = d.regra;
    } else if (d.final) {
      estado.final = d.final;
    } else if (d.relogio !== undefined) {
      estado.relogio = d.relogio ? Number(d.relogio) : null;
    } else if (d.chave) {
      estado[d.chave] = !estado[d.chave];
    } else {
      return;
    }
    avisados = false;
    desenharEscolhas();
    // regra, final, relógio e sofá não mudam o baralho: só o rodapé
    if (d.regra || d.final || d.membro || d.relogio !== undefined) {
      desenharRodape();
      return;
    }
    contar();
  });

  botaoDar.addEventListener("click", function (e) {
    e.preventDefault();
    if (dando) { return; }
    var m = motivo();
    if (!estado.tipo || contando || falhou || !resposta || m) {
      mmm.toast(m || (falhou ? "Toque em Contar de novo antes de dar as cartas." : "Espere a contagem das cartas."));
      return;
    }
    dando = true;
    botaoDar.setAttribute("aria-busy", "true");
    desenharRodape();
    mmm.jogo.darCartas(filtros()).then(function () {
      // deu certo, a página já está indo para a sessão; recusa ou queda: o botão volta
      dando = false;
      botaoDar.removeAttribute("aria-busy");
      desenharRodape();
    });
  });

  desenharEscolhas();
  desenharTempo();
  desenharRodape();
});
