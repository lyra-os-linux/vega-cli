#!/usr/bin/env bash
# Módulo "Serviços": listar units systemd (curadas ou todas), habilitar/
# desabilitar, iniciar/parar e reiniciar — equivalente ao módulo Serviços
# do vega-gtk (org.lyraos.Vega1.Services, vega-gtk/src/ui/services.rs +
# vega-gtk/src/application.rs `configure_services`). Sourced pelo
# entrypoint (bin/vega) — não é executável sozinho.

# vega::services::_acoes <name> <label> <description> <enabled> <active> <available>
vega::services::_acoes() {
  local name="$1" label="$2" description="$3" enabled="$4" active="$5" available="$6"

  if [ "$available" != "true" ]; then
    vega::ui::msgbox "$label ($name) não está disponível neste sistema." "Serviços"
    return
  fi

  local -a opts=()
  local habilitar_label="Habilitar"
  [ "$enabled" = "true" ] && habilitar_label="Desabilitar"
  opts+=(habilitar "$habilitar_label")
  local executar_label="Iniciar"
  [ "$active" = "true" ] && executar_label="Parar"
  opts+=(executar "$executar_label")
  [ "$active" = "true" ] && opts+=(reiniciar "Reiniciar")
  opts+=(voltar "Voltar")

  local choice
  choice="$(vega::ui::menu "$label" "$name — $description" "${opts[@]}")" || return

  local verbo detalhe
  case "$choice" in
  habilitar)
    if [ "$enabled" = "true" ]; then
      verbo="Desabilitar"
      detalhe="deixará de iniciar automaticamente e será parado"
    else
      verbo="Habilitar"
      detalhe="iniciará agora e automaticamente com o sistema"
    fi
    vega::ui::yesno "$label ($name) $detalhe." "$verbo serviço?" || return
    vega::ui::infobox "$verbo $label…" "Serviços"
    if vega::dbus::call Services SetServiceEnabled sb "$name" "$([ "$enabled" = "true" ] && echo false || echo true)" >/dev/null; then
      vega::ui::msgbox "$label atualizado." "Serviços"
    else
      vega::ui::msgbox "Falha: $VEGA_DBUS_LAST_ERROR" "Serviços"
    fi
    ;;
  executar)
    if [ "$active" = "true" ]; then
      verbo="Parar"
      detalhe="será interrompido até uma nova inicialização"
    else
      verbo="Iniciar"
      detalhe="será iniciado nesta sessão"
    fi
    vega::ui::yesno "$label ($name) $detalhe." "$verbo serviço?" || return
    vega::ui::infobox "$verbo $label…" "Serviços"
    if vega::dbus::call Services SetServiceRunning sb "$name" "$([ "$active" = "true" ] && echo false || echo true)" >/dev/null; then
      vega::ui::msgbox "$label atualizado." "Serviços"
    else
      vega::ui::msgbox "Falha: $VEGA_DBUS_LAST_ERROR" "Serviços"
    fi
    ;;
  reiniciar)
    vega::ui::yesno "$label ($name) será interrompido e iniciado novamente." "Reiniciar serviço?" || return
    vega::ui::infobox "Reiniciando $label…" "Serviços"
    if vega::dbus::call Services RestartService s "$name" >/dev/null; then
      vega::ui::msgbox "$label reiniciado." "Serviços"
    else
      vega::ui::msgbox "Falha: $VEGA_DBUS_LAST_ERROR" "Serviços"
    fi
    ;;
  esac
}

# vega::services::_listar <"curated"|"all">
vega::services::_listar() {
  local escopo="$1" metodo="ListServices"
  [ "$escopo" = "all" ] && metodo="ListAllServices"

  while true; do
    vega::ui::infobox "Carregando serviços…" "Serviços"
    local data rc=0
    data="$(vega::dbus::call_data Services "$metodo")" || rc=$?
    if [ "$rc" -ne 0 ]; then
      vega::ui::msgbox "Falha ao listar serviços: $VEGA_DBUS_LAST_ERROR" "Serviços"
      return
    fi
    local count
    count="$(printf '%s' "$data" | jq -r '.[0] | length')"
    if [ "$count" -eq 0 ]; then
      vega::ui::msgbox "Nenhum serviço encontrado." "Serviços"
      return
    fi

    local -a names labels descriptions enableds actives availables menu_args=()
    local -a rows
    mapfile -t rows < <(printf '%s' "$data" | jq -r '.[0][] |
      [.[0],.[1],.[2],(.[3]|tostring),(.[4]|tostring),(.[5]|tostring)] | join("")')
    local idx=0 row name label description enabled active available
    for row in "${rows[@]}"; do
      IFS=$'\x1f' read -r name label description enabled active available <<<"$row"
      names[idx]="$name"; labels[idx]="$label"; descriptions[idx]="$description"
      enableds[idx]="$enabled"; actives[idx]="$active"; availables[idx]="$available"
      local marcador=""
      [ "$available" != "true" ] && marcador=" [indisponível]"
      menu_args+=("$idx" "$label — $([ "$active" = "true" ] && echo "Ativo" || echo "Parado") • $([ "$enabled" = "true" ] && echo "Habilitado" || echo "Desabilitado")${marcador}")
      idx=$((idx + 1))
    done
    menu_args+=(voltar "Voltar")

    local choice
    choice="$(vega::ui::menu "Serviços ($count)" "Escolha um serviço:" "${menu_args[@]}")" || return
    [ "$choice" = "voltar" ] && return

    vega::services::_acoes "${names[$choice]}" "${labels[$choice]}" "${descriptions[$choice]}" \
      "${enableds[$choice]}" "${actives[$choice]}" "${availables[$choice]}"
  done
}

vega::module_services() {
  local choice
  while true; do
    choice="$(vega::ui::menu "Serviços" "Escolha uma lista:" \
      principais "Principais" \
      todos "Todos" \
      voltar "Voltar")" || return

    case "$choice" in
    principais) vega::services::_listar curated || true ;;
    todos) vega::services::_listar all || true ;;
    voltar | "") return ;;
    esac
  done
}
