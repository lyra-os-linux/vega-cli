#!/usr/bin/env bash
# Diagnóstico de saúde, verificação semanal, "Minha internet não funciona" e
# Liberar espaço (add-cli-diagnostics, Lyra OS Server 16.1 RC 3): as mesmas
# interfaces do vega-gtk (org.lyraos.Vega1.Diagnostics e Cleanup) pelo
# terminal. Sourced pelo entrypoint (bin/vega) — não é executável sozinho.
#
# O progresso de um diagnóstico vem de Diagnostics.Current, consultado a cada
# segundo, e não dos sinais: um teste rápido termina antes de a chamada Start
# responder, e o Current voltando a outro job encerra a espera.

# ---------------------------------------------------------------------------
# Textos (puros: só jq sobre o JSON do vegad, testados em tests/)

VEGA_DIAG_NAMES='{
  "packages":"Integridade de pacotes","disk-health":"Saúde do disco",
  "fs-scrub":"Sistema de arquivos","cpu-stress":"Processador sob carga",
  "memory-stress":"Memória sob carga","disk-bench":"Desempenho do disco",
  "logs":"Logs e falhas","platform":"Estado da plataforma","security":"Segurança",
  "network":"Rede e internet","boot":"Tempo de boot"}'

VEGA_DIAG_VERDICTS='{"ok":"Saudável","attention":"Atenção","fail":"Falha",
  "unavailable":"Indisponível","cancelled":"Cancelado","aborted":"Interrompido"}'

# O modo Rápido do vega-gtk sem os testes de carga, que no terminal não têm
# a telemetria ao vivo: leituras que não pesam num servidor em produção.
VEGA_DIAG_QUICK=(packages disk-health logs platform security boot network)

# vega::diag::bytes <n> — 268435456 → "256 MiB".
vega::diag::bytes() {
  jq -rn --argjson n "${1:-0}" '
    def fmt: if . >= 1073741824 then "\(. / 1073741824 * 10 | floor / 10) GiB"
      elif . >= 1048576 then "\(. / 1048576 | floor) MiB"
      elif . >= 1024 then "\(. / 1024 | floor) KiB" else "\(.) B" end;
    $n | fmt'
}

# vega::diag::periodic_summary <LastPeriodic data> <último job visto>
# Imprime o resumo das novidades, ou nada se não houver novidade nova.
vega::diag::periodic_summary() {
  jq -r --argjson seen "${2:-0}" '
    if .[0] == 0 or .[2] == 0 or .[0] <= $seen then empty else
      "Verificação semanal de \(.[1] | strflocaltime("%d/%m/%Y %H:%M")): \(.[2]) novidade(s).\n",
      (.[4][] | "  • \(.)"),
      "\nO relatório completo está em Hardware e Kernel → Diagnóstico de saúde."
    end' <<<"$1"
}

# vega::diag::report_text <relatório JSON> — resultado por teste e os achados
# de atenção e falha, como na lista e no relatório do vega-gtk.
vega::diag::report_text() {
  jq -r --argjson names "$VEGA_DIAG_NAMES" --argjson verdicts "$VEGA_DIAG_VERDICTS" '
    "Diagnóstico \(.jobId) · \(.started // "")",
    "",
    (.stages[] | "\($verdicts[.verdict] // .verdict | . + "            " | .[0:13]) \($names[.id] // .id): \(.summary)"),
    ([.stages[] | .id as $stage | .findings[]? | select(.severity == "attention" or .severity == "fail")
      | {stage: $stage, f: .}] as $found
     | if $found == [] then "", "Nenhum problema encontrado."
       else "", "Precisa de atenção:", "",
         ($found[] | "  [\(if .f.severity == "fail" then "FALHA" else "ATENÇÃO" end)] \($names[.stage] // .stage): \(.f.text)"
           + (if .f.remedy then "\n      → tem conserto: Corrigir achados" else "" end))
       end)' <<<"$1"
}

