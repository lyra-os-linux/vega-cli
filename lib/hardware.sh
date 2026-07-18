#!/usr/bin/env bash
# Módulo "Hardware e Kernel": inventário de hardware (CPU/GPU/memória/
# firmware), troca de driver NVIDIA, listar/instalar/remover kernels e
# configuração de boot — equivalente ao módulo Hardware e Kernel do
# vega-gtk (org.lyraos.Vega1.Hardware + Kernel, vega-gtk/src/ui/kernel.rs +
# vega-gtk/src/ui/shell.rs). Sourced pelo entrypoint (bin/vega) — não é
# executável sozinho.
#
# Nota: ao contrário de Software/Backup, nem Hardware nem Kernel emitem
# sinal de conclusão nenhum (sem "*Finished" no contrato D-Bus) — não usar
# vega::dbus::run_transaction aqui. SwitchNvidiaDriver, Remove e
# ApplyBootConfig são chamadas síncronas normais (o próprio vegad bloqueia
# até terminar). Só Kernel.Install é "dispare e esqueça": o vegad devolve
# na hora e continua o trabalho real em segundo plano, sem jeito de saber
# via D-Bus quando termina — o vega-gtk lida com isso com uma espera cega
# de alguns segundos antes de atualizar a lista, e aqui fazemos o mesmo.

vega::hardware::_inventario() {
  vega::ui::infobox "Carregando inventário…" "Hardware e Kernel"
  local data rc=0
  data="$(vega::dbus::call_data Hardware Inventory)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    vega::ui::msgbox "Falha ao consultar inventário: $VEGA_DBUS_LAST_ERROR" "Hardware e Kernel"
    return
  fi
  local cpu gpu ram firmware
  cpu="$(printf '%s' "$data" | jq -r '.[0][0]')"
  gpu="$(printf '%s' "$data" | jq -r '.[0][1]')"
  ram="$(printf '%s' "$data" | jq -r '.[0][2]')"
  firmware="$(vega::dbus::call_data Hardware FirmwareStatus | jq -r '.[0]')" || firmware="?"

  vega::ui::msgbox "Processador: $cpu
Vídeo: $gpu
Memória: $ram
Firmware: $firmware" "Inventário"
}

vega::hardware::_trocar_driver() {
  local driver
  driver="$(vega::ui::menu "Trocar driver NVIDIA" "Escolha o driver:" \
    nvidia-open-dkms "nvidia-open-dkms" \
    nvidia-580xx-dkms "nvidia-580xx-dkms" \
    nouveau "nouveau" \
    voltar "Voltar")" || return
  [ "$driver" = "voltar" ] && return

  vega::ui::yesno "Aplicar $driver? O sistema criará um snapshot antes da troca." \
    "Trocar driver NVIDIA?" || return

  vega::ui::infobox "Aplicando driver $driver…" "Hardware e Kernel"
  if vega::dbus::call Hardware SwitchNvidiaDriver s "$driver" >/dev/null; then
    vega::ui::msgbox "Driver $driver aplicado." "Hardware e Kernel"
  else
    vega::ui::msgbox "Falha ao trocar driver: $VEGA_DBUS_LAST_ERROR" "Hardware e Kernel"
  fi
}

# ---------------------------------------------------------------------------
# Kernel

vega::hardware::_kernel_remover() {
  local kernel="$1" count="$2"
  if [ "$count" -le 1 ]; then
    vega::ui::msgbox "\"$kernel\" é o único kernel instalado — não é possível removê-lo." "Kernel"
    return
  fi
  vega::ui::yesno "Remover $kernel? O daemon recusará o kernel em execução ou o último kernel instalado." \
    "Remover kernel?" || return

  vega::ui::infobox "Removendo kernel…" "Kernel"
  if vega::dbus::call Kernel Remove s "$kernel" >/dev/null; then
    vega::ui::msgbox "Kernel $kernel removido." "Kernel"
  else
    vega::ui::msgbox "Falha ao remover: $VEGA_DBUS_LAST_ERROR" "Kernel"
  fi
}

