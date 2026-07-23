#!/usr/bin/env bash
# Wrappers finos sobre `dialog` — todo lugar que precisar de uma tela usa
# essas funções em vez de chamar `dialog` direto, pra manter
# --backtitle/--stdout consistentes em todo o vega-cli. Sourced pelo
# entrypoint (bin/vega) — não é executável sozinho.

VEGA_BACKTITLE="Lyra Vega - Enterprise Control Center"
readonly VEGA_BACKTITLE

# vega::ui::menu <título> <prompt> <tag1> <item1> [<tag2> <item2> ...]
# Imprime a tag escolhida em stdout; retorna != 0 se o usuário cancelar
# (Esc ou "Cancelar") — o chamador decide o que fazer com isso.
vega::ui::menu() {
  local title="$1" prompt="$2"
  shift 2
  dialog --backtitle "$VEGA_BACKTITLE" \
    --title "$title" \
    --stdout \
    --menu "$prompt" 0 0 0 \
    "$@"
}

# vega::ui::msgbox <texto> [título]
vega::ui::msgbox() {
  local text="$1" title="${2:-}"
  local args=(--backtitle "$VEGA_BACKTITLE")
  [ -n "$title" ] && args+=(--title "$title")
  dialog "${args[@]}" --msgbox "$text" 0 0
}

# vega::ui::yesno <texto> [título]
# Retorna 0 se o usuário confirmar ("Sim"), != 0 em "Não"/Esc/Cancelar.
vega::ui::yesno() {
  local text="$1" title="${2:-}"
  local args=(--backtitle "$VEGA_BACKTITLE")
  [ -n "$title" ] && args+=(--title "$title")
  dialog "${args[@]}" --yesno "$text" 0 0
}

# vega::ui::inputbox <título> <prompt> [valor inicial]
# Imprime o texto digitado em stdout; retorna != 0 se o usuário cancelar.
vega::ui::inputbox() {
  local title="$1" prompt="$2" init="${3:-}"
  dialog --backtitle "$VEGA_BACKTITLE" \
    --title "$title" \
    --stdout \
    --inputbox "$prompt" 0 0 "$init"
}

# vega::ui::passwordbox <título> <prompt>
# Como inputbox, mas sem exibir os caracteres digitados.
vega::ui::passwordbox() {
  local title="$1" prompt="$2"
  dialog --backtitle "$VEGA_BACKTITLE" \
    --title "$title" \
    --stdout \
    --insecure \
    --passwordbox "$prompt" 0 0
}

# vega::ui::infobox <texto> [título]
# Desenha e retorna na hora, sem esperar tecla — pra mensagens de "aguarde"
# antes de uma chamada D-Bus que pode demorar.
vega::ui::infobox() {
  local text="$1" title="${2:-}"
  local args=(--backtitle "$VEGA_BACKTITLE")
  [ -n "$title" ] && args+=(--title "$title")
  dialog "${args[@]}" --infobox "$text" 0 0
}

# vega::ui::textbox <arquivo> [título]
# Mostra um arquivo num visualizador paginável (setas/PgUp/PgDn/busca com
# "/") — usado pra saídas potencialmente longas (ex.: logs do journal).
vega::ui::textbox() {
  local file="$1" title="${2:-}"
  local args=(--backtitle "$VEGA_BACKTITLE")
  [ -n "$title" ] && args+=(--title "$title")
  dialog "${args[@]}" --textbox "$file" 0 0
}

# vega::ui::tailbox <arquivo> [título]
# Como textbox, mas acompanha o crescimento do arquivo (igual `tail -f`) —
# usado pra telas que se atualizam periodicamente (ex.: métricas do
# Monitor), onde algum processo em background vai anexando linhas novas.
vega::ui::tailbox() {
  local file="$1" title="${2:-}"
  local args=(--backtitle "$VEGA_BACKTITLE")
  [ -n "$title" ] && args+=(--title "$title")
  dialog "${args[@]}" --tailbox "$file" 0 0
}

# vega::ui::checklist <título> <prompt> <tag1> <item1> <status1> ...
# <statusN> é "on"/"off". Imprime uma tag marcada por linha em stdout
# (--separate-output); retorna != 0 se o usuário cancelar.
vega::ui::checklist() {
  local title="$1" prompt="$2"
  shift 2
  dialog --backtitle "$VEGA_BACKTITLE" \
    --title "$title" \
    --stdout \
    --separate-output \
    --checklist "$prompt" 0 0 0 \
    "$@"
}