# vega::diag::remedy_items <Remedies data> <relatório JSON>
# Uma linha por achado com conserto: "<etapa>:<índice>\t<texto>".
vega::diag::remedy_items() {
  jq -r --argjson remedies "$1" --argjson names "$VEGA_DIAG_NAMES" '
    . as $report | $remedies[0][] | . as [$stage, $index, $remedy]
    | ($report.stages[] | select(.id == $stage) | .findings[$index].text) as $text
    | "\($stage):\($index)\t\($names[$stage] // $stage): \($text // $remedy)"' <<<"$2"
}

# vega::diag::network_text <relatório JSON> — os passos do teste de rede.
vega::diag::network_text() {
  jq -r '
    ({"link":"Cabo ou Wi-Fi","address":"Endereço IP","gateway":"Roteador","dns":"DNS","internet":"Internet"}) as $names
    | ({"ok":"funcionando","warn":"atenção","fail":"AQUI ESTÁ O PROBLEMA","skipped":"não testado"}) as $status
    | ([.stages[] | select(.id == "network")] | last) as $net
    | if $net == null then "O teste de rede não rodou." else
        ($net.metrics.steps[] | "  \($names[.id] // .id | . + "               " | .[0:15]) \($status[.status] // .status)" + (if .detail then "  (\(.detail))" else "" end)),
        "",
        (if $net.verdict == "ok" then "A conexão está funcionando." else ($net.findings[] | select(.severity != "info") | "• \(.text)") end)
      end' <<<"$1"
}

