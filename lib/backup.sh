#!/usr/bin/env bash
# Módulo "Backup e Pontos de Restauração": configurações de backup (criar,
# rodar, restaurar, excluir) e pontos de restauração do sistema (criar,
# comparar pacotes, aplicar rollback, excluir, retenção) — equivalente aos
# módulos Backup/Snapshots do vega-gtk (org.lyraos.Vega1.Backup +
# org.lyraos.Vega1.Snapshots, vega-gtk/src/ui/backup.rs e snapshots.rs).
# Sourced pelo entrypoint (bin/vega) — não é executável sozinho.

vega::backup::_frequencia_label() {
  case "$1" in
  manual) printf 'Manual' ;;
  daily) printf 'Diário' ;;
  weekly) printf 'Semanal' ;;
  on-connect) printf 'Ao conectar o destino' ;;
  *) printf '%s' "$1" ;;
  esac
}

vega::backup::_formatar_data() {
  date -d "@$1" "+%Y-%m-%d %H:%M" 2>/dev/null || printf '%s' "$1"
}

vega::backup::_formatar_tamanho() {
  numfmt --to=iec-i --suffix=B "$1" 2>/dev/null || printf '%s bytes' "$1"
}

# ---------------------------------------------------------------------------
# Configurações de backup
# ---------------------------------------------------------------------------

vega::backup::_nova_config() {
  local id paths_input destino uuid
  id="$(vega::ui::inputbox "Nova configuração de backup" \
    "Identificador (opcional — vazio gera um a partir do destino):")" || return
  paths_input="$(vega::ui::inputbox "Nova configuração de backup" \
    "Caminhos a proteger, separados por vírgula:")" || return
  destino="$(vega::ui::inputbox "Nova configuração de backup" \
    "Diretório ou repositório de destino:")" || return
  uuid="$(vega::ui::inputbox "Nova configuração de backup" \
    "UUID do volume de destino (opcional, pra mídia removível):")" || return

  local freq
  freq="$(vega::ui::menu "Nova configuração de backup" "Frequência:" \
    manual "Manual" \
    daily "Diário" \
    weekly "Semanal" \
    on-connect "Ao conectar o destino")" || return

  local -a paths=()
  local IFS=','
  local raw
  for raw in $paths_input; do
    raw="${raw#"${raw%%[![:space:]]*}"}"
    raw="${raw%"${raw##*[![:space:]]}"}"
    [ -n "$raw" ] && paths+=("$raw")
  done
  unset IFS
  destino="$(printf '%s' "$destino" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

  if [ "${#paths[@]}" -eq 0 ] || [ -z "$destino" ]; then
    vega::ui::msgbox "Informe ao menos um caminho e um destino." "Backup"
    return
  fi

  vega::ui::yesno "Criar configuração de backup?

Caminhos: ${paths[*]}
Destino: ${destino}${uuid:+ • UUID ${uuid}}
Frequência: $(vega::backup::_frequencia_label "$freq")" \
    "Confirmar" || return

  local result rc=0
  result="$(vega::dbus::call Backup CreateConfig "(sassss)" \
    "$id" "${#paths[@]}" "${paths[@]}" "$destino" "$uuid" "$freq")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    vega::ui::msgbox "Falha ao criar configuração: $VEGA_DBUS_LAST_ERROR" "Backup"
    return
  fi
  local created_id
  created_id="$(printf '%s' "$result" | jq -r '.data[0]')"
  vega::ui::msgbox "Configuração \"$created_id\" criada." "Backup"
}

# vega::backup::_ver_caminhos_snapshot <configId> <snapshotId>
vega::backup::_ver_caminhos_snapshot() {
  local config_id="$1" snapshot_id="$2"
  vega::ui::infobox "Carregando caminhos…" "Backup"
  local data rc=0
  data="$(vega::dbus::call_data Backup ListSnapshotPaths ss "$config_id" "$snapshot_id")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    vega::ui::msgbox "Falha ao listar caminhos: $VEGA_DBUS_LAST_ERROR" "Backup"
    return
  fi
  local count
  count="$(printf '%s' "$data" | jq -r '.[0] | length')"
  if [ "$count" -eq 0 ]; then
    vega::ui::msgbox "O snapshot não contém caminhos restauráveis." "Caminhos do snapshot"
    return
  fi
  local listagem
  listagem="$(printf '%s' "$data" | jq -r '.[0][0:200][]')"
  if [ "$count" -gt 200 ]; then
    listagem="${listagem}
… e mais $((count - 200)) caminho(s)."
  fi
  vega::ui::msgbox "$listagem" "Caminhos do snapshot ($count)"
}

# vega::backup::_restaurar <configId> <snapshotId>
vega::backup::_restaurar() {
  local config_id="$1" snapshot_id="$2"
  local destino
  destino="$(vega::ui::inputbox "Restaurar snapshot $snapshot_id" \
    "Pasta de destino da restauração:")" || return
  if [ -z "$destino" ]; then
    vega::ui::msgbox "Informe uma pasta de destino." "Backup"
    return
  fi

  local modo_tag
  modo_tag="$(vega::ui::menu "Restaurar snapshot $snapshot_id" "Modo de restauração:" \
    separada "Pasta separada (recomendado)" \
    substituir "Substituir arquivos existentes")" || return
  local modo="separate-folder"
  [ "$modo_tag" = "substituir" ] && modo="replace"

  vega::ui::yesno "Restaurar o snapshot $snapshot_id em \"$destino\"${modo_tag:+ (${modo_tag})}?" \
    "Confirmar restauração" || return

  vega::ui::infobox "Restaurando snapshot $snapshot_id…" "Backup"
  local result rc=0
  result="$(vega::dbus::run_transaction Backup RestoreSnapshot RestoreFinished \
    sss "$snapshot_id" "$destino" "$modo")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    vega::ui::msgbox "Falha na restauração: $VEGA_DBUS_LAST_ERROR" "Backup"
  else
    vega::ui::msgbox "${result:-Restauração concluída.}" "Backup"
  fi
}

# vega::backup::_acoes_snapshot <configId> <snapshotId>
vega::backup::_acoes_snapshot() {
  local config_id="$1" snapshot_id="$2"
  local choice
  choice="$(vega::ui::menu "Snapshot $snapshot_id" "Escolha uma ação:" \
    restaurar "Restaurar" \
    caminhos "Ver caminhos" \
    voltar "Voltar")" || return
  case "$choice" in
  restaurar) vega::backup::_restaurar "$config_id" "$snapshot_id" ;;
  caminhos) vega::backup::_ver_caminhos_snapshot "$config_id" "$snapshot_id" ;;
  esac
}

