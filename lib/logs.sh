#!/usr/bin/env bash
# Módulo "Log do Sistema": consulta somente leitura do journal por
# unidade/prioridade/período/texto — equivalente ao módulo Log do Sistema
# do vega-gtk (org.lyraos.Vega1.Logs, vega-gtk/src/ui/logs.rs). Sourced
# pelo entrypoint (bin/vega) — não é executável sozinho.
#
# Logs não exige polkit (é leitura do journal, que o usuário já poderia
# rodar sozinho via journalctl) — nenhuma chamada aqui é mutável.

vega::module_logs() {
  vega::ui::infobox "Carregando unidades do journal…" "Log do Sistema"
  local units_data rc=0
  units_data="$(vega::dbus::call_data Logs ListUnits)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    vega::ui::msgbox "Falha ao listar unidades: $VEGA_DBUS_LAST_ERROR" "Log do Sistema"
    return
  fi

  local -a unit_menu_args=(todas "Todas as unidades")
  local -a units
  mapfile -t units < <(printf '%s' "$units_data" | jq -r '.[0][]')
  local u
  for u in "${units[@]}"; do
    unit_menu_args+=("$u" "$u")
  done
  local unit
  unit="$(vega::ui::menu "Unidade" "Escolha a unidade:" "${unit_menu_args[@]}")" || return
  [ "$unit" = "todas" ] && unit=""

  local priority
  priority="$(vega::ui::menu "Prioridade" "Escolha a prioridade mínima:" \
    todas "Todas as prioridades" \
    err "Erro ou mais grave" \
    warning "Aviso ou mais grave" \
    info "Informação ou mais grave" \
    debug "Tudo, incluindo debug")" || return
  [ "$priority" = "todas" ] && priority=""

  local since
  since="$(vega::ui::menu "Período" "Escolha o período:" \
    -15min "Últimos 15 min" \
    -1hour "Última hora" \
    -24hour "Últimas 24h" \
    -7day "Últimos 7 dias" \
    semlimite "Sem limite de período")" || return
  [ "$since" = "semlimite" ] && since=""

  local search
  search="$(vega::ui::inputbox "Buscar" "Buscar texto no log (opcional):")" || return

  local limite
  limite="$(vega::ui::menu "Limite" "Quantas linhas trazer:" \
    100 "100 linhas" \
    250 "250 linhas" \
    500 "500 linhas" \
    1000 "1.000 linhas")" || return

  vega::ui::infobox "Consultando o journal…" "Log do Sistema"
  local data
  data="$(vega::dbus::call_data Logs Query ssssu "$unit" "$priority" "$since" "$search" "$limite")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    vega::ui::msgbox "Falha ao consultar logs: $VEGA_DBUS_LAST_ERROR" "Log do Sistema"
    return
  fi

  local count
  count="$(printf '%s' "$data" | jq -r '.[0] | length')"
  if [ "$count" -eq 0 ]; then
    vega::ui::msgbox "Nenhuma entrada encontrada para os filtros selecionados." "Log do Sistema"
    return
  fi

  local tmpfile
  tmpfile="$(mktemp)"
  printf '%s' "$data" | jq -r '.[0][]' >"$tmpfile"
  vega::ui::textbox "$tmpfile" "Log do Sistema ($count linha(s))"
  rm -f "$tmpfile"
}