# vega::cleanup::items <Scan data> — "<id>\t<texto>\t<on|off>" por categoria
# que pode ser limpa; as seguras vêm marcadas, kernels e snapshots não.
vega::cleanup::items() {
  jq -r '
    def bytes: if . >= 1073741824 then "\(. / 1073741824 * 10 | floor / 10) GiB"
      elif . >= 1048576 then "\(. / 1048576 | floor) MiB" elif . >= 1024 then "\(. / 1024 | floor) KiB" else "\(.) B" end;
    ({"coredumps":"Relatórios de falha (core dumps)","journal":"Logs antigos do sistema",
      "package-cache":"Pacotes baixados","flatpak-unused":"Runtimes Flatpak sem uso",
      "old-kernels":"Kernels antigos (com snapshot antes)","snapshots":"Snapshots fora da política"}) as $names
    | .[0][] | select(.[2]) | . as [$id, $size, $can, $detail]
    | ($detail | split(";") | map(select(startswith("count="))) | first // "" | ltrimstr("count=")) as $count
    | (if ($detail | contains("size=unknown")) then "pelo menos \($count), tamanho desconhecido" else ($size | bytes) end) as $shown
    | "\($id)\t\($names[$id] // $id) — \($shown)\t\(if $id == "old-kernels" or $id == "snapshots" then "off" else "on" end)"' <<<"$1"
}

# ---------------------------------------------------------------------------
# Estado por usuário (resumo já visto, último job)

vega::diag::_state_dir() {
  printf '%s/vega-cli' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

vega::diag::_seen() {
  local file
  file="$(vega::diag::_state_dir)/periodic-seen"
  [ -r "$file" ] && tr -cd '0-9' <"$file" || printf '0'
}

vega::diag::_mark_seen() {
  local dir
  dir="$(vega::diag::_state_dir)"
  mkdir -p "$dir" && printf '%s\n' "$1" >"$dir/periodic-seen"
}

vega::diag::_has() {
  local capabilities
  vega::dbus::call_data_into capabilities Metadata Capabilities 2>/dev/null || return 1
  jq -e --arg c "$1" '.[0] | index($c) != null' <<<"$capabilities" >/dev/null
}

# vega::diag::_auth <o que precisa da senha> — antes de uma chamada que pode
# pedir senha: o pkttyagent pergunta no próprio terminal, então a tela do
# dialog sai da frente e o prazo cobre o tempo de digitar. O polkit só aceita a
# senha por um agente; o dialog não pode coletá-la por ele.
VEGA_DIAG_AUTH_TIMEOUT=300
vega::diag::_auth() {
  clear
  printf '%s\n\nSe for pedida, digite a sua senha logo abaixo e tecle Enter.\n\n' "$1"
}

# ---------------------------------------------------------------------------
# Resumo ao abrir o vega

vega::diag::login_summary() {
  vega::diag::_has diagnostics-periodic-v1 || return 0
  local data text
  vega::dbus::call_data_into data Diagnostics LastPeriodic 2>/dev/null || return 0
  text="$(vega::diag::periodic_summary "$data" "$(vega::diag::_seen)")"
  [ -n "$text" ] || return 0
  vega::ui::msgbox "$text" "Novidades na saúde do sistema" || true
  vega::diag::_mark_seen "$(jq -r '.[0]' <<<"$data")"
}

# ---------------------------------------------------------------------------
# Execução com progresso

# vega::diag::_follow <job> — barra de progresso até o job terminar.
vega::diag::_follow() {
  local job="$1"
  {
    local current running stage percent
    while true; do
      vega::dbus::call_data_into current Diagnostics Current 2>/dev/null || break
      running="$(jq -r '.[0][0]' <<<"$current")"
      [ "$running" = "$job" ] || break
      stage="$(jq -r --argjson names "$VEGA_DIAG_NAMES" '.[0][2] as $s | $names[$s] // $s' <<<"$current")"
      percent="$(jq -r '.[0][3]' <<<"$current")"
      printf 'XXX\n%s\nTestando: %s\nXXX\n' "$percent" "$stage"
      sleep 1
    done
    printf 'XXX\n100\nConcluído\nXXX\n'
  } | dialog --backtitle "$VEGA_BACKTITLE" --title "Diagnóstico de saúde" --gauge "Iniciando…" 8 64 0
}

# vega::diag::_report_into <var> <job> — relatório JSON do job.
vega::diag::_report_into() {
  local -n _out="$1"
  local data
  vega::diag::_auth "Lendo o relatório do diagnóstico (inclui trechos do journal)."
  VEGA_DBUS_CALL_TIMEOUT=$VEGA_DIAG_AUTH_TIMEOUT vega::dbus::call_data_into data Diagnostics Report ub "$2" false || return 1
  # shellcheck disable=SC2034 # devolvido por referência
  _out="$(jq -r '.[0]' <<<"$data")"
}

vega::diag::_show_report() {
  local job="$1" report file
  if ! vega::diag::_report_into report "$job"; then
    vega::ui::msgbox "Falha ao ler o relatório: $VEGA_DBUS_LAST_ERROR" "Diagnóstico de saúde"
    return 1
  fi
  file="$(mktemp)"
  vega::diag::report_text "$report" >"$file"
  vega::ui::textbox "$file" "Relatório do diagnóstico" || true
  rm -f -- "$file"
}

# vega::diag::_run <teste...> — inicia, acompanha e mostra o relatório.
vega::diag::_run() {
  local -a args=("as" "$#" "$@" 1 locale s "$(vega::dbus::locale)")
  local data job
  vega::diag::_auth "Iniciando o diagnóstico."
  if ! VEGA_DBUS_CALL_TIMEOUT=$VEGA_DIAG_AUTH_TIMEOUT vega::dbus::call_data_into data Diagnostics Start "${args[0]}a{sv}" "${args[@]:1}"; then
    vega::ui::msgbox "Não foi possível iniciar: $VEGA_DBUS_LAST_ERROR" "Diagnóstico de saúde"
    return 1
  fi
  job="$(jq -r '.[0]' <<<"$data")"
  vega::diag::_follow "$job"
  VEGA_DIAG_LAST_JOB="$job"
}

# ---------------------------------------------------------------------------
# Telas

vega::diag::_quick() {
  vega::ui::yesno "Roda pacotes, disco, logs, plataforma, segurança, boot e rede, sem carga no processador. Leva alguns minutos." \
    "Executar o diagnóstico rápido?" || return 0
  local -a available=()
  local tests id
  vega::dbus::call_data_into tests Diagnostics ListTests || {
    vega::ui::msgbox "$VEGA_DBUS_LAST_ERROR" "Diagnóstico de saúde"
    return 1
  }
  for id in "${VEGA_DIAG_QUICK[@]}"; do
    jq -e --arg id "$id" '.[0][] | select(.[0] == $id and .[1])' <<<"$tests" >/dev/null && available+=("$id")
  done
  vega::diag::_run "${available[@]}" && vega::diag::_show_report "$VEGA_DIAG_LAST_JOB"
}

vega::diag::_one() {
  local tests choice
  vega::dbus::call_data_into tests Diagnostics ListTests || {
    vega::ui::msgbox "$VEGA_DBUS_LAST_ERROR" "Diagnóstico de saúde"
    return 1
  }
  local -a items=()
  mapfile -t items < <(jq -r --argjson names "$VEGA_DIAG_NAMES" '.[0][] | select(.[1]) | .[0], "\($names[.[0]] // .[0]) (~\(.[3]) s)\(if .[4] then " — na tomada" else "" end)"' <<<"$tests")
  choice="$(vega::ui::menu "Executar um teste" "Escolha o teste:" "${items[@]}")" || return 0
  case "$choice" in
  cpu-stress | memory-stress | disk-bench)
    vega::ui::yesno "Este teste deixa o servidor lento por alguns minutos. Continuar?" "Teste de carga" || return 0 ;;
  esac
  vega::diag::_run "$choice" && vega::diag::_show_report "$VEGA_DIAG_LAST_JOB"
}

vega::diag::_fix() {
  local report remedies job
  vega::diag::_report_into report 0 || {
    vega::ui::msgbox "Rode o diagnóstico antes: $VEGA_DBUS_LAST_ERROR" "Corrigir achados"
    return 0
  }
  job="$(jq -r '.jobId' <<<"$report")"
  vega::dbus::call_data_into remedies Diagnostics Remedies u "$job" || {
    vega::ui::msgbox "$VEGA_DBUS_LAST_ERROR" "Corrigir achados"
    return 0
  }
  local -a lines=() items=()
  mapfile -t lines < <(vega::diag::remedy_items "$remedies" "$report")
  if [ "${#lines[@]}" -eq 0 ]; then
    vega::ui::msgbox "O último relatório não tem nada com conserto automático." "Corrigir achados"
    return 0
  fi
  local line
  for line in "${lines[@]}"; do items+=("${line%%$'\t'*}" "${line#*$'\t'}" on); done
  local chosen
  chosen="$(vega::ui::checklist "Corrigir achados" "Marque o que o Vega deve consertar. Antes, um snapshot permite desfazer; depois, os testes afetados rodam de novo." "${items[@]}")" || return 0
  local -a refs=()
  mapfile -t refs <<<"$chosen"
  [ -n "${refs[0]:-}" ] || return 0
  local -a args=("u" "$job" "${#refs[@]}")
  local ref
  for ref in "${refs[@]}"; do args+=("${ref%%:*}" "${ref##*:}"); done
  local data
  vega::diag::_auth "Aplicando os consertos (um snapshot é criado antes)."
  if ! VEGA_DBUS_CALL_TIMEOUT=$VEGA_DIAG_AUTH_TIMEOUT vega::dbus::call_data_into data Diagnostics RepairFindings "ua(su)" "${args[@]:1}"; then
    vega::ui::msgbox "Não foi possível corrigir: $VEGA_DBUS_LAST_ERROR" "Corrigir achados"
    return 0
  fi
  local repair
  repair="$(jq -r '.[0]' <<<"$data")"
  vega::diag::_follow "$repair"
  vega::diag::_show_report "$repair"
}

vega::diag::_seen_logs() {
  local report job
  vega::diag::_report_into report 0 || {
    vega::ui::msgbox "$VEGA_DBUS_LAST_ERROR" "Já vi os logs"
    return 0
  }
  job="$(jq -r '.jobId' <<<"$report")"
  vega::ui::yesno "Os erros, falhas de programas e serviços com falha registrados até o último diagnóstico deixam de contar. O que acontecer depois volta a aparecer." \
    "Marcar os logs como vistos?" || return 0
  vega::diag::_auth "Marcando os logs como vistos."
  if VEGA_DBUS_CALL_TIMEOUT=$VEGA_DIAG_AUTH_TIMEOUT vega::dbus::call Diagnostics MarkLogsSeen u "$job" >/dev/null; then
    vega::ui::msgbox "Pronto. O próximo teste de logs só conta o que acontecer daqui em diante." "Já vi os logs"
  else
    vega::ui::msgbox "Rode o teste de logs e tente de novo: $VEGA_DBUS_LAST_ERROR" "Já vi os logs"
  fi
}

vega::diag::_periodic() {
  local data enabled frequency choice
  vega::dbus::call_data_into data Diagnostics GetPeriodic || {
    vega::ui::msgbox "$VEGA_DBUS_LAST_ERROR" "Verificação periódica"
    return 0
  }
  enabled="$(jq -r '.[0]' <<<"$data")"
  frequency="$(jq -r '.[1]' <<<"$data")"
  choice="$(vega::ui::menu "Verificação periódica" \
    "Confere disco, logs, plataforma e segurança em segundo plano. Hoje: $([ "$enabled" = true ] && echo "ligada" || echo "desligada"), $([ "$frequency" = daily ] && echo "diária" || echo "semanal")." \
    semanal "Ligada, toda semana" \
    diaria "Ligada, todo dia" \
    desligar "Desligada" \
    voltar "Voltar")" || return 0
  case "$choice" in
  semanal) enabled=true frequency=weekly ;;
  diaria) enabled=true frequency=daily ;;
  desligar) enabled=false ;;
  *) return 0 ;;
  esac
  vega::diag::_auth "Mudando a verificação periódica."
  if VEGA_DBUS_CALL_TIMEOUT=$VEGA_DIAG_AUTH_TIMEOUT vega::dbus::call Diagnostics SetPeriodic bs "$enabled" "$frequency" >/dev/null; then
    vega::ui::msgbox "Verificação periódica atualizada." "Verificação periódica"
  else
    vega::ui::msgbox "Não foi possível mudar: $VEGA_DBUS_LAST_ERROR" "Verificação periódica"
  fi
}

