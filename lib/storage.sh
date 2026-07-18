#!/usr/bin/env bash
# Módulo "Armazenamento": listar volumes/discos e montar/desmontar —
# equivalente ao módulo Armazenamento do vega-gtk
# (org.lyraos.Vega1.Storage, vega-gtk/src/ui/storage.rs +
# vega-gtk/src/application.rs `configure_storage`). Sourced pelo
# entrypoint (bin/vega) — não é executável sozinho.

vega::module_storage() {
  while true; do
    vega::ui::infobox "Carregando volumes…" "Armazenamento"
    local data rc=0
    data="$(vega::dbus::call_data Storage ListVolumes)" || rc=$?
    if [ "$rc" -ne 0 ]; then
      vega::ui::msgbox "Falha ao listar volumes: $VEGA_DBUS_LAST_ERROR" "Armazenamento"
      return
    fi
    local count
    count="$(printf '%s' "$data" | jq -r '.[0] | length')"
    if [ "$count" -eq 0 ]; then
      vega::ui::msgbox "Nenhum volume detectado." "Armazenamento"
      return
    fi

    local -a names paths types fstypes sizes useds avails usepercents mountpoints models removables canmounts canunmounts
    local -a menu_args=()
    local -a rows
    mapfile -t rows < <(printf '%s' "$data" | jq -r '.[0][] |
      [.[0],.[1],.[2],.[3],.[4],.[5],.[6],(.[7]|tostring),.[8],.[9],(.[10]|tostring),(.[11]|tostring),(.[12]|tostring)] | join("\u001f")')
    local idx=0 row name path type fstype size used avail usepercent mountpoint model removable canmount canunmount
    for row in "${rows[@]}"; do
      IFS=$'\x1f' read -r name path type fstype size used avail usepercent mountpoint model removable canmount canunmount <<<"$row"
      names[idx]="$name"; paths[idx]="$path"; types[idx]="$type"; fstypes[idx]="$fstype"
      sizes[idx]="$size"; useds[idx]="$used"; avails[idx]="$avail"; usepercents[idx]="$usepercent"
      mountpoints[idx]="$mountpoint"; models[idx]="$model"; removables[idx]="$removable"
      canmounts[idx]="$canmount"; canunmounts[idx]="$canunmount"

      local titulo="$name • $path"
      [ -n "$model" ] && titulo="$model • $path"
      local montagem="Não montado"
      [ -n "$mountpoint" ] && montagem="Montado em $mountpoint"
      local removivel=""
      [ "$removable" = "true" ] && removivel=" [Removível]"
      menu_args+=("$idx" "$titulo — ${fstype:-sem filesystem} • $montagem${removivel}")
      idx=$((idx + 1))
    done
    menu_args+=(voltar "Voltar")

    local choice
    choice="$(vega::ui::menu "Armazenamento" "Escolha um volume:" "${menu_args[@]}")" || return
    [ "$choice" = "voltar" ] && return

    local path="${paths[$choice]}" mountpoint="${mountpoints[$choice]}"
    local uso="${sizes[$choice]}"
    [ -n "${useds[$choice]}" ] && uso="${useds[$choice]} usados de ${sizes[$choice]} • ${usepercents[$choice]}%"

    vega::ui::msgbox "Nome: ${names[$choice]}
Caminho: $path
Modelo: ${models[$choice]:-—}
Tipo: ${types[$choice]}
Sistema de arquivos: ${fstypes[$choice]:-sem filesystem}
Uso: $uso
Ponto de montagem: ${mountpoint:-não montado}
Removível: $([ "${removables[$choice]}" = "true" ] && echo "Sim" || echo "Não")" "${names[$choice]}"

    if [ "${canunmounts[$choice]}" = "true" ]; then
      vega::ui::yesno "$path (${mountpoint:-não montado})" "Desmontar volume?" || continue
      vega::ui::infobox "Desmontando $path…" "Armazenamento"
      if vega::dbus::call Storage Unmount s "$path" >/dev/null; then
        vega::ui::msgbox "Volume desmontado." "Armazenamento"
      else
        vega::ui::msgbox "Falha ao desmontar: $VEGA_DBUS_LAST_ERROR" "Armazenamento"
      fi
    elif [ "${canmounts[$choice]}" = "true" ]; then
      vega::ui::yesno "$path (${mountpoint:-não montado})" "Montar volume?" || continue
      vega::ui::infobox "Montando $path…" "Armazenamento"
      if vega::dbus::call Storage Mount s "$path" >/dev/null; then
        vega::ui::msgbox "Volume montado." "Armazenamento"
      else
        vega::ui::msgbox "Falha ao montar: $VEGA_DBUS_LAST_ERROR" "Armazenamento"
      fi
    else
      vega::ui::msgbox "Nenhuma ação disponível para este volume." "Armazenamento"
    fi
  done
}
