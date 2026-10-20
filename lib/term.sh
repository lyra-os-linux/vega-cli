#!/usr/bin/env bash
# Ambiente de execução: checagens de pré-requisito e limpeza do terminal.
# Sourced pelo entrypoint (bin/vega) — não é executável sozinho.

# vega::configure_theme <vega_cli_root>
# Aplica o tema azul escuro do vega-cli exportando DIALOGRC — dialog lê essa
# variável antes de cair no ~/.dialogrc do usuário ou nas cores padrão. Não
# sobrescreve um DIALOGRC já definido pelo usuário no ambiente.
vega::configure_theme() {
  local root="$1"
  [ -n "${DIALOGRC:-}" ] && return 0
  export DIALOGRC="$root/lib/theme.dialogrc"
}

vega::require_dialog() {
  if ! command -v dialog >/dev/null 2>&1; then
    echo "vega: o comando 'dialog' não está instalado." >&2
    echo "Instale o pacote 'dialog' da sua distribuição e tente de novo." >&2
    exit 1
  fi
}

# busctl (systemd) e jq são a base do acesso a D-Bus (lib/dbus.sh) — sem
# eles nenhum módulo real consegue falar com o vegad.
vega::require_dbus_tools() {
  local missing=()
  command -v busctl >/dev/null 2>&1 || missing+=("busctl (systemd)")
  command -v jq >/dev/null 2>&1 || missing+=("jq")
  /usr/bin/python3 -c 'from gi.repository import Gio, GLib' >/dev/null 2>&1 || missing+=("python3 / python3-gobject (Gio)")
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "vega: dependência(s) faltando: ${missing[*]}." >&2
    echo "Instale o(s) pacote(s) da sua distribuição e tente de novo." >&2
    exit 1
  fi
}

vega::require_tty() {
  if [ ! -t 0 ] || [ ! -t 1 ]; then
    echo "vega: precisa rodar num terminal interativo (TTY)." >&2
    exit 1
  fi
}

# PID do pkttyagent registrado por vega::install_pkttyagent, pra matar no
# cleanup — vazio se pkttyagent não estiver instalado ou não tiver sido
# iniciado ainda.
VEGA_PKTTYAGENT_PID=""
# 1 quando cada chamada ao vegad deve levar um pkttyagent próprio
# (vega::dbus::_with_agent). Fica 0 sem pkttyagent ou fora de um TTY.
VEGA_PKTTYAGENT=0

# Sessões SSH normalmente não têm agente polkit gráfico registrado, então
# qualquer método do vegad que exija autorização (requirePolkit()) falharia.
# O vegad pergunta ao polkit pelo remetente D-Bus da chamada, que é o
# processo do busctl (ou do helper de transações), não este shell; um
# agente registrado com --process $$ nunca era encontrado e o polkit
# respondia "no agent is available" (vega-cli#26, gate da Server 16.1 RC 2).
# Por isso o agente é registrado por chamada, para o PID do próprio comando
# — ver vega::dbus::_with_agent. Aqui só se decide se isso está disponível.
# Não é fatal se faltar: módulos read-only continuam funcionando, ações
# privilegiadas é que vão falhar na autorização quando chamadas.
vega::install_pkttyagent() {
  if ! command -v pkttyagent >/dev/null 2>&1 || ! command -v mkfifo >/dev/null 2>&1; then
    return 0
  fi
  [ -t 0 ] || return 0
  VEGA_PKTTYAGENT=1
}

vega::cleanup_pkttyagent() {
  if [ -n "$VEGA_PKTTYAGENT_PID" ]; then
    kill "$VEGA_PKTTYAGENT_PID" >/dev/null 2>&1 || true
    VEGA_PKTTYAGENT_PID=""
  fi
}

# dialog desenha por cima da tela atual; sem isso, sair (inclusive via
# Ctrl+C) deixa o terminal do usuário com a última tela do dialog "colada"
# até o próximo clear manual. Também derruba o pkttyagent registrado em
# vega::install_pkttyagent — ele não deve sobreviver à sessão do vega-cli.
vega::install_cleanup_trap() {
  trap 'vega::cleanup_pkttyagent; clear' EXIT INT TERM
}