vega::diag::open() {
  if ! vega::diag::_has diagnostics-v1; then
    vega::ui::msgbox "Atualize o vegad para usar o diagnóstico de saúde." "Diagnóstico de saúde"
    return 0
  fi
  local actions=false periodic=false choice
  vega::diag::_has diagnostics-actions-v1 && actions=true
  vega::diag::_has diagnostics-periodic-v1 && periodic=true
  while true; do
    local -a menu=(rapido "Executar o diagnóstico rápido" teste "Executar um teste…" relatorio "Ver o último relatório")
    [ "$actions" = true ] && menu+=(corrigir "Corrigir achados…" javi "Já vi os logs")
    [ "$periodic" = true ] && menu+=(periodica "Verificação periódica…")
    menu+=(voltar "Voltar")
    choice="$(vega::ui::menu "Diagnóstico de saúde" "Testa disco, sistema e segurança sem alterar nada." "${menu[@]}")" || return 0
    case "$choice" in
    rapido) vega::diag::_quick || true ;;
    teste) vega::diag::_one || true ;;
    relatorio) vega::diag::_show_report 0 || true ;;
    corrigir) vega::diag::_fix || true ;;
    javi) vega::diag::_seen_logs || true ;;
    periodica) vega::diag::_periodic || true ;;
    voltar | "") return 0 ;;
    esac
  done
}

