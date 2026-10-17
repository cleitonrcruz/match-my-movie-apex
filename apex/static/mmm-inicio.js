// Página 1 (início): modo Editar da lista, a gaveta Adicionar (busca no TMDB por título, pessoa e saga, com a espera
// enquanto o TMDB responde, e nota antiga colada) e o destino do aviso tocado.
// Carregado só na página 1 (Page > JavaScript > File URLs: #APP_FILES#mmm-inicio.js?v=N).
apex.jQuery(function () {
  "use strict";

  // aviso tocado (MMM_PKG_UTIL.enviar_push): ele abre a entrada com o destino no fragmento (entrar#ir=<caminho>), a
  // entrada manda quem está logado para cá e o fragmento atravessa o redirecionamento. O fragmento sai da URL antes de
  // tudo, e o destino só vale se for da lista: a sessão do jogo pela página 11, com grupo e id numéricos, ou esta lista
  if (window.location.hash.indexOf("#ir=") === 0) {
    var valor = window.location.hash.slice(4);
    window.history.replaceState(window.history.state, "", window.location.pathname + window.location.search);
    var destino = "";
    try { destino = decodeURIComponent(valor); } catch (e) { destino = ""; }
    var sessaoDoJogo = /^abrir\?p11_grupo=(\d{1,15})&p11_tipo=SESSAO&p11_id=(\d{1,15})$/.exec(destino);
    if (sessaoDoJogo) {
      // endereço a partir da própria página (o <base href> do APEX aponta para /ords/), com a sessão de agora: sem ela, o
      // APEX não reaproveita a sessão num endereço com itens
      var abrir = new URL("abrir", window.location.href);
      abrir.searchParams.set("p11_grupo", sessaoDoJogo[1]);
      abrir.searchParams.set("p11_tipo", "SESSAO");
      abrir.searchParams.set("p11_id", sessaoDoJogo[2]);
      abrir.searchParams.set("session", apex.env.APP_SESSION);
      window.location.replace(abrir.href);
      return;
    }
  }

  var mmm = window.mmm;
  var lista = document.getElementById("lista");
  if (!lista || !mmm) { return; }
  var el = mmm.el;

  var botaoEditar = document.getElementById("mmm-editar");
  if (botaoEditar) {
    botaoEditar.setAttribute("aria-pressed", "false");
    botaoEditar.addEventListener("click", function () {
      var ligado = !lista.classList.contains("is-editando");
      lista.classList.toggle("is-editando", ligado);
      botaoEditar.setAttribute("aria-pressed", String(ligado));
      var rotulo = botaoEditar.querySelector(".t-Button-label");
      if (rotulo) { rotulo.textContent = ligado ? "Pronto" : "Editar"; }
      mmm.anunciar(ligado ? "Edição ligada: toque no X do pôster para tirar da lista" : "Edição encerrada");
    });
  }

  // botão flutuante: a gaveta entra no histórico para o Voltar do Android fechá-la
  var botaoAdicionar = document.getElementById("mmm-botao-adicionar");
  if (botaoAdicionar) {
    botaoAdicionar.addEventListener("click", function () {
      mmm.abrirGaveta("mmm-adicionar");
    });
  }

  var resultados = document.getElementById("mmm-resultados");
  var reconhecidos = document.getElementById("mmm-reconhecidos");
  var botaoReconhecer = document.getElementById("mmm-reconhecer");
  var botaoAdicionarNota = document.getElementById("mmm-adicionar-nota");
  var ultimaBusca = 0;

  // ---------- busca por título, pessoa e saga ----------
  // a pessoa e a saga abrem no lugar dos resultados, dentro da mesma gaveta; os resultados ficam guardados (escondidos) e
  // o Voltar à busca os devolve como estavam. Sem entrada no histórico: o Voltar do Android continua fechando a gaveta
  var explorar = null;
  var vista = null;      // { tipo: "pessoa" | "saga", alvo, resposta, aba }
  var pedidoVista = 0;   // resposta atrasada de uma pessoa ou saga não desenha por cima da seguinte
  var voltarPara = null; // botão que abriu a pessoa ou a saga: o foco volta para ele
  var entrou = {};       // o que entrou na lista por esta gaveta ("FILME:123"), para as outras vistas mostrarem Na lista

  function chave(i) {
    return i.tipo + ":" + i.idTmdb;
  }

  function estaNaLista(i) {
    return i.naLista === true || entrou[chave(i)] === true;
  }

  function textoTitulo(item) {
    return (item.tipo === "SERIE" ? "Série" : "Filme") + (item.ano ? " · " + item.ano : "");
  }

  // linha de título (busca, pessoa e saga): pôster, nome, dados, papel, marcas e o Adicionar
  function linhaResultado(item, dados) {
    var r = el("div", "mmm-Resultado");
    r.appendChild(mmm.imagem(item.posterPath, "mini", "44px", ""));
    var txt = el("div");
    txt.appendChild(el("b", null, item.titulo));
    txt.appendChild(el("span", null, dados === undefined ? textoTitulo(item) : dados));
    if (item.papel) { txt.appendChild(el("span", "mmm-Resultado-papel", item.papel)); }
    if (item.estreia || item.jaVisto === true) {
      var marcas = el("span", "mmm-Marcas");
      if (item.estreia) { marcas.appendChild(el("span", "mmm-Marca mmm-Marca--estreia", item.estreia)); }
      if (item.jaVisto === true) { marcas.appendChild(el("span", "mmm-Marca mmm-Marca--visto", "Vocês já viram")); }
      txt.appendChild(marcas);
    }
    r.appendChild(txt);
    var add = el("button", "t-Button t-Button--hot t-Button--small js-mmm-adicionar", estaNaLista(item) ? "Na lista" : "Adicionar");
    add.type = "button";
    add.dataset.tmdb = String(item.idTmdb);
    add.dataset.tipo = item.tipo;
    add.dataset.nome = item.titulo;
    add.disabled = estaNaLista(item);
    r.appendChild(add);
    return r;
  }

  function grupo(titulo, filhos, classe) {
    var g = el("section", "mmm-ResultadoGrupo");
    g.appendChild(el("h3", "mmm-ResultadoGrupo-titulo", titulo));
    var c = el("div", classe);
    filhos.forEach(function (f) { c.appendChild(f); });
    g.appendChild(c);
    return g;
  }

  function chipPessoa(p) {
    var b = el("button", "mmm-Chip mmm-Chip--pessoa");
    b.type = "button";
    b.appendChild(mmm.foto(p.fotoPath, p.nome));
    var txt = el("span", "mmm-Chip-texto");
    txt.appendChild(el("b", null, p.nome));
    var sobre = [p.area, p.conhecidoPor].filter(Boolean).join(" · ");
    if (sobre) { txt.appendChild(el("small", null, sobre)); }
    b.appendChild(txt);
    b.addEventListener("click", function () {
      abrirVista("pessoa", { id: p.id, nome: p.nome, fotoPath: p.fotoPath, area: p.area }, b);
    });
    return b;
  }

  function chipSaga(s) {
    var b = el("button", "mmm-Chip mmm-Chip--saga");
    b.type = "button";
    b.appendChild(mmm.imagem(s.posterPath, "mini", "32px", ""));
    var txt = el("span", "mmm-Chip-texto");
    txt.appendChild(el("b", null, s.nome));
    txt.appendChild(el("small", null, "Saga"));
    b.appendChild(txt);
    b.addEventListener("click", function () {
      abrirVista("saga", { id: s.id, nome: s.nome, posterPath: s.posterPath }, b);
    });
    return b;
  }

  // ---------- espera da busca (chamada ao TMDB): o termo, onde ele é procurado e o filtro que vale ----------
  // o ano no fim do nome ("duna 2021") ou entre parênteses vira filtro dos títulos no servidor (MMM_PKG_TMDB.separar_ano,
  // a mesma regra): a espera diz o mesmo que a busca vai fazer
  function separarAno(termo) {
    var t = termo.trim();
    var m = /\(((?:19|20)\d{2})\)/.exec(t);
    if (m) { return { nome: t.replace(m[0], " ").replace(/\s+/g, " ").trim(), ano: m[1] }; }
    m = /^(.*\S)\s+((?:19|20)\d{2})$/.exec(t);
    if (m && Number(m[2]) <= new Date().getFullYear() + 3) { return { nome: m[1].trim(), ano: m[2] }; }
    return { nome: t, ano: null };
  }

  // lâmpadas do letreiro piscando em fila (paradas com prefers-reduced-motion), a frase e linhas no formato dos
  // resultados, para a lista que chega ocupar o mesmo lugar
  function blocoEspera(frase, grupos) {
    var e = el("div", "mmm-Espera");
    var cab = el("div", "mmm-Espera-cab");
    var lampadas = el("span", "mmm-Lampadas");
    lampadas.setAttribute("aria-hidden", "true");
    for (var i = 0; i < 3; i++) { lampadas.appendChild(el("span", "mmm-Lampada")); }
    cab.appendChild(lampadas);
    cab.appendChild(frase);
    e.appendChild(cab);
    if (grupos && grupos.length) {
      // os grupos já estão na frase (para o leitor de tela); aqui só se veem
      var onde = el("div", "mmm-Espera-onde");
      onde.setAttribute("aria-hidden", "true");
      grupos.forEach(function (g) { onde.appendChild(el("span", "mmm-Espera-grupo", g)); });
      e.appendChild(onde);
    }
    var linhas = el("div", "mmm-Espera-linhas");
    linhas.setAttribute("aria-hidden", "true");
    for (var j = 0; j < 3; j++) {
      var l = el("div", "mmm-Espera-linha");
      l.appendChild(el("span", "mmm-Espera-capa"));
      var txt = el("span", "mmm-Espera-texto");
      txt.appendChild(el("span"));
      txt.appendChild(el("span"));
      l.appendChild(txt);
      linhas.appendChild(l);
    }
    e.appendChild(linhas);
    return e;
  }

  function fraseEspera(antes, destaque, depois, soLeitor) {
    var p = el("p", "mmm-Espera-frase", antes);
    p.appendChild(el("b", null, destaque));
    if (depois) { p.appendChild(document.createTextNode(depois)); }
    if (soLeitor) { p.appendChild(el("span", "mmm-Sr", soLeitor)); }
    return p;
  }

  // a lista anterior sai, mas a altura dela fica enquanto a busca anda: o que vem embaixo na gaveta não sobe e desce
  var anteriores = null;
  function mostrarEspera(termo) {
    var s = separarAno(termo);
    var titulos = s.ano ? "Filmes e séries de " + s.ano : "Filmes e séries";
    var frase = fraseEspera("Procurando ", "“" + (s.nome.length >= 2 ? s.nome : termo.trim()) + "”", " no TMDB",
      " em " + titulos.toLowerCase() + ", pessoas e sagas");
    // a busca nova toma o lugar da pessoa ou da saga aberta já na espera
    sairDaVista();
    var atual = resultados.querySelector(".mmm-Espera");
    if (atual) {
      // a busca seguinte (mais uma letra) troca só o texto: a animação e a altura continuam
      atual.querySelector(".mmm-Espera-frase").replaceWith(frase);
      atual.querySelector(".mmm-Espera-grupo").textContent = titulos;
      return;
    }
    if (resultados.childNodes.length) {
      resultados.style.minHeight = resultados.offsetHeight + "px";
    }
    anteriores = [].slice.call(resultados.childNodes);
    resultados.textContent = "";
    resultados.appendChild(blocoEspera(frase, [titulos, "Pessoas", "Sagas"]));
  }

  function soltarAltura() {
    resultados.style.minHeight = "";
    anteriores = null;
  }

  // recusa do servidor (o TMDB fora, o teto da demo, buscas demais): o aviso de sempre, e a lista volta ao que era
  function voltarDaEspera() {
    var volta = anteriores || [];
    resultados.textContent = "";
    volta.forEach(function (n) { resultados.appendChild(n); });
    soltarAltura();
  }

  // 429 ou queda de rede: a falha fica no lugar dos resultados, com o Tentar de novo
  function falhaNaBusca() {
    resultados.textContent = "";
    soltarAltura();
    var f = el("div", "mmm-BuscaFalha");
    f.appendChild(el("p", "mmm-Credito", "A busca não respondeu agora."));
    var b = el("button", "t-Button mmm-BotaoSec mmm-BuscaFalha-denovo", "Tentar de novo");
    b.type = "button";
    b.addEventListener("click", function () {
      var termo = $v("P1_BUSCA").trim();
      if (termo.length >= 2) {
        mostrarEspera(termo);
        buscar();
      }
    });
    f.appendChild(b);
    resultados.appendChild(f);
  }

  // resultado em grupos: pessoas e sagas compactas em cima, cada grupo só quando houver; só com títulos, sem grupo
  function desenharBusca(r, textoVazio) {
    var itens = (r && r.itens) || [];
    var pessoas = (r && r.pessoas) || [];
    var sagas = (r && r.sagas) || [];
    resultados.textContent = "";
    soltarAltura();
    if (!itens.length && !pessoas.length && !sagas.length) {
      resultados.appendChild(el("p", "mmm-Credito", textoVazio));
      return;
    }
    if (pessoas.length) { resultados.appendChild(grupo("Pessoas", pessoas.map(chipPessoa), "mmm-Chips")); }
    if (sagas.length) { resultados.appendChild(grupo("Sagas", sagas.map(chipSaga), "mmm-Chips")); }
    if (!itens.length) { return; }
    var linhas = itens.map(function (i) { return linhaResultado(i); });
    var comAno = r.ano && r.filtrouAno === true;
    if (!pessoas.length && !sagas.length && !r.ano) {
      linhas.forEach(function (l) { resultados.appendChild(l); });
      return;
    }
    var g = grupo(comAno ? "Filmes e séries de " + r.ano : "Filmes e séries", linhas, "mmm-ResultadosLista");
    // nome com ano sem nenhum título daquele ano: o filtro saiu no servidor e a tela diz por quê
    if (r.ano && r.filtrouAno === false) {
      g.insertBefore(el("p", "mmm-Credito", "Nada de " + r.ano + " com esse nome. Estes são de outros anos:"), g.lastChild);
    }
    resultados.appendChild(g);
  }

  function garantirExplorar() {
    if (!explorar) {
      explorar = el("div", "mmm-Explorar");
      explorar.id = "mmm-explorar";
      explorar.hidden = true;
      resultados.parentNode.insertBefore(explorar, resultados.nextSibling);
      apex.jQuery(explorar).on("click", ".js-mmm-adicionar", adicionar);
    }
    return explorar;
  }

  function mostrarVista(sim) {
    garantirExplorar();
    explorar.hidden = !sim;
    resultados.hidden = sim;
  }

  function cabecalhoVista(v) {
    var cab = el("div", "mmm-Explorar-cab");
    var voltar = el("button", "t-Button mmm-BotaoSec mmm-Explorar-voltar");
    voltar.type = "button";
    voltar.appendChild(mmm.seta("‹"));
    voltar.appendChild(document.createTextNode("Voltar à busca"));
    voltar.addEventListener("click", function () { voltarBusca(false); });
    cab.appendChild(voltar);
    var quem = el("div", "mmm-Explorar-quem");
    quem.appendChild(v.tipo === "pessoa" ? mmm.foto(v.alvo.fotoPath, v.alvo.nome) : mmm.imagem(v.alvo.posterPath, "mini", "48px", ""));
    var txt = el("div", "mmm-Explorar-texto");
    var h = el("h3", "mmm-Explorar-titulo", v.alvo.nome);
    h.id = "mmm-explorar-titulo";
    h.tabIndex = -1;
    txt.appendChild(h);
    var sobre = el("small", "mmm-Explorar-sobre", v.tipo === "pessoa" ? v.alvo.area || "" : "Saga");
    txt.appendChild(sobre);
    quem.appendChild(txt);
    cab.appendChild(quem);
    return cab;
  }

  function abrirVista(tipo, alvo, origem) {
    var meu = ++pedidoVista;
    voltarPara = origem || null;
    vista = { tipo: tipo, alvo: alvo, resposta: null, aba: null };
    var ex = garantirExplorar();
    ex.textContent = "";
    ex.appendChild(cabecalhoVista(vista));
    var corpo = el("div", "mmm-Explorar-corpo");
    // a mesma espera da busca: a pessoa e a saga também vêm do TMDB
    corpo.appendChild(blocoEspera(tipo === "pessoa" ? fraseEspera("Procurando os filmes e as séries de ", alvo.nome)
      : fraseEspera("Procurando as partes da saga ", alvo.nome)));
    ex.appendChild(corpo);
    ex.setAttribute("aria-busy", "true");
    mostrarVista(true);
    document.getElementById("mmm-explorar-titulo").focus();
    mmm.chamar(tipo === "pessoa" ? "MMM_PESSOA" : "MMM_SAGA", { x01: String(alvo.id) }).then(function (r) {
      if (meu !== pedidoVista) { return; }
      vista.resposta = r;
      preencherVista();
      mmm.anunciar(resumoVista());
    }, function (e) {
      if (meu !== pedidoVista) { return; }
      voltarBusca(false);
      mmm.erro(e);
    });
  }

  function resumoVista() {
    var r = vista.resposta;
    if (vista.tipo === "pessoa") {
      var f = (r.filmes || []).length;
      var s = (r.series || []).length;
      return vista.alvo.nome + ": " + f + (f === 1 ? " filme" : " filmes") + " e " + s + (s === 1 ? " série" : " séries");
    }
    var p = (r.partes || []).length;
    return "Saga " + vista.alvo.nome + ": " + p + (p === 1 ? " filme" : " filmes") + ", " + (Number(r.adicionaveis) || 0) + " para adicionar";
  }

  // só o corpo muda: o cabeçalho (com o foco) fica onde está
  function preencherVista() {
    var corpo = explorar.querySelector(".mmm-Explorar-corpo");
    corpo.textContent = "";
    explorar.removeAttribute("aria-busy");
    // a saga aberta pela ficha não trouxe o pôster: ele chega com as partes
    if (vista.tipo === "saga" && !vista.alvo.posterPath && vista.resposta.posterPath) {
      vista.alvo.posterPath = vista.resposta.posterPath;
      var quem = explorar.querySelector(".mmm-Explorar-quem");
      quem.replaceChild(mmm.imagem(vista.alvo.posterPath, "mini", "48px", ""), quem.firstChild);
    }
    if (vista.tipo === "pessoa") { desenharPessoa(corpo, vista); } else { desenharSaga(corpo, vista); }
  }

  // pílulas Filmes e Séries com a contagem; cada linha com o papel ao lado
  function desenharPessoa(corpo, v) {
    var r = v.resposta;
    var filmes = r.filmes || [];
    var series = r.series || [];
    if (!filmes.length && !series.length) {
      corpo.appendChild(el("p", "mmm-Credito", "Nenhum filme ou série com pôster para mostrar."));
      return;
    }
    if (!v.aba) { v.aba = filmes.length ? "filmes" : "series"; }
    var abas = el("div", "mmm-Abas");
    abas.setAttribute("role", "group");
    abas.setAttribute("aria-label", "Filmes ou séries");
    var lista = el("div", "mmm-ResultadosLista");
    var nota = el("p", "mmm-Credito");
    [["filmes", "Filmes", filmes], ["series", "Séries", series]].forEach(function (a) {
      if (!a[2].length) { return; }
      var b = el("button", "mmm-Aba", a[1] + " (" + a[2].length + ")");
      b.type = "button";
      b.dataset.aba = a[0];
      b.addEventListener("click", function () {
        v.aba = a[0];
        marcar();
        preencher();
      });
      abas.appendChild(b);
    });
    function marcar() {
      abas.querySelectorAll(".mmm-Aba").forEach(function (b) { b.setAttribute("aria-pressed", String(b.dataset.aba === v.aba)); });
    }
    function preencher() {
      var itens = v.aba === "filmes" ? filmes : series;
      var total = Number(v.aba === "filmes" ? r.totalFilmes : r.totalSeries) || itens.length;
      lista.textContent = "";
      itens.forEach(function (i) { lista.appendChild(linhaResultado(i, i.ano ? String(i.ano) : "")); });
      nota.textContent = total > itens.length ? "Estes são os " + itens.length + " mais recentes." : "";
      nota.hidden = !nota.textContent;
    }
    corpo.appendChild(abas);
    corpo.appendChild(lista);
    corpo.appendChild(nota);
    marcar();
    preencher();
  }

  function textoSagaInteira(n) {
    return n ? "Adicionar a saga inteira (" + n + ")" : "Nada novo para adicionar";
  }

  // partes em ordem de lançamento, o Adicionar a saga inteira com o número que entra e o Adicionar de cada parte
  function desenharSaga(corpo, v) {
    var r = v.resposta;
    var n = Number(r.adicionaveis) || 0;
    var tudo = el("button", "t-Button t-Button--hot mmm-Botao--largo mmm-SagaInteira", textoSagaInteira(n));
    tudo.type = "button";
    tudo.id = "mmm-saga-inteira";
    if (!n) { indisponivel(tudo, true); }
    tudo.addEventListener("click", function () { adicionarSaga(tudo); });
    corpo.appendChild(tudo);
    corpo.appendChild(el("p", "mmm-Credito", "Fica de fora o que já está na lista, o que vocês já viram e o que ainda não estreou."));
    var lista = el("div", "mmm-ResultadosLista");
    (r.partes || []).forEach(function (p, i) {
      lista.appendChild(linhaResultado(p, (i + 1) + "º" + (p.ano ? " · " + p.ano : "")));
    });
    corpo.appendChild(lista);
  }

  function voltarBusca(silencioso) {
    pedidoVista++;
    vista = null;
    mostrarVista(false);
    // o que entrou pela pessoa ou pela saga aparece como Na lista também nos resultados
    resultados.querySelectorAll(".js-mmm-adicionar").forEach(function (b) {
      if (entrou[b.dataset.tipo + ":" + b.dataset.tmdb] && !b.disabled && b.getAttribute("aria-disabled") !== "true") {
        b.textContent = "Na lista";
        b.disabled = true;
      }
    });
    var alvo = voltarPara && document.body.contains(voltarPara) ? voltarPara : document.getElementById("P1_BUSCA");
    voltarPara = null;
    if (alvo && !silencioso) { alvo.focus(); }
  }

  // a busca nova toma o lugar da pessoa ou da saga aberta
  function sairDaVista() {
    if (!vista) { return; }
    pedidoVista++;
    vista = null;
    voltarPara = null;
    mostrarVista(false);
  }

  // pedido silencioso: a queda de rede e o 429 aparecem no lugar dos resultados, e não no aviso padrão do APEX
  var buscar = apex.util.debounce(function () {
    var termo = $v("P1_BUSCA").trim();
    var minha = ++ultimaBusca;
    if (termo.length < 2) {
      sairDaVista();
      desenharBusca(null, "Digite o nome de um filme ou série.");
      return;
    }
    mmm.chamar("MMM_BUSCAR", { x01: termo }, true).then(function (r) {
      if (minha !== ultimaBusca) { return; }
      sairDaVista();
      desenharBusca(r, "Nada com esse nome no TMDB.");
    }, function (e) {
      if (minha !== ultimaBusca) { return; }
      if (e && e.recusado) {
        voltarDaEspera();
        mmm.erro(e);
        return;
      }
      falhaNaBusca();
    });
  }, 350);

  // a espera aparece já na digitação (com dois caracteres), antes do pedido que sai 350 ms depois da última tecla
  function digitou() {
    if ($v("P1_BUSCA").trim().length >= 2) { mostrarEspera($v("P1_BUSCA")); }
    buscar();
  }

  // indisponível pela classe do tema, sem o atributo disabled: o botão desabilitado perde o foco, a gaveta deixa de
  // fechar com o Esc e dois Enter seguidos em Adicionar congelavam a página no Chrome
  function indisponivel(b, sim) {
    b.classList.toggle("is-disabled", sim);
    if (sim) { b.setAttribute("aria-disabled", "true"); } else { b.removeAttribute("aria-disabled"); }
  }

  // o título que entrou vale nas três vistas; na saga, a parte deixa de contar no Adicionar a saga inteira
  function marcarNaVista(item) {
    entrou[chave(item)] = true;
    if (!vista || !vista.resposta) { return; }
    var r = vista.resposta;
    [r.filmes, r.series, r.partes].forEach(function (lista) {
      (lista || []).forEach(function (i) {
        if (chave(i) !== chave(item) || i.naLista === true) { return; }
        if (vista.tipo === "saga" && i.lancado === true && i.jaVisto !== true) {
          r.adicionaveis = Math.max(0, (Number(r.adicionaveis) || 0) - 1);
        }
        i.naLista = true;
      });
    });
    var tudo = document.getElementById("mmm-saga-inteira");
    if (vista.tipo === "saga" && tudo) {
      tudo.textContent = textoSagaInteira(Number(r.adicionaveis) || 0);
      if (!r.adicionaveis) { indisponivel(tudo, true); }
    }
  }

  function adicionar() {
    var b = this;
    if (b.disabled || b.getAttribute("aria-disabled") === "true") { return; }
    indisponivel(b, true);
    mmm.chamar("MMM_ADICIONAR", {
      x01: b.dataset.tipo,
      x02: b.dataset.tmdb,
      pageItems: "#P1_ORIGEM,#P1_VONTADE"
    }).then(function () {
      b.textContent = "Na lista";
      marcarNaVista({ tipo: b.dataset.tipo, idTmdb: Number(b.dataset.tmdb) });
      mmm.atualizarLista();
      mmm.toast(b.dataset.nome + " entrou na lista");
    }, function (e) {
      indisponivel(b, false);
      mmm.erro(e);
    });
  }

  function adicionarSaga(b) {
    if (b.getAttribute("aria-disabled") === "true") { return; }
    indisponivel(b, true);
    var v = vista;
    mmm.chamar("MMM_ADICIONAR_SAGA", { x01: String(v.alvo.id), pageItems: "#P1_ORIGEM,#P1_VONTADE" }).then(function (r) {
      (r.partes || []).forEach(function (p) {
        if (p.naLista === true) { entrou[chave(p)] = true; }
      });
      var n = Number(r.adicionados) || 0;
      if (vista === v) {
        v.resposta.partes = r.partes || v.resposta.partes;
        v.resposta.adicionaveis = r.adicionaveis;
        preencherVista();
        // o botão novo (já indisponível) recebe o foco: o Esc continua fechando a gaveta
        var novo = document.getElementById("mmm-saga-inteira");
        if (novo) { novo.focus(); }
      }
      mmm.atualizarLista();
      mmm.toast(n ? n + (n === 1 ? " filme da saga entrou" : " filmes da saga entraram") + " na lista" : "Nada novo para adicionar");
    }, function (e) {
      indisponivel(b, false);
      mmm.erro(e);
    });
  }

  if (resultados) {
    apex.jQuery("#P1_BUSCA").on("input", digitou);
    apex.jQuery(resultados).on("click", ".js-mmm-adicionar", adicionar);
    // a ficha abre a pessoa ou a saga aqui (Mais com, Faz parte da saga), com a gaveta no modo Buscar
    mmm.explorar = {
      abrir: function (alvo) {
        if (apex.item("P1_MODO").getValue() !== "BUSCAR") { apex.item("P1_MODO").setValue("BUSCAR"); }
        // pela ficha a busca começa limpa: o Voltar à busca não cai num resultado antigo
        ultimaBusca++;
        apex.item("P1_BUSCA").setValue("", null, true);
        desenharBusca(null, "Digite o nome de um filme ou série.");
        mmm.abrirGaveta("mmm-adicionar");
        abrirVista(alvo.tipo === "saga" ? "saga" : "pessoa",
          { id: alvo.id, nome: alvo.nome, fotoPath: alvo.fotoPath, posterPath: null, area: alvo.area }, null);
      }
    };
  }

  // nota antiga: cada linha vira uma escolha; OK já vem marcada, ambígua pede escolha
  var ROTULO = {
    OK: "Achei",
    AMBIGUO: "Qual destes?",
    NAO_ACHEI: "Não achei com certeza",
    NA_LISTA: "Já está na lista",
    ERRO: "O TMDB não respondeu: cole de novo",
    NAO_PROCESSADA: "Procurando…"
  };

  function linhaNota(l) {
    var d = el("div", "mmm-Resultado mmm-Resultado--nota");
    d.dataset.status = l.status;
    var txt = el("div");
    txt.appendChild(el("b", null, l.linha));
    txt.appendChild(el("span", null, ROTULO[l.status] || l.status));
    d.appendChild(txt);
    if (l.status !== "OK" && l.status !== "AMBIGUO" && l.status !== "NAO_ACHEI") { return d; }
    // o TMDB não devolveu nada para a linha: sem candidato não há o que escolher
    if (!(l.candidatos || []).length) { return d; }
    var escolha = el("select", "selectlist apex-item-select js-mmm-nota");
    escolha.dataset.seq = String(l.seq);
    escolha.setAttribute("aria-label", "Título para a linha " + l.linha);
    var nenhum = el("option", null, l.status === "OK" ? "Não adicionar" : "Escolha…");
    nenhum.value = "";
    escolha.appendChild(nenhum);
    (l.candidatos || []).forEach(function (c, i) {
      var o = el("option", null, c.titulo + " (" + textoTitulo(c) + ")");
      o.value = c.tipo + ":" + c.idTmdb;
      if (l.status === "OK" && i === 0) { o.selected = true; }
      escolha.appendChild(o);
    });
    d.appendChild(escolha);
    return d;
  }

  // a escolha feita num select sobrevive à rodada seguinte: o seq das linhas já prontas não muda
  var escolhasNota = {};

  function desenharNota(r) {
    reconhecidos.querySelectorAll(".js-mmm-nota").forEach(function (s) { escolhasNota[s.dataset.seq] = s.value; });
    reconhecidos.textContent = "";
    (r.linhas || []).forEach(function (l) { reconhecidos.appendChild(linhaNota(l)); });
    reconhecidos.querySelectorAll(".js-mmm-nota").forEach(function (s) {
      var antes = escolhasNota[s.dataset.seq];
      if (antes !== undefined && [].some.call(s.options, function (o) { return o.value === antes; })) { s.value = antes; }
    });
  }

  // o Adicionar só aparece com a última rodada pronta: tocado no meio, a resposta seguinte redesenharia o que já entrou
  function mostrarAdicionarNota() {
    if (botaoAdicionarNota) { botaoAdicionarNota.hidden = !reconhecidos.querySelector(".js-mmm-nota"); }
  }

  // continuação que falhou ou parou de andar: a linha não fica em "Procurando…" sem nada procurando
  function pararProcura() {
    reconhecidos.querySelectorAll('[data-status="NAO_PROCESSADA"] span').forEach(function (s) {
      s.textContent = "Ficou sem procurar. Toque em Reconhecer para tentar de novo.";
    });
  }

  function linhasParadas(r) {
    return (r.linhas || []).filter(function (l) { return l.status === "NAO_PROCESSADA"; }).length;
  }

  // cada pedido da nota para em ~6 s (segura uma das poucas vagas HTTP da ATP): enquanto sobrar linha
  // NAO_PROCESSADA e cada rodada andar, a tela pede a continuação sozinha
  function continuarNota(antes) {
    return mmm.chamar("MMM_RECONHECER_NOTA", { x01: "S" }).then(function (r) {
      desenharNota(r);
      var agora = linhasParadas(r);
      return agora > 0 && agora < antes ? continuarNota(agora) : null;
    });
  }

  if (reconhecidos && botaoReconhecer) {
    botaoReconhecer.addEventListener("click", function () {
      var espera = apex.util.showSpinner(apex.jQuery(reconhecidos));
      botaoReconhecer.disabled = true;
      // nota nova: as escolhas da nota anterior não valem para estas linhas
      escolhasNota = {};
      reconhecidos.textContent = "";
      if (botaoAdicionarNota) { botaoAdicionarNota.hidden = true; }
      mmm.chamar("MMM_RECONHECER_NOTA", { pageItems: "#P1_COLAGEM" }).then(function (r) {
        espera.remove();
        desenharNota(r);
        var n = linhasParadas(r);
        return n > 0 ? continuarNota(n) : null;
      }, function (e) {
        espera.remove();
        throw e;
      }).then(function () {
        pararProcura();
        mostrarAdicionarNota();
        botaoReconhecer.disabled = false;
      }, function (e) {
        pararProcura();
        mostrarAdicionarNota();
        botaoReconhecer.disabled = false;
        mmm.erro(e);
      });
    });
  }

  if (reconhecidos && botaoAdicionarNota) {
    botaoAdicionarNota.addEventListener("click", function () {
      var vontade = Number($v("P1_VONTADE")) || 2;
      var escolhas = [];
      reconhecidos.querySelectorAll(".js-mmm-nota").forEach(function (s) {
        if (!s.value) { return; }
        var partes = s.value.split(":");
        escolhas.push({ seq: Number(s.dataset.seq), tipo: partes[0], idTmdb: Number(partes[1]), pipocas: vontade });
      });
      if (!escolhas.length) {
        mmm.toast("Escolha pelo menos um título.");
        return;
      }
      botaoAdicionarNota.disabled = true;
      mmm.chamar("MMM_ADICIONAR_NOTA", { x01: JSON.stringify(escolhas) }).then(function (r) {
        botaoAdicionarNota.disabled = false;
        reconhecidos.textContent = "";
        botaoAdicionarNota.hidden = true;
        // o botão sumiu com o foco: ele volta à gaveta, no Reconhecer, para o Esc continuar fechando
        if (document.activeElement === document.body && botaoReconhecer) { botaoReconhecer.focus(); }
        mmm.atualizarLista();
        mmm.toast(r.adicionados + (r.adicionados === 1 ? " título entrou" : " títulos entraram") + " na lista. Os detalhes chegam em instantes.");
      }, function (e) {
        botaoAdicionarNota.disabled = false;
        mmm.erro(e);
      });
    });
  }

  // sem pulso permanente: cada pedido conta na cota do Worker e ocupa uma vaga HTTP da ATP. O letreiro
  // sai do Before Header ao abrir a página e só confere de novo quando a aba volta a ficar visível;
  // quem foi chamado para o sofá recebe o push
  var letreiro = document.getElementById("mmm-letreiro");
  var grupoTela = document.getElementById("P0_GRUPO_TELA");
  document.addEventListener("visibilitychange", function () {
    if (!letreiro || document.visibilityState !== "visible") { return; }
    mmm.chamar("MMM_PULSO", {}, true).then(function (r) {
      // o grupo ativo mudou em outro aparelho: a lista na tela é de outro grupo
      var outroGrupo = grupoTela && String(r.grupo || "") !== grupoTela.value;
      if (outroGrupo || String(r.sessao || "") !== (letreiro.dataset.sessao || "")) {
        window.location.reload();
      }
    }, function () { return null; });
  });

  // a lista mudou (adicionar, tirar, desfazer): o cabeçalho volta do servidor com o total, e o letreiro sem sessão
  // aberta acompanha o texto que vem nele
  apex.jQuery("#mmm-contagem").on("apexafterrefresh", function () {
    var total = this.querySelector("[data-letreiro]");
    var info = letreiro && letreiro.querySelector(".mmm-Letreiro-info");
    if (total && info && !letreiro.dataset.sessao) { info.textContent = total.dataset.letreiro; }
  });

  // atalho Adicionar do app instalado (manifesto: inicio#adicionar) abre a gaveta. É fragmento porque a página 1 exige
  // checksum em todo argumento da URL (request e item sem checksum dão erro de proteção) e o fragmento não vai ao
  // servidor; ele sai da URL antes, para recarregar ou voltar não abrir a gaveta de novo
  if (botaoAdicionar && window.location.hash === "#adicionar") {
    window.history.replaceState(window.history.state, "", window.location.pathname + window.location.search);
    mmm.abrirGaveta("mmm-adicionar");
  }
});
