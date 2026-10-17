// Match My Movie: página 4, Membros e convite (#APP_FILES#mmm-membros.js?v=N nas File URLs da página).
// Tornar dono, Remover, Gerar novo link e Excluir grupo pedem confirmação antes; o servidor confere tudo de novo.
(function (apex, $) {
  "use strict";

  // unsafe: o APEX escapa o texto, que leva o apelido (dado de quem usa o app)
  function confirmar(texto, rotulo, estilo, fn) {
    apex.message.confirm(texto, function (ok) {
      if (ok) { fn(); }
    }, { unsafe: true, style: estilo, confirmLabel: rotulo, cancelLabel: "Cancelar" });
  }

  // a ação da linha só põe o id num item oculto e submete: quem grava é o processo da página, nunca um GET
  function acaoDaLinha(request, texto, rotulo, estilo) {
    return function (e) {
      e.preventDefault();
      var id = this.dataset.id;
      var nome = this.dataset.nome || "esta pessoa";
      confirmar(texto(nome), rotulo, estilo, function () {
        apex.item("P4_ID_MEMBRO").setValue(id);
        apex.submit({ request: request });
      });
    };
  }

  $(document)
    .off(".mmmMembros")
    .on("click.mmmMembros", ".js-mmm-remover", acaoDaLinha("REMOVER", function (nome) {
      return "Remover " + nome + " do grupo? O link de convite atual deixa de valer.";
    }, "Remover", "danger"))
    .on("click.mmmMembros", ".js-mmm-tornar-dono", acaoDaLinha("TORNAR_DONO", function (nome) {
      return "Passar o papel de dono para " + nome + "? Você continua no grupo.";
    }, "Passar o papel"))
    // só o dono vê o botão; a confirmação diz o que some e para quem, porque não dá para desfazer
    .on("click.mmmMembros", ".js-mmm-excluir-grupo", function () {
      var outros = Number(this.dataset.outros) || 0;
      var nome = this.dataset.nome || "este grupo";
      confirmar("Excluir o grupo " + nome + (outros ? " para todos?" : "?") + " A lista, as sessões e o histórico do grupo " +
        "são apagados" + (outros ? " para você e " + (outros === 1 ? "mais 1 pessoa" : "mais " + outros + " pessoas") : "") +
        ", e não dá para desfazer.", "Excluir o grupo", "danger", function () {
        apex.submit({ request: "EXCLUIR_GRUPO" });
      });
    })
    // as ações da linha são links com papel de botão: o espaço também aciona
    .on("keydown.mmmMembros", ".js-mmm-remover, .js-mmm-tornar-dono", function (e) {
      if (e.key === " ") {
        e.preventDefault();
        this.click();
      }
    })
    .on("click.mmmMembros", ".js-mmm-novo-link", function () {
      var botao = this;
      confirmar("O link atual deixa de valer. Gerar um novo?", "Gerar novo link", null, function () {
        mmm.chamar("MMM_CONVITE_NOVO").then(function (r) {
          apex.item("P4_CONVITE_URL").setValue(r.link);
          document.querySelectorAll(".js-mmm-compartilhar").forEach(function (b) {
            b.dataset.url = r.link;
          });
          mmm.toast("Link novo pronto. O anterior deixou de valer.");
          botao.focus();
        }, mmm.erro);
      });
    });
})(apex, apex.jQuery);
