#!/usr/bin/env bash
# Módulo "Monitor do Sistema": CPU (agregado e por núcleo), memória, swap,
# disco, rede (só valores em texto, sem gráficos — decisão explícita de
# escopo do v4.0, ver issue #115) e lista de processos com hierarquia
# pai/filho + encerrar processo. Equivalente ao módulo Monitor do vega-gtk
# (org.lyraos.Vega1.Monitor, vega-gtk/src/ui/monitor.rs), trocando os
# sparklines por texto puro. Sourced pelo entrypoint (bin/vega) — não é
# executável sozinho.

# vega::monitor::_formatar_bytes <bytes>
vega::monitor::_formatar_bytes() {
  local bytes="${1:-0}" unit=0
  local -a unidades=(B KiB MiB GiB TiB)
  local valor="$bytes"
  while [ "${valor%.*}" -ge 1024 ] 2>/dev/null && [ "$unit" -lt 4 ]; do
    valor="$(awk -v v="$valor" 'BEGIN { printf "%.4f", v / 1024 }')"
    unit=$((unit + 1))
  done
  if [ "$unit" -eq 0 ]; then
    printf '%s %s' "$bytes" "${unidades[$unit]}"
  else
    printf '%s %s' "$(awk -v v="$valor" 'BEGIN { printf "%.1f", v }')" "${unidades[$unit]}"
  fi
}

# vega::monitor::_recursos_amostra <arquivo de saída>
# Roda em background: anexa uma amostra formatada de métricas ao arquivo a
# cada 2s, até ser morto pelo chamador. Taxas de disco/rede exigem duas
# amostras (calculadas a partir dos contadores cumulativos do vegad) — a
# primeira amostra sempre mostra "Calculando…" pra essas duas linhas,
# igual ao vega-gtk (rates: Option<Rates> == None na primeira leitura).
vega::monitor::_recursos_amostra() {
  local tmpfile="$1"
  local prev_read=0 prev_write=0 prev_rx=0 prev_tx=0 prev_time=0 have_prev=0
  while true; do
    local data
    data="$(vega::dbus::call_data Monitor Metrics 2>/dev/null)" || {
      sleep 2
      continue
    }
    local cpu memused memtotal swapused swaptotal diskread diskwrite netrx nettx
    cpu="$(printf '%s' "$data" | jq -r '.[0][0] | (. * 10 | round) / 10')"
    memused="$(printf '%s' "$data" | jq -r '.[0][1]')"
    memtotal="$(printf '%s' "$data" | jq -r '.[0][2]')"
    swapused="$(printf '%s' "$data" | jq -r '.[0][3]')"
    swaptotal="$(printf '%s' "$data" | jq -r '.[0][4]')"
    diskread="$(printf '%s' "$data" | jq -r '.[0][5]')"
    diskwrite="$(printf '%s' "$data" | jq -r '.[0][6]')"
    netrx="$(printf '%s' "$data" | jq -r '.[0][7]')"
    nettx="$(printf '%s' "$data" | jq -r '.[0][8]')"

    local now disco_txt rede_txt
    now="$(date +%s)"
    if [ "$have_prev" = 1 ] && [ "$now" -gt "$prev_time" ]; then
      local delta=$((now - prev_time))
      local dr=$(((diskread - prev_read) / delta))
      local dw=$(((diskwrite - prev_write) / delta))
      local nr=$(((netrx - prev_rx) / delta))
      local nt=$(((nettx - prev_tx) / delta))
      disco_txt="$(vega::monitor::_formatar_bytes "$dr")/s leitura • $(vega::monitor::_formatar_bytes "$dw")/s escrita"
      rede_txt="$(vega::monitor::_formatar_bytes "$nr")/s recebido • $(vega::monitor::_formatar_bytes "$nt")/s enviado"
    else
      disco_txt="Calculando…"
      rede_txt="Calculando…"
    fi
    prev_read="$diskread"; prev_write="$diskwrite"; prev_rx="$netrx"; prev_tx="$nettx"
    prev_time="$now"; have_prev=1

    {
      echo "== $(date '+%H:%M:%S') =="
      echo "CPU: ${cpu}%"
      printf '%s' "$data" | jq -r '.[0][9] | to_entries[] | "  Núcleo \(.key): \(.value | round)%"' 2>/dev/null
      echo "Memória: $(vega::monitor::_formatar_bytes "$memused") de $(vega::monitor::_formatar_bytes "$memtotal")"
      if [ "$swaptotal" = "0" ]; then
        echo "Swap: sem swap configurado"
      else
        echo "Swap: $(vega::monitor::_formatar_bytes "$swapused") de $(vega::monitor::_formatar_bytes "$swaptotal")"
      fi
      echo "Disco: $disco_txt"
      echo "Rede: $rede_txt"
      echo
    } >>"$tmpfile"
    sleep 2
  done
}

vega::monitor::_recursos() {
  local tmpfile
  tmpfile="$(mktemp)"
  vega::monitor::_recursos_amostra "$tmpfile" &
  local bgpid=$!

  # Dá tempo pra pelo menos uma amostra existir antes de abrir o tailbox
  # (senão ele abre num arquivo vazio e só mostra algo depois de 2s).
  sleep 1

  vega::ui::tailbox "$tmpfile" "Monitor do Sistema — Recursos"

  kill "$bgpid" >/dev/null 2>&1 || true
  wait "$bgpid" 2>/dev/null || true
  rm -f "$tmpfile"
}

