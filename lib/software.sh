#!/usr/bin/env bash
# Módulo "Software": buscar/instalar/remover pacotes, atualizações
# pendentes, repositórios, atualizar tudo, otimizar mirrors e limpar cache
# — equivalente ao módulo Software do vega-gtk (org.lyraos.Vega1.Software,
# vega-gtk/src/ui/software.rs). Sourced pelo entrypoint (bin/vega) — não é
# executável sozinho.

vega::software::_origin_label() {
  case "$1" in
  official) printf 'Oficial' ;;
  flathub) printf 'Flathub' ;;
  aur) printf 'Comunidade' ;;
  *) printf '%s' "$1" ;;
  esac
}

# vega::software::_run_and_report <mensagem-de-espera> <interface> <método> [assinatura arg...]
# Mostra um infobox enquanto a transação roda (vega::dbus::run_transaction
# bloqueia até o sinal TransactionFinished chegar) e reporta o resultado.
vega::software::_run_and_report() {
  local wait_message="$1" interface="$2" method="$3"
  shift 3
  vega::ui::infobox "$wait_message" "Software"
  local result rc=0
  result="$(vega::dbus::run_transaction "$interface" "$method" TransactionFinished "$@")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    vega::ui::msgbox "Falha: $VEGA_DBUS_LAST_ERROR" "Software"
  else
    vega::ui::msgbox "${result:-Concluído.}" "Software"
  fi
}

# vega::software::_acoes_pacote <origin> <id> <name> <installed>
vega::software::_acoes_pacote() {
  local origin="$1" id="$2" name="$3" installed="$4"
  local -a opts=()
  if [ "$installed" = "true" ]; then
    opts+=(remover "Remover")
  else
    opts+=(instalar "Instalar")
  fi
  opts+=(voltar "Voltar")

  local choice
  choice="$(vega::ui::menu "$name" \
    "Origem: $(vega::software::_origin_label "$origin") • ID: $id" \
    "${opts[@]}")" || return

  case "$choice" in
  instalar)
    vega::ui::yesno "Instalar \"$name\"?" "Confirmar instalação" &&
      vega::software::_run_and_report "Instalando \"$name\"…" Software Install ss "$origin" "$id"
    ;;
  remover)
    vega::ui::yesno "Remover \"$name\"?" "Confirmar remoção" &&
      vega::software::_run_and_report "Removendo \"$name\"…" Software Remove ss "$origin" "$id"
    ;;
  esac
}

# vega::software::_selecionar_pacote <título> <json de PackageRef ("data" já extraído)>
# JSON no formato de vega::dbus::call_data pra um método que devolve
# a(ssssbs) (PackageRef: origin, id, name, description, installed, icon).
vega::software::_selecionar_pacote() {
  local title="$1" data="$2"
  local count
  count="$(printf '%s' "$data" | jq -r '.[0] | length')"
  if [ "$count" -eq 0 ]; then
    vega::ui::msgbox "Nenhum resultado encontrado." "$title"
    return
  fi

  local -a rows
  mapfile -t rows < <(printf '%s' "$data" | jq -r '.[0][] | [.[0],.[1],.[2],.[4]] | join("")')

  local -a origins=() ids=() names=() installeds=() menu_args=()
  local idx=0 row origin id name installed marker
  for row in "${rows[@]}"; do
    IFS=$'\x1f' read -r origin id name installed <<<"$row"
    origins[idx]="$origin"
    ids[idx]="$id"
    names[idx]="$name"
    installeds[idx]="$installed"
    marker=""
    [ "$installed" = "true" ] && marker=" [Instalado]"
    menu_args+=("$idx" "$(vega::software::_origin_label "$origin"): ${name}${marker}")
    idx=$((idx + 1))
  done

  local choice
  choice="$(vega::ui::menu "$title" "Escolha um pacote:" "${menu_args[@]}")" || return
  vega::software::_acoes_pacote "${origins[$choice]}" "${ids[$choice]}" "${names[$choice]}" "${installeds[$choice]}"
}

vega::software::_buscar() {
  local query
  query="$(vega::ui::inputbox "Buscar pacotes" \
    "Nome do pacote ou palavra-chave (mínimo 2 caracteres):")" || return
  if [ "${#query}" -lt 2 ]; then
    vega::ui::msgbox "Digite ao menos dois caracteres para buscar." "Software"
    return
  fi

  vega::ui::infobox "Buscando \"$query\"…" "Software"
  local data rc=0
  # Buscas com backend tipo Flathub podem demorar bem mais que uma chamada
  # D-Bus comum, especialmente com cache frio.
  data="$(VEGA_DBUS_CALL_TIMEOUT=60 vega::dbus::call_data Software Search s "$query")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    vega::ui::msgbox "Falha na busca: $VEGA_DBUS_LAST_ERROR" "Software"
    return
  fi
  vega::software::_selecionar_pacote "Resultados para \"$query\"" "$data"
}

