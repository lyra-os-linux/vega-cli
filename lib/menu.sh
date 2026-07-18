#!/usr/bin/env bash
# Menu principal e navegação entre módulos. Sourced pelo entrypoint
# (bin/vega) — não é executável sozinho.
#
# Todos os módulos desta versão (#105-#115) já estão implementados —
# "sobre" continua sendo o único item que não vem de um módulo próprio,
# por não ter equivalente no vega-gtk.

vega::module_about() {
  vega::ui::msgbox \
    "Lyra Vega - Enterprise Control Center\nInterface de terminal\nVersão: ${VEGA_CLI_VERSION}" \
    "Sobre"
}

vega::main_menu() {
  local choice
  while true; do
    choice="$(vega::ui::menu "Vega" "Escolha um módulo:" \
      painel        "Painel" \
      software      "Software" \
      backup        "Backup e Pontos de Restauração" \
      hardware      "Hardware e Kernel" \
      usuarios      "Usuários" \
      rede          "Rede e Firewall" \
      servicos      "Serviços" \
      datahora      "Data, Hora e Idioma" \
      armazenamento "Armazenamento" \
      logs          "Log do Sistema" \
      monitor       "Monitor do Sistema" \
      sobre         "Sobre" \
      sair          "Sair")" || break # Esc/Cancelar também sai.

    # "|| true" em cada módulo: sob set -e, uma tela interna terminando com
    # o usuário em Esc/Não (código != 0) só deve voltar pra este menu, não
    # derrubar a sessão inteira — sem isso, fechar qualquer msgbox com Esc
    # mataria o vega-cli na hora.
    case "$choice" in
    painel) vega::module_painel || true ;;
    software) vega::module_software || true ;;
    backup) vega::module_backup || true ;;
    hardware) vega::module_hardware || true ;;
    usuarios) vega::module_users || true ;;
    rede) vega::module_network || true ;;
    servicos) vega::module_services || true ;;
    datahora) vega::module_datetime || true ;;
    armazenamento) vega::module_storage || true ;;
    logs) vega::module_logs || true ;;
    monitor) vega::module_monitor || true ;;
    sobre) vega::module_about || true ;;
    sair | "") break ;;
    esac
  done
}