# vega::backup::_ver_snapshots <configId>
vega::backup::_ver_snapshots() {
  local config_id="$1"
  vega::ui::infobox "Carregando snapshots de \"$config_id\"…" "Backup"
  local data rc=0
  data="$(vega::dbus::call_data Backup ListSnapshots s "$config_id")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    vega::ui::msgbox "Falha ao listar snapshots: $VEGA_DBUS_LAST_ERROR" "Backup"
    return
  fi

  local count
  count="$(printf '%s' "$data" | jq -r '.[0] | length')"
  if [ "$count" -eq 0 ]; then
    vega::ui::msgbox "Nenhum snapshot encontrado para \"$config_id\"." "Snapshots"
    return
  fi

  # BackupSnapshotInfo: (id, timestampUnix, fileCount, sizeBytes)
  local -a rows
  mapfile -t rows < <(printf '%s' "$data" | jq -r '.[0][] | [.[0],.[1],.[2],.[3]] | join("")')

  local -a ids=() menu_args=()
  local row sid ts files size
  for row in "${rows[@]}"; do
    IFS=$'\x1f' read -r sid ts files size <<<"$row"
    ids+=("$sid")
    menu_args+=("$sid" "$(vega::backup::_formatar_data "$ts") • ${files} arquivo(s) • $(vega::backup::_formatar_tamanho "$size")")
  done

  local choice
  choice="$(vega::ui::menu "Snapshots de \"$config_id\"" "Escolha um snapshot:" "${menu_args[@]}")" || return
  vega::backup::_acoes_snapshot "$config_id" "$choice"
}

