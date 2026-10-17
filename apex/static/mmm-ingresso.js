// Páginas 1 e 6: o ingresso rasgado e a nota. O servidor diz o que falta (o
// data-ingresso de cada ingresso, em MMM_PKG_INGRESSO); aqui o ingresso é desenhado como o da página 30, o canhoto se
// solta no Rasgar e a pessoa escolhe de 1 a 5 pipocas. Na página 1 o cartão fica no lugar; na página 6 o ingresso abre
// numa folha por cima da lista, que volta atualizada no fim.
apex.jQuery(function () {
  "use strict";

  var mmm = window.mmm;
  if (!mmm) { return; }
  var reduz = window.matchMedia("(prefers-reduced-motion: reduce)");
  var ROTULOS = ["", "Não gostei", "Fraco", "Deu para o gasto", "Gostei", "Adorei"];

  function el(tag, classe, texto) {
    var e = document.createElement(tag);
    if (classe) { e.className = classe; }
    if (texto !== undefined && texto !== null) { e.textContent = texto; }
    return e;
  }

  function dados(no) {
    try { return JSON.parse(no.getAttribute("data-ingresso")); } catch (e) { return null; }
  }

  // a mesma linha do ingresso da página 30: o selo da classificação, o ano e a duração
  function meta(d) {
    var linha = el("div", "mmm-LinhaMeta");
    var ci = mmm.classificacao(d.cls);
    if (ci) { linha.appendChild(ci); }
    [d.ano, mmm.duracaoTexto({ tipo: d.tipo, duracao: d.duracao, temporadas: d.temporadas })].forEach(function (v) {
      if (v) { linha.appendChild(el("span", "mmm-LinhaMeta-item", String(v))); }
    });
    return linha;
  }

  // o mesmo desenho do ingresso da página 30 (mmm-sessao.js, telaIngresso)
  function ingresso(d) {
    var t = el("div", "mmm-Ingresso");
    var topo = el("div", "mmm-Ingresso-topo");
    if (d.poster) {
      var img = el("img", "mmm-Ingresso-poster");
      img.src = "https://image.tmdb.org/t/p/w185" + d.poster;
      img.alt = "";
      img.width = 96;
      img.height = 144;
      img.decoding = "async";
      topo.appendChild(img);
    } else {
      topo.appendChild(el("div", "mmm-SemCapa", d.titulo));
    }
    var dd = el("div", "mmm-Ingresso-dados");
    dd.appendChild(el("div", "mmm-Ingresso-rotulo", (d.grupo ? d.grupo + " · " : "") + (d.tipo === "SERIE" ? "série" : "filme")));
    dd.appendChild(el("div", "mmm-Ingresso-titulo", d.titulo));
    dd.appendChild(meta(d));
    topo.appendChild(dd);
    t.appendChild(topo);
    // o horário e a sala são da sessão: marcado na ficha (Já assistimos) não tem sessão nem código
    if (d.codigo) {
      var campos = el("div", "mmm-Ingresso-campos");
      [["Começa", d.inicio || "—"], ["Termina", d.fim || "Quando cansar"], ["Sala", "Sofá"]].forEach(function (x) {
        var c = el("div");
        c.appendChild(el("span", "mmm-Ingresso-rotulo", x[0]));
        c.appendChild(el("b", null, x[1]));
        campos.appendChild(c);
      });
      t.appendChild(campos);
    }
    var picote = el("div", "mmm-Ingresso-picote");
    picote.setAttribute("aria-hidden", "true");
    t.appendChild(picote);
    var canhoto = el("div", "mmm-Ingresso-canhoto");
    var plateia = el("div");
    plateia.appendChild(el("div", "mmm-Ingresso-rotulo", "Na plateia"));
    var avs = el("div", "mmm-Avatares");
    (d.plateia || []).forEach(function (p) { avs.appendChild(mmm.avatar(p.apelido, p.cor)); });
    avs.setAttribute("role", "img");
    avs.setAttribute("aria-label", (d.plateia || []).map(function (p) { return p.apelido; }).join(", "));
    plateia.appendChild(avs);
    canhoto.appendChild(plateia);
    canhoto.appendChild(el("div", "mmm-Ingresso-codigo", "Nº " + (d.codigo || "")));
    t.appendChild(canhoto);
    t.setAttribute("role", "img");
    t.setAttribute("aria-label", "Ingresso de " + d.titulo + (d.estado === "RASGAR" ? "" : ", já rasgado"));
    if (d.estado !== "RASGAR") { rasgado(t); }
    return t;
  }

  // sem o canhoto e com a borda de baixo picotada
  function rasgado(t) {
    var canhoto = t.querySelector(".mmm-Ingresso-canhoto");
    var picote = t.querySelector(".mmm-Ingresso-picote");
    if (canhoto) { canhoto.remove(); }
    if (picote) { picote.remove(); }
    t.classList.add("is-rasgado");
  }

  // o canhoto se solta: uma cópia dele cai por cima, fora da máscara do ingresso, e o ingresso fica picotado
  function rasgar(t) {
    return new Promise(function (pronto) {
      var canhoto = t.querySelector(".mmm-Ingresso-canhoto");
      if (!canhoto) { pronto(); return; }
      var palco = t.parentNode;
      var r = canhoto.getBoundingClientRect();
      var p = palco.getBoundingClientRect();
      var solto = canhoto.cloneNode(true);
      solto.className = "mmm-Ingresso-canhoto mmm-CanhotoSolto";
      solto.setAttribute("aria-hidden", "true");
      solto.style.setProperty("top", (r.top - p.top) + "px");
      solto.style.setProperty("left", (r.left - p.left) + "px");
      solto.style.setProperty("width", r.width + "px");
      palco.appendChild(solto);
      rasgado(t);
      t.classList.add("is-puxado");
      mmm.som("vira");
      mmm.vibrar([12, 30, 12]);
      var fim = function () { solto.remove(); t.classList.remove("is-puxado"); pronto(); };
      if (reduz.matches) { window.setTimeout(fim, 260); } else { solto.addEventListener("animationend", fim, { once: true }); window.setTimeout(fim, 1400); }
    });
  }

  // de 1 a 5 pipocas, como um grupo de rádio (setas mudam, espaço e Enter marcam). A ficha usa o mesmo painel para o Já
  // assistimos: opcoes.enviar troca a chamada, opcoes.texto a mensagem do fim, opcoes.aviso entra antes da pergunta e
  // opcoes.falhou recebe a recusa do servidor
  function painelNota(d, guardou, opcoes) {
    opcoes = opcoes || {};
    var p = el("div", "mmm-NotaPainel");
    var idAviso = "mmm-nota-aviso-" + d.id;
    if (opcoes.aviso) {
      var aviso = el("p", "mmm-NotaPainel-aviso", opcoes.aviso);
      aviso.id = idAviso;
      p.appendChild(aviso);
    }
    var idPergunta = "mmm-nota-pergunta-" + d.id;
    var pergunta = el("p", "mmm-NotaPainel-pergunta", d.minhaNota ? "Quer trocar a sua nota?" : "Que nota você dá?");
    pergunta.id = idPergunta;
    p.appendChild(pergunta);
    var grupo = el("div", "mmm-NotaPainel-pipocas");
    grupo.setAttribute("role", "radiogroup");
    grupo.setAttribute("aria-labelledby", idPergunta);
    // o leitor de tela ouve o aviso junto com as pipocas e com o Guardar
    if (opcoes.aviso) { grupo.setAttribute("aria-describedby", idAviso); }
    var rotulo = el("p", "mmm-NotaPainel-rotulo", d.minhaNota ? ROTULOS[d.minhaNota] : "Toque nas pipocas");
    rotulo.setAttribute("aria-live", "polite");
    var guardar = el("button", "mmm-JogoBotao mmm-JogoBotao--pri", "Guardar nota");
    guardar.type = "button";
    if (opcoes.aviso) { guardar.setAttribute("aria-describedby", idAviso); }
    var nota = d.minhaNota || 0;
    var botoes = [];
    function marcar(n, focar) {
      nota = n;
      botoes.forEach(function (b, i) {
        b.classList.toggle("is-acesa", i < n);
        b.setAttribute("aria-checked", String(i + 1 === n));
        b.tabIndex = (i + 1 === (n || 1)) ? 0 : -1;
      });
      rotulo.textContent = n ? ROTULOS[n] : "Toque nas pipocas";
      guardar.disabled = !n;
      if (focar && botoes[n - 1]) { botoes[n - 1].focus(); }
    }
    for (var i = 1; i <= 5; i++) {
      var b = el("button", "mmm-NotaPipoca");
      b.type = "button";
      b.setAttribute("role", "radio");
      b.setAttribute("aria-label", i + (i === 1 ? " pipoca, " : " pipocas, ") + ROTULOS[i].toLowerCase());
      b.dataset.nota = String(i);
      b.appendChild(el("span", "mmm-NotaPipoca-icone"));
      b.querySelector("span").setAttribute("aria-hidden", "true");
      b.addEventListener("click", function (e) { marcar(Number(e.currentTarget.dataset.nota)); mmm.som("tique"); });
      b.addEventListener("keydown", function (e) {
        var atual = Number(e.currentTarget.dataset.nota);
        if (e.key === "ArrowRight" || e.key === "ArrowUp") { e.preventDefault(); marcar(Math.min(5, atual + 1), true); }
        else if (e.key === "ArrowLeft" || e.key === "ArrowDown") { e.preventDefault(); marcar(Math.max(1, atual - 1), true); }
        else if (e.key === "Home") { e.preventDefault(); marcar(1, true); }
        else if (e.key === "End") { e.preventDefault(); marcar(5, true); }
      });
      botoes.push(b);
      grupo.appendChild(b);
    }
    p.appendChild(grupo);
    p.appendChild(rotulo);
    guardar.addEventListener("click", function () {
      if (!nota || guardar.getAttribute("aria-busy") === "true") { return; }
      guardar.setAttribute("aria-busy", "true");
      var envio = opcoes.enviar ? opcoes.enviar(nota) : mmm.chamar("MMM_INGRESSO", { x01: "NOTA", x02: d.id, x03: nota });
      envio.then(function (r) {
        guardar.removeAttribute("aria-busy");
        var texto = opcoes.texto ? opcoes.texto(r, nota) : "Nota guardada" + (r.media ? ". Média do grupo: " + r.media : "");
        mmm.toast(texto);
        mmm.anunciar(texto);
        guardou(r, nota);
      }, function (e) {
        guardar.removeAttribute("aria-busy");
        mmm.erro(e);
        if (opcoes.falhou) { opcoes.falhou(e); }
      });
    });
    p.appendChild(guardar);
    marcar(nota);
    return { no: p, focar: function () { (botoes[(nota || 1) - 1]).focus(); } };
  }

  // o fluxo inteiro num palco: o ingresso (com o Rasgar, se ainda está inteiro) e depois a nota
  // na página 30 o ingresso já está desenhado (existente): ele entra no palco em vez de um novo
  function montar(palco, d, terminou, existente, rasgou) {
    var t = existente;
    if (t) {
      if (d.estado !== "RASGAR") { rasgado(t); }
    } else {
      palco.textContent = "";
      t = ingresso(d);
    }
    palco.classList.add("mmm-IngressoPalco");
    palco.appendChild(t);
    function pedirNota() {
      var painel = painelNota(d, terminou);
      palco.appendChild(painel.no);
      painel.focar();
    }
    if (d.estado !== "RASGAR") { pedirNota(); return; }
    var botao = el("button", "mmm-JogoBotao mmm-JogoBotao--pri mmm-IngressoPalco-rasgar", "Rasgar o ingresso");
    botao.type = "button";
    botao.addEventListener("click", function () {
      if (botao.getAttribute("aria-busy") === "true") { return; }
      botao.setAttribute("aria-busy", "true");
      mmm.chamar("MMM_INGRESSO", { x01: "RASGAR", x02: d.id }).then(function () {
        botao.remove();
        d.estado = "NOTA";
        if (rasgou) { rasgou(); }
        mmm.anunciar("Ingresso rasgado. " + d.titulo + " está entre os assistidos.");
        return rasgar(t);
      }).then(pedirNota, function (e) {
        botao.removeAttribute("aria-busy");
        mmm.erro(e);
      });
    });
    palco.appendChild(botao);
  }

  /* ---------- página 30: o ingresso do DEU MATCH, para rasgar ali mesmo ---------- */
  // o mmm-sessao.js chama depois de desenhar o ingresso: pergunta ao servidor como ele está e põe o Rasgar, ou as pipocas
  // (rasgado por outra pessoa), ou a nota já dada, no lugar da dica
  mmm.ingresso = {
    painelNota: painelNota,
    anexar: function (ticket, sessao, dica) {
      mmm.chamar("MMM_INGRESSO", { x01: "DADOS", x04: sessao }, true).then(function (r) {
        var d = r.ingresso;
        if (!d || !ticket.isConnected) { return; }
        if (d.minhaNota) {
          rasgado(ticket);
          dica.textContent = "Sua nota: " + d.minhaNota + (d.minhaNota === 1 ? " pipoca." : " pipocas.");
          return;
        }
        var palco = el("div");
        ticket.parentNode.insertBefore(palco, ticket);
        dica.textContent = d.estado === "RASGAR" ? "Rasgue agora ou depois, na lista do grupo." : (d.rasgouQuem || "Alguém") + " já rasgou o ingresso.";
        montar(palco, d, function (resposta, nota) {
          var p = palco.querySelector(".mmm-NotaPainel");
          if (p) { p.remove(); }
          dica.textContent = "Obrigado! Você deu " + nota + (nota === 1 ? " pipoca" : " pipocas") + (resposta.media ? ". Média do grupo: " + resposta.media + "." : ".");
        }, ticket, function () { dica.textContent = "Ingresso rasgado: já está entre os assistidos do grupo."; });
      }, function () { /* sem a resposta, fica a dica: dá para rasgar na lista */ });
    }
  };

  /* ---------- página 1: o cartão do ingresso pendente ---------- */
  var cartao = document.getElementById("mmm-ingresso-pendente");
  if (cartao) {
    var d1 = dados(cartao);
    if (d1) {
      montar(cartao.querySelector(".mmm-IngressoPendente-palco"), d1, function (r, nota) {
        var chamada = cartao.querySelector(".mmm-IngressoPendente-chamada");
        chamada.textContent = "Obrigado! Você deu " + nota + (nota === 1 ? " pipoca" : " pipocas") + (r.media ? ". Média do grupo: " + r.media + "." : ".");
        cartao.querySelector(".mmm-IngressoPendente-palco").remove();
        window.setTimeout(function () {
          cartao.classList.add("is-saindo");
          window.setTimeout(function () { cartao.remove(); }, reduz.matches ? 0 : 400);
        }, 3500);
      });
    }
  }

  /* ---------- página 6: Rasgar e Dar nota abrem o ingresso numa folha ---------- */
  var folhaAberta = null;
  function fecharFolha(atualizar) {
    if (!folhaAberta) { return; }
    var f = folhaAberta;
    folhaAberta = null;
    document.removeEventListener("keydown", f.tecla, true);
    f.no.remove();
    document.body.classList.remove("mmm-ComFolha");
    if (atualizar) {
      var reg = apex.region("mmm-assistidos");
      if (reg && reg.refresh) { reg.refresh(); } else { window.location.reload(); }
    }
    if (f.origem && document.body.contains(f.origem)) { f.origem.focus(); }
  }
  function abrirFolha(d, origem) {
    fecharFolha(false);
    var fundo = el("div", "mmm-IngressoFolha");
    var caixa = el("div", "mmm-IngressoFolha-caixa");
    caixa.setAttribute("role", "dialog");
    caixa.setAttribute("aria-modal", "true");
    caixa.setAttribute("aria-label", "Ingresso de " + d.titulo);
    var fechar = el("button", "mmm-JogoBotao mmm-IngressoFolha-fechar", "Fechar");
    fechar.type = "button";
    var palco = el("div");
    caixa.appendChild(fechar);
    caixa.appendChild(palco);
    fundo.appendChild(caixa);
    document.body.appendChild(fundo);
    document.body.classList.add("mmm-ComFolha");
    var mudou = false;
    var tecla = function (e) {
      if (e.key === "Escape") { e.preventDefault(); fecharFolha(mudou); return; }
      if (e.key === "Tab") {
        var focaveis = [].slice.call(caixa.querySelectorAll("button:not([disabled]), [tabindex=\"0\"]"));
        if (!focaveis.length) { return; }
        var primeiro = focaveis[0];
        var ultimo = focaveis[focaveis.length - 1];
        if (e.shiftKey && document.activeElement === primeiro) { e.preventDefault(); ultimo.focus(); }
        else if (!e.shiftKey && document.activeElement === ultimo) { e.preventDefault(); primeiro.focus(); }
      }
    };
    folhaAberta = { no: fundo, tecla: tecla, origem: origem };
    document.addEventListener("keydown", tecla, true);
    fechar.addEventListener("click", function () { fecharFolha(mudou); });
    fundo.addEventListener("click", function (e) { if (e.target === fundo) { fecharFolha(mudou); } });
    montar(palco, d, function () {
      mudou = true;
      window.setTimeout(function () { fecharFolha(true); }, 1600);
    });
    // o Rasgar já rasga no servidor: fechar a folha depois dele também atualiza a lista
    palco.addEventListener("click", function (e) { if (e.target.closest(".mmm-IngressoPalco-rasgar")) { mudou = true; } });
    // com o ingresso inteiro o foco vai ao Rasgar; rasgado, o painel da nota ja levou o foco para as pipocas
    var rasgarBotao = palco.querySelector(".mmm-IngressoPalco-rasgar");
    if (rasgarBotao) { rasgarBotao.focus(); }
  }
  apex.jQuery(document).on("click.mmmingresso", ".js-mmm-rasgar, .js-mmm-dar-nota", function (e) {
    var item = e.currentTarget.closest("[data-ingresso]");
    var d = item && dados(item);
    if (d) { abrirFolha(d, e.currentTarget); }
  });
});