vega::hardware::_kernel_instalados() {
  while true; do
    vega::ui::infobox "Carregando kernels instalados…" "Kernel"
    local data rc=0
    data="$(vega::dbus::call_data Kernel ListInstalled)" || rc=$?
    if [ "$rc" -ne 0 ]; then
      vega::ui::msgbox "Falha ao listar kernels instalados: $VEGA_DBUS_LAST_ERROR" "Kernel"
      return
    fi
    local count
    count="$(printf '%s' "$data" | jq -r '.[0] | length')"
    if [ "$count" -eq 0 ]; then
      vega::ui::msgbox "Nenhum kernel listado." "Kernels instalados"
      return
    fi

    local -a kernels menu_args=()
    mapfile -t kernels < <(printf '%s' "$data" | jq -r '.[0][]')
    local k
    for k in "${kernels[@]}"; do
      menu_args+=("$k" "$k")
    done
    menu_args+=(voltar "Voltar")

    local choice
    choice="$(vega::ui::menu "Kernels instalados" "Escolha um kernel:" "${menu_args[@]}")" || return
    [ "$choice" = "voltar" ] && return
    vega::hardware::_kernel_remover "$choice" "$count"
  done
}

vega::hardware::_kernel_disponiveis() {
  while true; do
    vega::ui::infobox "Carregando kernels disponíveis…" "Kernel"
    local available_data installed_data rc=0
    available_data="$(vega::dbus::call_data Kernel AvailablePackages)" || rc=$?
    if [ "$rc" -ne 0 ]; then
      vega::ui::msgbox "Falha ao listar kernels disponíveis: $VEGA_DBUS_LAST_ERROR" "Kernel"
      return
    fi
    installed_data="$(vega::dbus::call_data Kernel ListInstalled)" || rc=$?
    if [ "$rc" -ne 0 ]; then
      vega::ui::msgbox "Falha ao listar kernels instalados: $VEGA_DBUS_LAST_ERROR" "Kernel"
      return
    fi

    # AvailablePackages traz todo pacote de kernel instalável, não só os
    # ainda não instalados — a comparação (case-insensitive, igual ao
    # vega-gtk) é o que sobra pra "disponíveis" de verdade.
    local -a kernels
    mapfile -t kernels < <(jq -rn --argjson avail "$available_data" --argjson inst "$installed_data" '
      ($inst[0] // [] | map(ascii_downcase)) as $installed_lower
      | ($avail[0] // [])[]
      | select( (. | ascii_downcase) as $l | ($installed_lower | index($l)) == null )
    ')

    if [ "${#kernels[@]}" -eq 0 ]; then
      vega::ui::msgbox "Todos os kernels disponíveis já estão instalados." "Kernels disponíveis"
      return
    fi

    local -a menu_args=()
    local k
    for k in "${kernels[@]}"; do
      menu_args+=("$k" "$k")
    done
    menu_args+=(voltar "Voltar")

    local choice
    choice="$(vega::ui::menu "Kernels disponíveis" "Escolha um kernel para instalar:" "${menu_args[@]}")" || return
    [ "$choice" = "voltar" ] && return

    vega::ui::yesno "Instalar $choice? O vegad criará um snapshot quando possível e reconstruirá os artefatos de boot." \
      "Instalar kernel?" || continue

    vega::ui::infobox "Solicitando instalação do kernel…" "Kernel"
    if ! vega::dbus::call Kernel Install s "$choice" >/dev/null; then
      vega::ui::msgbox "Falha ao solicitar instalação: $VEGA_DBUS_LAST_ERROR" "Kernel"
      continue
    fi
    # Install só confirma que o vegad aceitou o pedido — o trabalho real
    # (baixar, instalar, reconstruir artefatos de boot) continua em segundo
    # plano sem sinal de conclusão. Esperamos um pouco antes de atualizar a
    # lista, igual ao vega-gtk (timeout_future_seconds(3)) — é só uma
    # estimativa, não confirma que já terminou.
    vega::ui::infobox "Instalação iniciada. Atualizando a lista…" "Kernel"
    sleep 3
  done
}

vega::hardware::_kernel_boot() {
  vega::ui::infobox "Carregando configuração de boot…" "Kernel"
  local status_data rc=0
  status_data="$(vega::dbus::call_data Kernel BootStatus)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    vega::ui::msgbox "Falha ao consultar configuração de boot: $VEGA_DBUS_LAST_ERROR" "Kernel"
    return
  fi
  local loader default_entry timeout cmdline
  loader="$(printf '%s' "$status_data" | jq -r '.[0][0]')"
  default_entry="$(printf '%s' "$status_data" | jq -r '.[0][1]')"
  timeout="$(printf '%s' "$status_data" | jq -r '.[0][2]')"
  cmdline="$(printf '%s' "$status_data" | jq -r '.[0][3]')"

  if [ -z "$loader" ]; then
    vega::ui::msgbox "Bootloader não detectado." "Configuração de boot"
    return
  fi

  local entries_data
  entries_data="$(vega::dbus::call_data Kernel ListBootEntries)" || entries_data='[[]]'
  local entries_joined
  entries_joined="$(printf '%s' "$entries_data" | jq -r '.[0] | if length == 0 then "Nenhuma entrada listada" else join(" • ") end')"

  vega::ui::msgbox "Detectado: $loader
Entrada padrão: ${default_entry:-Padrão atual}
Timeout: $timeout segundos
Parâmetros: ${cmdline:-Nenhum parâmetro adicional}
Entradas: $entries_joined" "Configuração de boot"

  vega::ui::yesno "Editar a configuração de boot?" "Configuração de boot" || return

  local -a entry_menu_args=(manter "Manter atual (${default_entry:-padrão atual})")
  local -a entries
  mapfile -t entries < <(printf '%s' "$entries_data" | jq -r '.[0][]')
  local e
  for e in "${entries[@]}"; do
    entry_menu_args+=("$e" "$e")
  done
  local novo_entry
  novo_entry="$(vega::ui::menu "Entrada padrão" "Escolha a entrada padrão:" "${entry_menu_args[@]}")" || return
  [ "$novo_entry" = "manter" ] && novo_entry="$default_entry"

  local novo_timeout
  novo_timeout="$(vega::ui::inputbox "Timeout" "Timeout em segundos:" "$timeout")" || return
  case "$novo_timeout" in
  '' | *[!0-9]*)
    vega::ui::msgbox "Informe um número inteiro para o timeout." "Configuração de boot"
    return
    ;;
  esac

  local novo_cmdline
  novo_cmdline="$(vega::ui::inputbox "Parâmetros do kernel" "Parâmetros do kernel:" "$cmdline")" || return

  vega::ui::yesno "Aplicar entrada padrão '${novo_entry:-padrão atual}', timeout de $novo_timeout segundo(s) e os parâmetros informados? Um snapshot será criado quando possível." \
    "Alterar configuração de boot?" || return

  vega::ui::infobox "Aplicando configuração de boot…" "Kernel"
  if vega::dbus::call Kernel ApplyBootConfig sus "$novo_entry" "$novo_timeout" "$novo_cmdline" >/dev/null; then
    vega::ui::msgbox "Configuração de boot atualizada." "Kernel"
  else
    vega::ui::msgbox "Falha ao aplicar configuração de boot: $VEGA_DBUS_LAST_ERROR" "Kernel"
  fi
}

vega::hardware::_kernel() {
  local choice
  while true; do
    choice="$(vega::ui::menu "Kernel" "Escolha uma área:" \
      instalados "Kernels instalados" \
      disponiveis "Kernels disponíveis" \
      boot "Configuração de boot" \
      voltar "Voltar")" || return

    case "$choice" in
    instalados) vega::hardware::_kernel_instalados || true ;;
    disponiveis) vega::hardware::_kernel_disponiveis || true ;;
    boot) vega::hardware::_kernel_boot || true ;;
    voltar | "") return ;;
    esac
  done
}

# ---------------------------------------------------------------------------

vega::module_hardware() {
  local choice
  while true; do
    choice="$(vega::ui::menu "Hardware e Kernel" "Escolha uma área:" \
      inventario "Inventário" \
      driver "Trocar driver NVIDIA" \
      kernel "Kernel" \
      voltar "Voltar")" || return

    case "$choice" in
    inventario) vega::hardware::_inventario || true ;;
    driver) vega::hardware::_trocar_driver || true ;;
    kernel) vega::hardware::_kernel || true ;;
    voltar | "") return ;;
    esac
  done
}
