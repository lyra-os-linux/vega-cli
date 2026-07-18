#!/usr/bin/env bash
# Módulo "Data, Hora e Idioma": timezone, NTP, locale e layout de teclado —
# equivalente ao módulo Data, Hora e Idioma do vega-gtk
# (org.lyraos.Vega1.DateTime, vega-gtk/src/ui/datetime.rs +
# vega-gtk/src/application.rs `configure_datetime`). Sourced pelo
# entrypoint (bin/vega) — não é executável sozinho.
#
# Apply(timezone, ntp, locale, keymap) sempre aplica os quatro campos numa
# única chamada — timezone/locale/keymap vazios são ignorados pelo vegad,
# mas o NTP é sempre reaplicado (não há como só "não mexer" no NTP num
# Apply parcial). Por isso, igual ao vega-gtk, sempre reenviamos os quatro
# valores atuais/editados juntos, nunca um campo isolado.

# vega::datetime::_sanear <valor>
# `localectl status` às vezes imprime "X11 Layout: (unset)" quando não há
# layout configurado, e o vegad devolve isso literalmente em Status() como
# se fosse um valor de teclado válido — reenviar isso pro Apply seria
# passar um layout inexistente pro localectl (não dá erro, mas é lixo sem
# sentido). Trata como "vazio" pra o Apply simplesmente não mexer no campo.
vega::datetime::_sanear() {
  case "$1" in
  "(unset)") printf '' ;;
  *) printf '%s' "$1" ;;
  esac
}

# vega::datetime::_escolher <título> <prompt> <atual> <lista de opções (uma por linha)>
# Menu de seleção a partir de uma lista grande (timezones/locales/keymaps).
# Se o usuário cancelar (Esc), mantém o valor atual.
vega::datetime::_escolher() {
  local title="$1" prompt="$2" atual="$3"
  shift 3
  local -a opcoes=("$@")
  local -a menu_args=()
  local o
  for o in "${opcoes[@]}"; do
    menu_args+=("$o" "$o")
  done
  local escolha
  escolha="$(vega::ui::menu "$title" "$prompt (atual: $atual)" "${menu_args[@]}")" || escolha="$atual"
  printf '%s' "$escolha"
}

vega::module_datetime() {
  vega::ui::infobox "Carregando data, hora e idioma…" "Data, Hora e Idioma"
  local status_data rc=0
  status_data="$(vega::dbus::call_data DateTime Status)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    vega::ui::msgbox "Falha ao consultar configuração: $VEGA_DBUS_LAST_ERROR" "Data, Hora e Idioma"
    return
  fi
  local timezone ntp locale keymap
  timezone="$(printf '%s' "$status_data" | jq -r '.[0][0]')"
  ntp="$(printf '%s' "$status_data" | jq -r '.[0][1]')"
  locale="$(printf '%s' "$status_data" | jq -r '.[0][2]')"
  keymap="$(printf '%s' "$status_data" | jq -r '.[0][3]')"

  vega::ui::yesno "Fuso horário: $timezone
NTP: $([ "$ntp" = "true" ] && echo "Ativado" || echo "Desativado")
Idioma/locale: $locale
Teclado: $keymap

Editar essa configuração?" "Data, Hora e Idioma" || return

  local -a timezones locales keymaps
  mapfile -t timezones < <(vega::dbus::call_data DateTime ListTimezones | jq -r '.[0][]')
  mapfile -t locales < <(vega::dbus::call_data DateTime ListLocales | jq -r '.[0][]')
  mapfile -t keymaps < <(vega::dbus::call_data DateTime ListKeymaps | jq -r '.[0][]')

  local novo_timezone novo_locale novo_keymap
  novo_timezone="$(vega::datetime::_escolher "Fuso horário" "Escolha o fuso horário:" "$timezone" "${timezones[@]}")"
  novo_locale="$(vega::datetime::_escolher "Idioma/locale" "Escolha o idioma/locale:" "$locale" "${locales[@]}")"
  novo_keymap="$(vega::datetime::_escolher "Teclado" "Escolha o layout de teclado:" "$(vega::datetime::_sanear "$keymap")" "${keymaps[@]}")"
  novo_keymap="$(vega::datetime::_sanear "$novo_keymap")"

  local novo_ntp="false" ntp_palavra="desativado"
  if vega::ui::yesno "Ativar sincronização automática de hora (NTP)?" "NTP"; then
    novo_ntp="true"
    ntp_palavra="ativado"
  fi

  vega::ui::yesno "Aplicar timezone $novo_timezone, locale $novo_locale, teclado ${novo_keymap:-(não alterado)} e NTP $ntp_palavra para todo o sistema?" \
    "Alterar data, hora e idioma?" || return

  vega::ui::infobox "Aplicando configuração global…" "Data, Hora e Idioma"
  if vega::dbus::call DateTime Apply sbss "$novo_timezone" "$novo_ntp" "$novo_locale" "$novo_keymap" >/dev/null; then
    vega::ui::msgbox "Configuração de data, hora e idioma atualizada." "Data, Hora e Idioma"
  else
    vega::ui::msgbox "Falha ao aplicar: $VEGA_DBUS_LAST_ERROR" "Data, Hora e Idioma"
  fi
}