# Rede e Firewall → Minha internet não funciona
vega::diag::network() {
  if ! vega::diag::_has diagnostics-v4; then
    vega::ui::msgbox "Atualize o vegad para usar o teste de rede." "Minha internet não funciona"
    return 0
  fi
  vega::diag::_run network || return 0
  local job="$VEGA_DIAG_LAST_JOB" report file
  vega::diag::_report_into report "$job" || {
    vega::ui::msgbox "Falha ao ler o resultado: $VEGA_DBUS_LAST_ERROR" "Minha internet não funciona"
    return 0
  }
  file="$(mktemp)"
  vega::diag::network_text "$report" >"$file"
  vega::ui::textbox "$file" "Minha internet não funciona" || true
  rm -f -- "$file"
  local remedies
  vega::dbus::call_data_into remedies Diagnostics Remedies u "$job" 2>/dev/null || return 0
  [ "$(jq -r '.[0] | length' <<<"$remedies")" -gt 0 ] || return 0
  vega::ui::yesno "$(vega::diag::remedy_items "$remedies" "$report" | cut -f2)" "Aplicar o conserto?" || return 0
  local data args=()
  mapfile -t args < <(jq -r '.[0] | length, (.[] | .[0], .[1])' <<<"$remedies")
  vega::diag::_auth "Aplicando o conserto da rede."
  if VEGA_DBUS_CALL_TIMEOUT=$VEGA_DIAG_AUTH_TIMEOUT vega::dbus::call_data_into data Diagnostics RepairFindings "ua(su)" "$job" "${args[@]}"; then
    local repair
    repair="$(jq -r '.[0]' <<<"$data")"
    vega::diag::_follow "$repair"
    vega::diag::_report_into report "$repair" && {
      vega::diag::network_text "$report" >"$file"
      vega::ui::textbox "$file" "Depois do conserto" || true
      rm -f -- "$file"
    }
  else
    vega::ui::msgbox "Não foi possível consertar: $VEGA_DBUS_LAST_ERROR" "Minha internet não funciona"
  fi
}