# vega::backup::_acoes_config <id> <destino> <uuid> <numCaminhos> <frequencia>
vega::backup::_acoes_config() {
  local id="$1" destino="$2" uuid="$3" npaths="$4" freq="$5"
  local subtitle="${destino}${uuid:+ • UUID ${uuid}} • ${npaths} caminho(s) • $(vega::backup::_frequencia_label "$freq")"

  local choice
  choice="$(vega::ui::menu "$id" "$subtitle" \
    executar "Executar backup agora" \
    snapshots "Ver snapshots" \
    excluir "Excluir configuração" \
    voltar "Voltar")" || return

  case "$choice" in
  executar)
    vega::ui::yesno "Executar o backup \"$id\" agora?" "Confirmar" || return
    vega::ui::infobox "Executando backup \"$id\"…" "Backup"
    local result rc=0
    result="$(vega::dbus::run_transaction Backup RunBackupNow BackupFinished s "$id")" || rc=$?
    if [ "$rc" -ne 0 ]; then
      vega::ui::msgbox "Falha no backup: $VEGA_DBUS_LAST_ERROR" "Backup"
    else
      vega::ui::msgbox "${result:-Backup concluído.}" "Backup"
    fi
    ;;
  snapshots) vega::backup::_ver_snapshots "$id" ;;
  excluir)
    vega::ui::yesno "Excluir a configuração \"$id\"?

Os dados já armazenados no destino não são apagados automaticamente." \
      "Excluir configuração" || return
    if vega::dbus::call Backup DeleteConfig s "$id" >/dev/null; then
      vega::ui::msgbox "Configuração \"$id\" excluída." "Backup"
    else
      vega::ui::msgbox "Falha ao excluir: $VEGA_DBUS_LAST_ERROR" "Backup"
    fi
    ;;
  esac
}

vega::backup::_configuracoes() {
  while true; do
    vega::ui::infobox "Carregando configurações de backup…" "Backup"
    local data rc=0
    data="$(vega::dbus::call_data Backup ListConfigs)" || rc=$?
    if [ "$rc" -ne 0 ]; then
      vega::ui::msgbox "Falha ao listar configurações: $VEGA_DBUS_LAST_ERROR" "Backup"
      return
    fi

    local count
    count="$(printf '%s' "$data" | jq -r '.[0] | length')"

    # BackupConfig: (id, paths[], destination, destinationUUID, frequency)
    local -a ids=() destinos=() uuids=() npaths_arr=() freqs=() menu_args=()
    menu_args+=(nova "+ Nova configuração de backup")
    if [ "$count" -gt 0 ]; then
      local -a rows
      mapfile -t rows < <(printf '%s' "$data" |
        jq -r '.[0][] | [.[0], (.[1] | length | tostring), .[2], .[3], .[4]] | join("\u001f")')
      local row cfg_id cfg_npaths cfg_dest cfg_uuid cfg_freq label
      for row in "${rows[@]}"; do
        IFS=$'\x1f' read -r cfg_id cfg_npaths cfg_dest cfg_uuid cfg_freq <<<"$row"
        ids+=("$cfg_id")
        destinos+=("$cfg_dest")
        uuids+=("$cfg_uuid")
        npaths_arr+=("$cfg_npaths")
        freqs+=("$cfg_freq")
        label="${cfg_dest}${cfg_uuid:+ • UUID ${cfg_uuid}} • ${cfg_npaths} caminho(s) • $(vega::backup::_frequencia_label "$cfg_freq")"
        menu_args+=("$cfg_id" "$label")
      done
    fi

    local choice
    choice="$(vega::ui::menu "Configurações de backup" "Escolha uma configuração:" "${menu_args[@]}")" || return

    if [ "$choice" = "nova" ]; then
      vega::backup::_nova_config
      continue
    fi

    local i idx=-1
    for i in "${!ids[@]}"; do
      [ "${ids[$i]}" = "$choice" ] && idx=$i && break
    done
    if [ "$idx" -ge 0 ]; then
      vega::backup::_acoes_config "${ids[$idx]}" "${destinos[$idx]}" "${uuids[$idx]}" "${npaths_arr[$idx]}" "${freqs[$idx]}"
    fi
  done
}