vega::software::_listar_instalados() {
  vega::ui::infobox "Carregando pacotes instalados…" "Software"
  local data rc=0
  data="$(VEGA_DBUS_CALL_TIMEOUT=60 vega::dbus::call_data Software ListInstalled)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    vega::ui::msgbox "Falha ao listar pacotes instalados: $VEGA_DBUS_LAST_ERROR" "Software"
    return
  fi
  vega::software::_selecionar_pacote "Pacotes instalados" "$data"
}

vega::software::_listar_atualizacoes() {
  vega::ui::infobox "Verificando atualizações…" "Software"
  local data rc=0
  data="$(vega::dbus::call_data Software ListUpdates)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    vega::ui::msgbox "Falha ao verificar atualizações: $VEGA_DBUS_LAST_ERROR" "Software"
    return
  fi

  local count
  count="$(printf '%s' "$data" | jq -r '.[0] | length')"
  if [ "$count" -eq 0 ]; then
    vega::ui::msgbox "Tudo em dia — nenhuma atualização pendente." "Atualizações"
    return
  fi

  vega::software::_selecionar_pacote "Atualizações disponíveis ($count)" "$data"
}

vega::software::_repositorios() {
  vega::ui::infobox "Carregando repositórios…" "Software"
  local data rc=0
  data="$(vega::dbus::call_data Software ListRepos)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    vega::ui::msgbox "Falha ao listar repositórios: $VEGA_DBUS_LAST_ERROR" "Software"
    return
  fi

  local count
  count="$(printf '%s' "$data" | jq -r '.[0] | length')"
  if [ "$count" -eq 0 ]; then
    vega::ui::msgbox "Nenhum repositório encontrado." "Repositórios"
    return
  fi

  local -a rows
  mapfile -t rows < <(printf '%s' "$data" | jq -r '.[0][] | [.[0],.[1]] | join("")')

  local -a names=() checklist_args=()
  local -A original_enabled=()
  local row name enabled status
  for row in "${rows[@]}"; do
    IFS=$'\x1f' read -r name enabled <<<"$row"
    names+=("$name")
    original_enabled["$name"]="$enabled"
    status="off"
    [ "$enabled" = "true" ] && status="on"
    checklist_args+=("$name" "$name" "$status")
  done

  local checklist_output crc=0
  checklist_output="$(vega::ui::checklist "Repositórios" \
    "Marque para ativar, desmarque para desativar:" "${checklist_args[@]}")" || crc=$?
  if [ "$crc" -ne 0 ]; then
    return
  fi

  local -a checked=()
  if [ -n "$checklist_output" ]; then
    mapfile -t checked <<<"$checklist_output"
  fi
  local -A now_checked=()
  local c
  for c in "${checked[@]}"; do
    now_checked["$c"]=1
  done

  local changed=0 failed=0 was is
  for name in "${names[@]}"; do
    was="${original_enabled[$name]}"
    is="false"
    [ -n "${now_checked[$name]:-}" ] && is="true"
    if [ "$was" != "$is" ]; then
      changed=$((changed + 1))
      vega::dbus::call Software SetRepoEnabled sb "$name" "$is" >/dev/null || failed=$((failed + 1))
    fi
  done

  if [ "$changed" -eq 0 ]; then
    return
  fi
  if [ "$failed" -eq 0 ]; then
    vega::ui::msgbox "$changed repositório(s) atualizado(s)." "Repositórios"
  else
    vega::ui::msgbox "$failed de $changed alteração(ões) falharam. Última falha: $VEGA_DBUS_LAST_ERROR" "Repositórios"
  fi
}

vega::module_software() {
  local choice
  while true; do
    choice="$(vega::ui::menu "Software" "Escolha uma ação:" \
      buscar "Buscar pacotes" \
      instalados "Pacotes instalados" \
      atualizacoes "Atualizações disponíveis" \
      repositorios "Repositórios" \
      atualizar "Atualizar tudo" \
      mirrors "Otimizar mirrors" \
      cache "Limpar cache" \
      voltar "Voltar")" || return

    # "|| true" em cada ação: sob set -e, o usuário recusando um yesno ou
    # fechando uma tela com Esc (código != 0) só deve voltar pra este menu,
    # não derrubar a sessão inteira.
    case "$choice" in
    buscar) vega::software::_buscar || true ;;
    instalados) vega::software::_listar_instalados || true ;;
    atualizacoes) vega::software::_listar_atualizacoes || true ;;
    repositorios) vega::software::_repositorios || true ;;
    atualizar)
      if vega::ui::yesno "Atualizar todos os pacotes pendentes agora?" "Atualizar tudo"; then
        vega::software::_run_and_report "Atualizando pacotes…" Software UpdateAll || true
      fi
      ;;
    mirrors)
      if vega::ui::yesno "Otimizar a lista de mirrors agora?" "Otimizar mirrors"; then
        vega::software::_run_and_report "Otimizando mirrors…" Software OptimizeMirrors || true
      fi
      ;;
    cache)
      if vega::ui::yesno "Limpar o cache de pacotes agora?" "Limpar cache"; then
        vega::software::_run_and_report "Limpando cache…" Software ClearCache || true
      fi
      ;;
    voltar | "") return ;;
    esac
  done
}
