// Match My Movie: página 2, Meus grupos (#APP_FILES#mmm-grupos.js?v=N nas File URLs da página).
// Cada grupo tem um menu (o botão de três pontos): Abrir, Renomear e Excluir grupo (só o dono) e Sair do grupo. O
// Renomear abre a gaveta com o nome; Sair e Excluir pedem confirmação com o que acontece de verdade, lido do servidor na
// hora (MMM_GRUPO_INFO: quem fica como dono, quantas pessoas, se é a última conta Google). A ação só põe o grupo num item
// oculto e submete: quem grava é o processo da página, que confere tudo de novo (participação, dono, demonstração).
// O Criar grupo abre a folha do Novo grupo, como a do Renomear: o nome e o apelido são conferidos aqui, antes de
// enviar, e de novo pelas validações da página. A página envia sem recarregar quando dá erro (Reload on Submit: Only
// for Success): a recusa volta com a folha aberta e o aviso.
(function (apex, $) {
  "use strict";

  var menu = null;
  var botaoDoMenu = null;
  var botaoNovo = null;

  // unsafe: o APEX escapa o texto, que leva o nome do grupo e o apelido (dados de quem usa o app)
  function confirmar(texto, rotulo, estilo, fn) {
    apex.message.confirm(texto, function (ok) {
      if (ok) { fn(); }
    }, { unsafe: true, style: estilo, confirmLabel: rotulo, cancelLabel: "Cancelar" });
  }

  function enviar(id, request) {
    apex.item("P2_GRUPO").setValue(id);
    apex.submit({ request: request });
  }

  // o que o servidor sabe agora do grupo; erro de rede ou recusa vira o aviso do app
  function lerInfo(id) {
    return mmm.chamar("MMM_GRUPO_INFO", { x01: id });
  }

  function pessoas(n) { return n === 1 ? "mais 1 pessoa" : "mais " + n + " pessoas"; }

  function sair(li) {
    var id = li.dataset.grupo;
    var nome = li.dataset.nome || "este grupo";
    lerInfo(id).then(function (r) {
      var texto;
      var estilo = "warning";
      if (r.outros === 0) {
        texto = "Você é a última pessoa com conta Google em " + nome + ". Se sair, o grupo é apagado com a lista e o histórico. Sair mesmo assim?";
        estilo = "danger";
      } else if (r.papel === "DONO") {
        texto = "Sair de " + nome + "? " + r.novoDono + " fica como dono. Para escolher outra pessoa, use Tornar dono em Membros e convite antes de sair.";
      } else {
        texto = "Sair de " + nome + "? Para voltar, você vai precisar de um convite novo.";
      }
      confirmar(texto, "Sair do grupo", estilo, function () { enviar(id, "SAIR_GRUPO"); });
    }, mmm.erro);
  }

  // só o dono vê a opção; a confirmação diz o que some e para quem, porque não dá para desfazer
  function excluir(li) {
    var id = li.dataset.grupo;
    var nome = li.dataset.nome || "este grupo";
    lerInfo(id).then(function (r) {
      var outros = Math.max(0, (Number(r.pessoas) || 1) - 1);
      confirmar("Excluir o grupo " + nome + (outros ? " para todos?" : "?") + " A lista, as sessões e o histórico do grupo " +
        "são apagados" + (outros ? " para você e " + pessoas(outros) : "") + ", e não dá para desfazer.", "Excluir o grupo", "danger",
        function () { enviar(id, "EXCLUIR_GRUPO"); });
    }, mmm.erro);
  }

  function renomear(li) {
    apex.item("P2_GRUPO").setValue(li.dataset.grupo);
    apex.item("P2_NOME").setValue(li.dataset.nome || "");
    mmm.abrirGaveta("mmm-renomear");
    window.setTimeout(function () {
      var campo = document.getElementById("P2_NOME");
      if (campo) {
        campo.focus();
        campo.select();
      }
    }, 120);
  }

  function novoGrupo(botao) {
    botaoNovo = botao;
    apex.message.clearErrors();
    mmm.abrirGaveta("mmm-novo-grupo");
    window.setTimeout(function () {
      var campo = document.getElementById("P2_NOVO_NOME");
      if (campo) { campo.focus(); }
    }, 120);
  }

  // sem nome ou sem apelido a folha fica aberta, com o aviso no campo; o processo também recusa nome vazio
  function criarGrupo(botao) {
    var faltam = [];
    if (!apex.item("P2_NOVO_NOME").getValue().trim()) {
      faltam.push({ type: "error", location: "inline", pageItem: "P2_NOVO_NOME", message: "Dê um nome ao grupo.", unsafe: false });
    }
    if (!apex.item("P2_NOVO_APELIDO").getValue().trim()) {
      faltam.push({ type: "error", location: "inline", pageItem: "P2_NOVO_APELIDO", message: "Escreva um apelido.", unsafe: false });
    }
    apex.message.clearErrors();
    if (faltam.length) {
      apex.message.showErrors(faltam);
      document.getElementById(faltam[0].pageItem).focus();
      return;
    }
    // um toque só: o segundo criaria outro grupo com o mesmo nome. Se o servidor recusa (o limite de grupos, por exemplo)
    // ou a rede falha, a página não recarrega, e o botão volta a valer para tentar de novo
    botao.disabled = true;
    $(document).on("ajaxComplete.mmmCriar", function (e, xhr, opcoes) {
      if (!opcoes || String(opcoes.url).indexOf("wwv_flow.accept") < 0) { return; }
      $(document).off("ajaxComplete.mmmCriar");
      if (!(xhr.responseJSON && xhr.responseJSON.redirectURL)) { botao.disabled = false; }
    });
    apex.submit({ request: "CRIAR" });
  }

  function itens(li) {
    var dono = li.dataset.papel === "DONO";
    var lista = [{
      type: "action",
      label: "Abrir",
      icon: "fa fa-arrow-right",
      action: function () { apex.navigation.redirect(li.querySelector(".mmm-MeuGrupo-abrir").href); }
    }];
    if (dono) {
      lista.push({ type: "action", label: "Renomear", icon: "fa fa-pencil", action: function () { renomear(li); } });
    }
    lista.push({ type: "action", label: "Sair do grupo", icon: "fa fa-sign-out", action: function () { sair(li); } });
    if (dono) {
      lista.push({ type: "separator" });
      lista.push({ type: "action", label: "Excluir grupo", icon: "fa fa-trash-o", action: function () { excluir(li); } });
    }
    return lista;
  }

  function abrirMenu(botao) {
    var li = botao.closest(".mmm-MeuGrupo");
    if (!li) { return; }
    botaoDoMenu = botao;
    if (!menu) {
      menu = $("<div id='mmm-grupo-menu' class='mmm-GrupoMenu'></div>").appendTo(document.body);
      menu.menu({ items: itens(li) });
    } else {
      menu.menu("option", "items", itens(li));
    }
    menu.menu("toggle", $(botao));
  }

  $(document)
    .off(".mmmGrupos")
    .on("click.mmmGrupos", ".js-mmm-grupo-acoes", function (e) {
      e.preventDefault();
      abrirMenu(this);
    })
    // a folha do Novo grupo: abre pelo Criar grupo, cria pelo Criar grupo de dentro e fecha pelo Cancelar
    .on("click.mmmGrupos", ".js-mmm-novo-grupo", function () {
      novoGrupo(this);
    })
    .on("click.mmmGrupos", ".js-mmm-criar-grupo", function () {
      criarGrupo(this);
    })
    .on("click.mmmGrupos", ".js-mmm-novo-cancelar", function () {
      apex.message.clearErrors();
      mmm.fecharGaveta("mmm-novo-grupo");
      if (botaoNovo) { botaoNovo.focus(); }
    })
    // a gaveta do Renomear: Cancelar fecha sem gravar
    .on("click.mmmGrupos", ".js-mmm-renomear-cancelar", function () {
      mmm.fecharGaveta("mmm-renomear");
      if (botaoDoMenu) { botaoDoMenu.focus(); }
    });

})(apex, apex.jQuery);