# ---------------------------------------------------------------------------
# Pontos de restauração (snapshots do sistema)
# ---------------------------------------------------------------------------

vega::backup::_criar_snapshot() {
  local descricao
  descricao="$(vega::ui::inputbox "Criar ponto de restauração" \
    "Descrição do ponto de restauração:")" || return
  if [ -z "$descricao" ]; then
    vega::ui::msgbox "Informe uma descrição para o snapshot." "Pontos de restauração"
    return
  fi
  vega::ui::yesno "Criar um ponto de restauração agora?

O snapshot será criado pelo backend disponível no sistema." \
    "Confirmar" || return

  vega::ui::infobox "Criando ponto de restauração…" "Pontos de restauração"
  local result rc=0
  result="$(vega::dbus::call Snapshots CreateSnapshot s "$descricao")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    vega::ui::msgbox "Falha ao criar snapshot: $VEGA_DBUS_LAST_ERROR" "Pontos de restauração"
    return
  fi
  local new_id
  new_id="$(printf '%s' "$result" | jq -r '.data[0]')"
  vega::ui::msgbox "Ponto de restauração #$new_id criado." "Pontos de restauração"
}

# vega::backup::_diff_pacotes <snapshotId>
# Imprime o texto formatado da comparação de pacotes em stdout.
vega::backup::_diff_pacotes() {
  local snapshot_id="$1"
  local data rc=0
  data="$(vega::dbus::call_data Snapshots DiffPackages u "$snapshot_id")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'Falha ao comparar pacotes: %s' "$VEGA_DBUS_LAST_ERROR"
    return 1
  fi
  local count
  count="$(printf '%s' "$data" | jq -r '.[0] | length')"
  if [ "$count" -eq 0 ]; then
    printf 'Nenhuma diferença de pacotes em relação ao estado atual.'
    return 0
  fi
  printf '%s' "$data" | jq -r '.[0][]'
}

vega::backup::_comparar_pacotes() {
  local snapshot_id="$1"
  vega::ui::infobox "Comparando pacotes…" "Pontos de restauração"
  local texto
  texto="$(vega::backup::_diff_pacotes "$snapshot_id")"
  vega::ui::msgbox "$texto" "Diferenças de pacotes — snapshot #$snapshot_id"
}

vega::backup::_aplicar_rollback() {
  local snapshot_id="$1"
  vega::ui::infobox "Carregando revisão obrigatória do rollback…" "Pontos de restauração"
  local diff
  diff="$(vega::backup::_diff_pacotes "$snapshot_id")"

  vega::ui::yesno "Aplicar o snapshot #$snapshot_id?

Revise as diferenças abaixo. O sistema pode precisar ser reiniciado após o rollback.

$diff" \
    "Aplicar rollback" || return

  vega::ui::infobox "Aplicando ponto de restauração…" "Pontos de restauração"
  if vega::dbus::call Snapshots Rollback u "$snapshot_id" >/dev/null; then
    vega::ui::msgbox "Rollback aplicado. Reinicie o sistema se o backend solicitar." "Pontos de restauração"
  else
    vega::ui::msgbox "Falha no rollback: $VEGA_DBUS_LAST_ERROR" "Pontos de restauração"
  fi
}

vega::backup::_excluir_snapshot() {
  local snapshot_id="$1"
  vega::ui::yesno "Excluir o ponto de restauração #$snapshot_id permanentemente?" \
    "Excluir" || return
  if vega::dbus::call Snapshots DeleteSnapshot u "$snapshot_id" >/dev/null; then
    vega::ui::msgbox "Ponto de restauração #$snapshot_id excluído." "Pontos de restauração"
  else
    vega::ui::msgbox "Falha ao excluir: $VEGA_DBUS_LAST_ERROR" "Pontos de restauração"
  fi
}

