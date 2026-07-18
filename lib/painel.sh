#!/usr/bin/env bash
# Módulo "Painel": tela de resumo do sistema — status do vegad, sistema,
# atualizações, backup, pontos de restauração, serviços e disco. Espelha o
# dashboard do vega-gtk (vega-gtk/src/ui/shell.rs + application.rs),
# trocando "interface nativa ativa" por "vega-cli" e sem gráficos/ícones.
# Mostrada automaticamente ao abrir o vega (ver bin/vega) e reacessível
# pela opção "Painel" do menu principal. Sourced pelo entrypoint — não é
# executável sozinho.
#
# Nota: em toda função abaixo, a chamada D-Bus (vega::dbus::call_data) é
# capturada numa variável ANTES de passar pro jq, nunca encadeada num pipe
# direto (`call_data | jq`) — com `set -o pipefail`, se call_data falhar e
# não escrever nada no stdout, `jq '.[0]'` lendo stdin vazio ainda sai com
# status 0, o que mascararia o erro original.

# vega::painel::_count_out0 <interface> <método>
# Chama um método cujo único retorno é um array de structs (ex.
# ListUpdates, ListConfigs) e imprime a quantidade de itens. Retorna != 0
# em erro de D-Bus, com a mensagem em $VEGA_DBUS_LAST_ERROR.
vega::painel::_count_out0() {
  local data
  data="$(vega::dbus::call_data "$@")" || return 1
  printf '%s' "$data" | jq -r '.[0] | length'
}

vega::painel::_linha_backend() {
  local ping_json version_json distro_json version distro
  if ! ping_json="$(vega::dbus::call_data System Ping)"; then
    printf 'vegad indisponível: %s' "$VEGA_DBUS_LAST_ERROR"
    return 1
  fi
  if [ "$(printf '%s' "$ping_json" | jq -r '.[0]')" != "true" ]; then
    printf 'vegad indisponível: Ping retornou false'
    return 1
  fi

  if version_json="$(vega::dbus::call_data System Version)"; then
    version="$(printf '%s' "$version_json" | jq -r '.[0]')"
  else
    version="?"
  fi
  if distro_json="$(vega::dbus::call_data System Distro)"; then
    distro="$(printf '%s' "$distro_json" | jq -r '.[0]')"
  else
    distro="?"
  fi
  printf 'vegad %s conectado • %s' "$version" "$distro"
}

vega::painel::_linha_sistema() {
  local distro_json
  if distro_json="$(vega::dbus::call_data System Distro)"; then
    printf '%s • gerenciado via vega-cli' "$(printf '%s' "$distro_json" | jq -r '.[0]')"
  else
    printf '%s' "$VEGA_DBUS_LAST_ERROR"
  fi
}

vega::painel::_linha_atualizacoes() {
  local count
  if ! count="$(vega::painel::_count_out0 Software ListUpdates)"; then
    printf '%s' "$VEGA_DBUS_LAST_ERROR"
  elif [ "$count" -eq 0 ]; then
    printf 'Tudo em dia'
  else
    printf '%s pacote(s) pendente(s)' "$count"
  fi
}

vega::painel::_linha_backup() {
  local count
  if ! count="$(vega::painel::_count_out0 Backup ListConfigs)"; then
    printf '%s' "$VEGA_DBUS_LAST_ERROR"
  elif [ "$count" -eq 0 ]; then
    printf 'Não configurado'
  else
    printf '%s destino(s) configurado(s)' "$count"
  fi
}

vega::painel::_linha_snapshots() {
  local available_json available count
  if ! available_json="$(vega::dbus::call_data Snapshots Available)"; then
    printf '%s' "$VEGA_DBUS_LAST_ERROR"
    return
  fi
  available="$(printf '%s' "$available_json" | jq -r '.[0]')"
  if [ "$available" != "true" ]; then
    printf 'Não suportado neste sistema'
    return
  fi
  if ! count="$(vega::painel::_count_out0 Snapshots ListSnapshots)"; then
    printf '%s' "$VEGA_DBUS_LAST_ERROR"
  elif [ "$count" -eq 0 ]; then
    printf 'Nenhum snapshot'
  else
    printf '%s snapshot(s)' "$count"
  fi
}

vega::painel::_linha_servicos() {
  local data struggling
  if ! data="$(vega::dbus::call_data Services ListServices)"; then
    printf '%s' "$VEGA_DBUS_LAST_ERROR"
    return
  fi
  # ManagedServiceInfo: (name, label, description, enabled, active,
  # available) — "com problema" é habilitado e disponível, mas não ativo.
  struggling="$(printf '%s' "$data" |
    jq -r '[.[0][] | select(.[5] == true and .[3] == true and .[4] == false)] | length')"
  if [ "$struggling" -eq 0 ]; then
    printf 'Nenhum serviço com problema'
  else
    printf '%s serviço(s) habilitado(s), mas parado(s)' "$struggling"
  fi
}

vega::painel::_linha_disco() {
  local data
  if ! data="$(vega::dbus::call_data System DiskUsage)"; then
    printf '%s' "$VEGA_DBUS_LAST_ERROR"
    return
  fi
  printf '%s%% • %s de %s usados' \
    "$(printf '%s' "$data" | jq -r '.[2]')" \
    "$(printf '%s' "$data" | jq -r '.[0]')" \
    "$(printf '%s' "$data" | jq -r '.[1]')"
}

vega::module_painel() {
  vega::ui::infobox "Carregando painel…" "Painel"

  local backend rc=0
  backend="$(vega::painel::_linha_backend)" || rc=$?

  if [ "$rc" -ne 0 ]; then
    vega::ui::msgbox "Backend: ${backend}

As demais informações do painel dependem do vegad e não puderam ser carregadas." "Painel"
    return
  fi

  local texto
  texto="Backend: ${backend}
Sistema: $(vega::painel::_linha_sistema)
Atualizações: $(vega::painel::_linha_atualizacoes)
Backup: $(vega::painel::_linha_backup)
Pontos de restauração: $(vega::painel::_linha_snapshots)
Serviços: $(vega::painel::_linha_servicos)
Disco: $(vega::painel::_linha_disco)"

  vega::ui::msgbox "$texto" "Painel"
}