# Armazenamento → Liberar espaço (categorias do sistema)
vega::cleanup::open() {
  if ! vega::diag::_has space-cleanup-v1; then
    vega::ui::msgbox "Atualize o vegad para usar o Liberar espaço." "Liberar espaço"
    return 0
  fi
  vega::ui::infobox "Medindo o que pode ser liberado…" "Liberar espaço"
  local data
  vega::dbus::call_data_into data Cleanup Scan || {
    vega::ui::msgbox "Falha ao medir: $VEGA_DBUS_LAST_ERROR" "Liberar espaço"
    return 0
  }
  local -a lines=() items=()
  mapfile -t lines < <(vega::cleanup::items "$data")
  if [ -z "${lines[0]:-}" ]; then
    vega::ui::msgbox "Nada para limpar agora." "Liberar espaço"
    return 0
  fi
  local line id rest
  for line in "${lines[@]}"; do
    id="${line%%$'\t'*}"; rest="${line#*$'\t'}"
    items+=("$id" "${rest%$'\t'*}" "${rest##*$'\t'}")
  done
  local chosen
  chosen="$(vega::ui::checklist "Liberar espaço" "Kernels antigos e snapshots só saem se você marcar." "${items[@]}")" || return 0
  local -a ids=()
  mapfile -t ids <<<"$chosen"
  [ -n "${ids[0]:-}" ] || return 0
  vega::ui::yesno "Estes itens serão apagados (não dá para desfazer):
$(printf '  • %s\n' "${ids[@]}")" "Liberar espaço?" || return 0
  vega::diag::_auth "Liberando espaço."
  local message
  if VEGA_DBUS_CALL_TIMEOUT=$VEGA_DIAG_AUTH_TIMEOUT vega::dbus::run_transaction_into message Cleanup Clean Finished as "${ids[@]}"; then
    local result="${message%%:*}" freed="${message##*:}"
    vega::ui::msgbox "$(vega::diag::bytes "$freed") liberados.$([ "$result" = partial ] && printf '\nAlgumas categorias não puderam ser limpas; veja o log do vegad.')" "Liberar espaço"
  else
    vega::ui::msgbox "A limpeza falhou: $VEGA_DBUS_LAST_ERROR" "Liberar espaço"
  fi
}