vega::backup::_definir_retencao() {
  local keep
  keep="$(vega::ui::inputbox "Política de retenção" \
    "Quantos pontos de restauração mais recentes manter:" "10")" || return
  case "$keep" in
  '' | *[!0-9]*)
    vega::ui::msgbox "Informe um número inteiro positivo." "Pontos de restauração"
    return
    ;;
  esac
  [ "$keep" -lt 1 ] && keep=1

  vega::ui::yesno "O sistema manterá os $keep pontos de restauração mais recentes. Os excedentes poderão ser removidos pelo backend.

Aplicar?" \
    "Alterar política de retenção" || return

  if vega::dbus::call Snapshots SetRetentionPolicy u "$keep" >/dev/null; then
    vega::ui::msgbox "Política de retenção atualizada." "Pontos de restauração"
  else
    vega::ui::msgbox "Falha ao atualizar: $VEGA_DBUS_LAST_ERROR" "Pontos de restauração"
  fi
}

vega::backup::_acoes_snapshot_sistema() {
  local snapshot_id="$1"
  local choice
  choice="$(vega::ui::menu "Snapshot #$snapshot_id" "Escolha uma ação:" \
    comparar "Comparar pacotes" \
    aplicar "Aplicar rollback" \
    excluir "Excluir" \
    voltar "Voltar")" || return
  case "$choice" in
  comparar) vega::backup::_comparar_pacotes "$snapshot_id" ;;
  aplicar) vega::backup::_aplicar_rollback "$snapshot_id" ;;
  excluir) vega::backup::_excluir_snapshot "$snapshot_id" ;;
  esac
}

vega::backup::_pontos_restauracao() {
  local available_json available rc=0
  available_json="$(vega::dbus::call_data Snapshots Available)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    vega::ui::msgbox "Falha ao consultar suporte a snapshots: $VEGA_DBUS_LAST_ERROR" "Pontos de restauração"
    return
  fi
  available="$(printf '%s' "$available_json" | jq -r '.[0]')"
  if [ "$available" != "true" ]; then
    vega::ui::msgbox "Pontos de restauração não são suportados neste sistema." "Pontos de restauração"
    return
  fi

  while true; do
    vega::ui::infobox "Carregando pontos de restauração…" "Pontos de restauração"
    local data
    data="$(vega::dbus::call_data Snapshots ListSnapshots)" || rc=$?
    if [ "$rc" -ne 0 ]; then
      vega::ui::msgbox "Falha ao listar: $VEGA_DBUS_LAST_ERROR" "Pontos de restauração"
      return
    fi

    local count
    count="$(printf '%s' "$data" | jq -r '.[0] | length')"

    # SnapshotInfo: (id, timestampUnix, trigger, description)
    local -a menu_args=(novo "+ Criar ponto de restauração" retencao "Política de retenção")
    if [ "$count" -gt 0 ]; then
      local -a rows
      mapfile -t rows < <(printf '%s' "$data" | jq -r '.[0][] | [(.[0]|tostring),.[1],.[2],.[3]] | join("\u001f")')
      local row sid ts trigger desc
      for row in "${rows[@]}"; do
        IFS=$'\x1f' read -r sid ts trigger desc <<<"$row"
        menu_args+=("$sid" "#${sid} • $(vega::backup::_formatar_data "$ts") • ${trigger}${desc:+ • ${desc}}")
      done
    fi

    local choice
    choice="$(vega::ui::menu "Pontos de restauração" "Escolha uma opção:" "${menu_args[@]}")" || return

    case "$choice" in
    novo)
      vega::backup::_criar_snapshot
      ;;
    retencao)
      vega::backup::_definir_retencao
      ;;
    *)
      vega::backup::_acoes_snapshot_sistema "$choice"
      ;;
    esac
  done
}

# ---------------------------------------------------------------------------

vega::module_backup() {
  local choice
  while true; do
    choice="$(vega::ui::menu "Backup e Pontos de Restauração" "Escolha uma área:" \
      configuracoes "Configurações de backup" \
      pontos "Pontos de restauração" \
      voltar "Voltar")" || return

    case "$choice" in
    configuracoes) vega::backup::_configuracoes || true ;;
    pontos) vega::backup::_pontos_restauracao || true ;;
    voltar | "") return ;;
    esac
  done
}
