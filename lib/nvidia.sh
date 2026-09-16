#!/usr/bin/env bash
# Optional qualified RPM installation. Reads never request authorization.
vega::nvidia::text() {
  local pt="$1" en="$2" es="$3"
  case "${VEGA_NVIDIA_LOCALE:-en-US}" in
    pt-*) printf '%s' "$pt" ;;
    es-*) printf '%s' "$es" ;;
    *) printf '%s' "$en" ;;
  esac
}

vega::nvidia::state() {
  case "$1" in
    available) vega::nvidia::text 'Disponível para instalação' 'Available to install' 'Disponible para instalar' ;;
    unmanaged) vega::nvidia::text 'Driver oficial instalado; falta a integração Lyra' 'Official driver installed; Lyra integration is missing' 'Controlador oficial instalado; falta la integración Lyra' ;;
    active) vega::nvidia::text 'Driver ativo e verificado' 'Driver active and verified' 'Controlador activo y verificado' ;;
    reboot-required) vega::nvidia::text 'Reinicialização necessária' 'Restart required' 'Es necesario reiniciar' ;;
    no-gpu) vega::nvidia::text 'Nenhuma GPU NVIDIA detectada' 'No NVIDIA GPU detected' 'No se detectó ninguna GPU NVIDIA' ;;
    *) vega::nvidia::text 'Instalação bloqueada; confira o diagnóstico' 'Installation blocked; review the diagnostics' 'Instalación bloqueada; revise el diagnóstico' ;;
  esac
}

vega::nvidia::recovery_help() {
  local kind="$1" reference="$2"
  if [ "$kind" = restic-offline ]; then
    vega::nvidia::text \
      'Recuperação ext4: cópia local verificada do sistema. Restauração somente por mídia de recuperação, com a raiz original montada. Dados dos serviços, pasta pessoal e ESP ficam fora da cópia. Não protege contra falha do disco.' \
      'ext4 recovery: verified local OS backup. Restore only from rescue media with the original root mounted. Service data, home and ESP are excluded. This does not protect against disk failure.' \
      'Recuperación ext4: copia local verificada del sistema. Restaure solo desde un medio de rescate con la raíz original montada. Se excluyen datos de servicios, carpetas personales y ESP. No protege contra fallos del disco.'
    if [[ "$reference" =~ ^[0-9a-f]{32}$ ]]; then
      printf '\n\n/usr/lib/vega/vegad nvidia-recover --target /mnt --reference %s --confirm' "$reference"
    fi
  elif [ "$kind" = snapper ]; then
    vega::nvidia::text 'Recuperação por snapshot Snapper da raiz. Nenhum rollback ou reinício automático.' \
      'Recovery through a root Snapper snapshot. No automatic rollback or restart.' \
      'Recuperación mediante snapshot Snapper de la raíz. Sin reversión ni reinicio automáticos.'
  fi
}

vega::nvidia::open() {
  local VEGA_NVIDIA_LOCALE
  VEGA_NVIDIA_LOCALE="$(vega::dbus::locale)"
  local capabilities
  if ! vega::dbus::call_data_into capabilities Metadata Capabilities; then
    vega::ui::msgbox "$VEGA_DBUS_LAST_ERROR" NVIDIA; return
  fi
  if ! jq -e '.[0] | index("nvidia-official-v1") != null and index("nvidia-recovery-v1") != null' <<<"$capabilities" >/dev/null; then
    vega::ui::msgbox "$(vega::nvidia::text 'Atualize o vegad para usar esta instalação.' 'Update vegad to use this installer.' 'Actualice vegad para usar este instalador.')" NVIDIA
    return
  fi
  while true; do
    local status recovery
    if ! vega::dbus::call_data_into status Software NvidiaStatus ||
       ! vega::dbus::call_data_into recovery Software NvidiaRecovery; then
      vega::ui::msgbox "$VEGA_DBUS_LAST_ERROR" NVIDIA; return
    fi
    local state gpu detail kind reference summary choice
    state="$(jq -r '.[0][5]' <<<"$status")"
    gpu="$(jq -r '.[0][3]' <<<"$status")"
    detail="$(jq -r '.[0][6]' <<<"$status")"
    kind="$(jq -r '.[0][1]' <<<"$recovery")"
    reference="$(jq -r '.[0][2]' <<<"$recovery")"
    summary="$(vega::nvidia::state "$state") [$state]
$gpu
$detail
Secure Boot: $(jq -r '.[0][4]' <<<"$status")

$(vega::nvidia::recovery_help "$kind" "$reference")
$kind $reference ($(jq -r '.[0][3]' <<<"$recovery"))
$(jq -r '.[0][4]' <<<"$recovery")"
    local -a options=()
    if [[ "$state" = available || "$state" = unmanaged ]] &&
       jq -e '.[0][0] == true' <<<"$status" >/dev/null &&
       jq -e '.[0][0] == true' <<<"$recovery" >/dev/null; then
      options+=(install "$(vega::nvidia::text 'Instalar integração NVIDIA oficial' 'Install official NVIDIA integration' 'Instalar integración NVIDIA oficial')")
    fi
    options+=(refresh "$(vega::nvidia::text 'Atualizar diagnóstico' 'Refresh diagnostics' 'Actualizar diagnóstico')" back "$(vega::nvidia::text 'Voltar' 'Back' 'Volver')")
    choice="$(vega::ui::menu NVIDIA "$summary" "${options[@]}")" || return
    case "$choice" in
      install)
        # Always confirm, including adoption of an already installed driver.
        vega::ui::yesno "$summary

$(vega::nvidia::text \
          'Instalar os RPMs oficiais NVIDIA 610.57.04, módulo assinado SUSE e integração Lyra? Requer internet e autenticação administrativa. A recuperação será criada e verificada antes da instalação. Não desligue durante a operação.' \
          'Install official NVIDIA 610.57.04 RPMs, SUSE-signed module and Lyra integration? Internet access and administrator authentication are required. Recovery will be created and verified before installation. Do not power off during the operation.' \
          '¿Instalar los RPM oficiales NVIDIA 610.57.04, el módulo firmado por SUSE y la integración Lyra? Se requiere internet y autenticación administrativa. Se creará y verificará la recuperación antes de instalar. No apague durante la operación.')" NVIDIA || continue
        vega::ui::infobox "$(vega::nvidia::text 'Preparando recuperação e instalando; aguarde a conclusão…' 'Preparing recovery and installing; wait for completion…' 'Preparando recuperación e instalando; espere la finalización…')" NVIDIA
        local _transaction_result
        if vega::dbus::run_transaction_into _transaction_result Software InstallNvidia TransactionFinished b true; then
          vega::ui::msgbox "$(vega::nvidia::text 'Instalação concluída e verificada. Consulte o estado antes de reiniciar.' 'Installation completed and verified. Review the status before restarting.' 'Instalación completada y verificada. Revise el estado antes de reiniciar.')" NVIDIA
        else
          vega::ui::msgbox "$(vega::nvidia::text 'Instalação não confirmada. Verifique o diagnóstico e a recuperação antes de repetir.' 'Installation not confirmed. Check diagnostics and recovery before retrying.' 'Instalación no confirmada. Revise el diagnóstico y la recuperación antes de repetir.')
$VEGA_DBUS_LAST_ERROR" NVIDIA
        fi
        ;;
      refresh) ;;
      *) return ;;
    esac
  done
}