# vega::monitor::_processos
# Lista os processos (vega-gtk lê /proc, ordena por CPU/memória e trunca em
# 250 — igual ao vegad), monta a árvore pai/filho com indentação em texto
# no lugar da margem visual do vega-gtk, e permite encerrar (SIGTERM) um
# processo selecionado.
vega::monitor::_processos() {
  while true; do
    vega::ui::infobox "Carregando processos…" "Monitor do Sistema"
    local data rc=0
    data="$(vega::dbus::call_data Monitor ListProcesses)" || rc=$?
    if [ "$rc" -ne 0 ]; then
      vega::ui::msgbox "Falha ao listar processos: $VEGA_DBUS_LAST_ERROR" "Monitor do Sistema"
      return
    fi
    local count
    count="$(printf '%s' "$data" | jq -r '.[0] | length')"
    if [ "$count" -eq 0 ]; then
      vega::ui::msgbox "Nenhum processo listado." "Monitor do Sistema"
      return
    fi

    local -a pids ppids names users cpus mems states
    local -a rows
    mapfile -t rows < <(printf '%s' "$data" | jq -r '.[0][] |
      [(.[0]|tostring),(.[1]|tostring),.[2],.[3],(.[4]|tostring),(.[5]|tostring),.[6]] | join("")')
    local idx=0 row pid ppid name user cpu mem state
    for row in "${rows[@]}"; do
      IFS=$'\x1f' read -r pid ppid name user cpu mem state <<<"$row"
      pids[idx]="$pid"; ppids[idx]="$ppid"; names[idx]="$name"; users[idx]="$user"
      cpus[idx]="$cpu"; mems[idx]="$mem"; states[idx]="$state"
      idx=$((idx + 1))
    done
    local n="$idx"

    # --- árvore pai/filho (porta de build_process_tree) ---
    # is_child[i]=1 se i é filho de algum outro processo visível.
    # filhos_de[<pid do pai>] = "i1 i2 i3" (índices, ordem original).
    local -A is_child=() filhos_de=() pid_para_idx=()
    local i
    for ((i = 0; i < n; i++)); do
      pid_para_idx["${pids[$i]}"]="$i"
    done
    for ((i = 0; i < n; i++)); do
      local meu_ppid="${ppids[$i]}" meu_pid="${pids[$i]}"
      if [ "$meu_ppid" != "$meu_pid" ] && [ -n "${pid_para_idx[$meu_ppid]:-}" ]; then
        filhos_de["$meu_ppid"]="${filhos_de[$meu_ppid]:-} $i"
        is_child["$i"]=1
      fi
    done

    # Pilha "idx,depth"; raízes empilhadas ao contrário pra sair na ordem
    # original ao desempilhar do fim (mesmo truque do .rev() em Rust).
    local -a pilha=()
    for ((i = n - 1; i >= 0; i--)); do
      [ -z "${is_child[$i]:-}" ] && pilha+=("$i,0")
    done

    local -a ordem=()
    local -A visitado=()
    while [ "${#pilha[@]}" -gt 0 ]; do
      local topo="${pilha[-1]}"
      unset 'pilha[-1]'
      pilha=("${pilha[@]}")
      local cur_idx="${topo%,*}" cur_depth="${topo#*,}"
      [ -n "${visitado[$cur_idx]:-}" ] && continue
      visitado["$cur_idx"]=1
      ordem+=("$cur_idx,$cur_depth")
      local filhos="${filhos_de[${pids[$cur_idx]}]:-}"
      if [ -n "$filhos" ]; then
        local -a lista_filhos=($filhos)
        local j
        for ((j = ${#lista_filhos[@]} - 1; j >= 0; j--)); do
          pilha+=("${lista_filhos[$j]},$((cur_depth + 1))")
        done
      fi
    done
    # ---------------------------------------------------------

    local -a menu_args=()
    local par
    for par in "${ordem[@]}"; do
      local idx_i="${par%,*}" prof="${par#*,}"
      local indent=""
      local d
      for ((d = 0; d < prof; d++)); do indent+="  "; done
      menu_args+=("${pids[$idx_i]}" \
        "${indent}${names[$idx_i]} — PID ${pids[$idx_i]} • ${users[$idx_i]} • ${states[$idx_i]} • ${cpus[$idx_i]}% • $(vega::monitor::_formatar_bytes "${mems[$idx_i]}")")
    done
    menu_args+=(voltar "Voltar")

    local choice
    choice="$(vega::ui::menu "Processos ($count)" "Escolha um processo:" "${menu_args[@]}")" || return
    [ "$choice" = "voltar" ] && return

    local nome_escolhido="${choice}"
    for ((i = 0; i < n; i++)); do
      [ "${pids[$i]}" = "$choice" ] && nome_escolhido="${names[$i]}"
    done

    vega::ui::yesno "$nome_escolhido (PID $choice) será encerrado (SIGTERM)." "Encerrar processo?" || continue
    vega::ui::infobox "Encerrando processo $choice…" "Monitor do Sistema"
    if vega::dbus::call Monitor KillProcess u "$choice" >/dev/null; then
      vega::ui::msgbox "Processo encerrado." "Monitor do Sistema"
    else
      vega::ui::msgbox "Falha ao encerrar: $VEGA_DBUS_LAST_ERROR" "Monitor do Sistema"
    fi
  done
}

# ---------------------------------------------------------------------------

vega::module_monitor() {
  local choice
  while true; do
    choice="$(vega::ui::menu "Monitor do Sistema" "Escolha uma área:" \
      recursos "Recursos (CPU, memória, swap, disco, rede)" \
      processos "Processos" \
      voltar "Voltar")" || return

    case "$choice" in
    recursos) vega::monitor::_recursos || true ;;
    processos) vega::monitor::_processos || true ;;
    voltar | "") return ;;
    esac
  done
}
