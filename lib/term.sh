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

# Sessões SSH normalmente não têm agente polkit gráfico registrado, então
# qualquer método do vegad que exija autorização (requirePolkit()) falharia
# silenciosamente. pkttyagent registra um agente baseado em terminal para
# este processo, que passa a poder pedir senha diretamente no TTY atual.
# Não é fatal se faltar: módulos read-only continuam funcionando, ações
# privilegiadas é que vão falhar na autorização quando chamadas.
vega::install_pkttyagent() {
  if ! command -v pkttyagent >/dev/null 2>&1; then
    return 0
  fi
  pkttyagent --process $$ >/dev/null 2>&1 &
  VEGA_PKTTYAGENT_PID=$!
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
