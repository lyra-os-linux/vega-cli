#!/usr/bin/env bash
# Acesso a D-Bus: busctl --json=short + jq contra o barramento de sistema
# exportado pelo vegad (org.lyraos.Vega1.*, ver vegad/internal/dbusserver).
# JSON é bem mais fácil de tratar em shell do que o formato texto do
# GVariant para os structs/arrays aninhados do contrato (SystemMetrics,
# ProcessInfo, etc.) — por isso busctl em vez de gdbus/dbus-send.
# Sourced pelo entrypoint (bin/vega) — não é executável sozinho.

VEGA_DBUS_BUS_NAME="org.lyraos.Vega1"
VEGA_DBUS_OBJECT_PATH="/org/lyraos/Vega1"
VEGA_DBUS_TIMEOUT="30"
# Orçamento de tempo para vega::dbus::run_transaction — operações reais
# (baixar e instalar pacotes, etc.) podem levar bem mais que o timeout de
# uma chamada D-Bus comum.
VEGA_DBUS_TRANSACTION_TIMEOUT="900"
readonly VEGA_DBUS_BUS_NAME VEGA_DBUS_OBJECT_PATH VEGA_DBUS_TIMEOUT VEGA_DBUS_TRANSACTION_TIMEOUT

# Erro da última chamada que falhou, já traduzido — quem chama decide como
# mostrar isso (msgbox etc.). vega::dbus::call só retorna != 0.
VEGA_DBUS_LAST_ERROR=""

# vega::dbus::call <interface> <method> [assinatura arg...]
# <interface> é só o sufixo do contrato (ex. "Monitor"), prefixado aqui com
# org.lyraos.Vega1. Argumentos extras seguem o formato do busctl call:
# "<assinatura> <arg1> <arg2> ...", ex.: vega::dbus::call Services
# SetServiceEnabled sb sshd.service true
#
# O timeout usado é $VEGA_DBUS_CALL_TIMEOUT se o chamador setar essa
# variável antes de chamar (ex.: `VEGA_DBUS_CALL_TIMEOUT=60
# vega::dbus::call Software Search ...` — busca com backend tipo Flathub
# pode ser bem mais lenta que uma chamada comum), senão o padrão
# $VEGA_DBUS_TIMEOUT.
#
# Em sucesso, imprime o JSON de retorno (--json=short) em stdout. Em erro,
# não imprime nada, seta VEGA_DBUS_LAST_ERROR e retorna o código de saída
# do busctl (sempre != 0).
vega::dbus::call() {
  local interface="$1" method="$2"
  shift 2
  local out err_file rc=0
  err_file="$(mktemp)"
  # "--" antes dos argumentos: sem isso, um argumento de dado que comece
  # com "-" (ex.: o filtro de período "-1hour" do módulo Logs) é lido pelo
  # parser de opções do próprio busctl em vez de como valor — busctl
  # aborta com "invalid option" antes de sequer tentar a chamada D-Bus.
  out="$(busctl --system --json=short --timeout="${VEGA_DBUS_CALL_TIMEOUT:-$VEGA_DBUS_TIMEOUT}" call \
    "$VEGA_DBUS_BUS_NAME" "$VEGA_DBUS_OBJECT_PATH" \
    "$VEGA_DBUS_BUS_NAME.$interface" "$method" -- "$@" 2>"$err_file")" || rc=$?

  if [ "$rc" -ne 0 ]; then
    VEGA_DBUS_LAST_ERROR="$(vega::dbus::_friendly_error "$(<"$err_file")")"
    rm -f "$err_file"
    return "$rc"
  fi

  rm -f "$err_file"
  printf '%s\n' "$out"
}

# vega::dbus::call_data <interface> <method> [assinatura arg...]
# Igual a vega::dbus::call, mas já extrai com jq só o array de valores de
# retorno (campo "data" do --json=short) — a forma mais comum de consumir
# a resposta nos módulos.
vega::dbus::call_data() {
  local raw
  raw="$(vega::dbus::call "$@")" || return $?
  printf '%s' "$raw" | jq -c '.data'
}

# vega::dbus::run_transaction <interface> <método> <sinal-finished> [assinatura arg...]
# Para métodos assíncronos do vegad que devolvem um transactionId (uint32) e
# reportam o resultado de verdade via um sinal "<interface>.<sinal-finished>"
# (transactionId, success, message) — ex. Software.Install +
# "TransactionFinished", Backup.RunBackupNow + "BackupFinished",
# Backup.RestoreSnapshot + "RestoreFinished" (o nome do sinal muda por
# método, não só por interface — Backup usa sinais diferentes pra backup e
# restore). O método em si só confirma que a transação começou; sem esperar
# o sinal não dá pra saber se ela terminou nem se deu certo.
#
# `busctl wait` escuta o sinal sem precisar de privilégio de "monitor"
# (diferente de `busctl monitor`, que exige acesso de eavesdrop e falha pra
# usuário comum) — mas registrar esse wait DEPOIS de chamar o método
# arrisca perder transações rápidas que já terminam antes da gente começar
# a escutar; por isso o wait começa em background antes da chamada.
#
# Em sucesso, imprime a mensagem final (a mesma do sinal) em stdout e
# retorna 0. Em erro — da chamada inicial, de timeout (ver nota abaixo) ou
# de transação que terminou com success=false — retorna 1 e deixa a
# mensagem em VEGA_DBUS_LAST_ERROR.
vega::dbus::run_transaction() {
  local interface="$1" method="$2" finished_signal="$3"
  shift 3

  local wait_out wait_pid
  wait_out="$(mktemp)"
  busctl --system --json=short wait "$VEGA_DBUS_OBJECT_PATH" \
    "$VEGA_DBUS_BUS_NAME.$interface" "$finished_signal" \
    >"$wait_out" 2>/dev/null &
  wait_pid=$!
  # Pequena folga pro busctl terminar de registrar o match no bus antes da
  # transação começar — não elimina a corrida, só encolhe a janela.
  sleep 0.2

  local start_json start_rc=0
  start_json="$(vega::dbus::call "$interface" "$method" "$@")" || start_rc=$?
  if [ "$start_rc" -ne 0 ]; then
    kill "$wait_pid" >/dev/null 2>&1 || true
    wait "$wait_pid" 2>/dev/null || true
    rm -f "$wait_out"
    return "$start_rc"
  fi
  local tx_id
  tx_id="$(printf '%s' "$start_json" | jq -r '.data[0]')"

  # `busctl wait` some sozinho depois do --timeout do próprio comando (que
  # não controlamos aqui de forma fina): se o tempo estourar sem sinal
  # nenhum, ele sai com status 0 e stdout VAZIO — sem essa checagem de
  # arquivo vazio, um timeout silencioso pareceria sucesso.
  local elapsed=0
  while kill -0 "$wait_pid" 2>/dev/null; do
    if [ "$elapsed" -ge "$VEGA_DBUS_TRANSACTION_TIMEOUT" ]; then
      kill "$wait_pid" >/dev/null 2>&1 || true
      break
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  wait "$wait_pid" 2>/dev/null || true

  if [ ! -s "$wait_out" ]; then
    rm -f "$wait_out"
    VEGA_DBUS_LAST_ERROR="Tempo esgotado aguardando a conclusão da transação #$tx_id (nenhum sinal recebido do vegad)."
    return 1
  fi

  local finished_id finished_success finished_message
  finished_id="$(jq -r '.data[0]' <"$wait_out")"
  finished_success="$(jq -r '.data[1]' <"$wait_out")"
  finished_message="$(jq -r '.data[2]' <"$wait_out")"
  rm -f "$wait_out"

  if [ "$finished_id" != "$tx_id" ]; then
    VEGA_DBUS_LAST_ERROR="Sinal de transação recebido não corresponde (esperado #$tx_id, recebido #$finished_id) — outra transação pode estar em andamento no mesmo vegad."
    return 1
  fi

  if [ "$finished_success" != "true" ]; then
    VEGA_DBUS_LAST_ERROR="$finished_message"
    return 1
  fi

  printf '%s' "$finished_message"
}

# Traduz os erros mais comuns do busctl (vegad fora do ar, timeout, polkit
# negando) pra mensagem em pt-br; no caso genérico, devolve a mensagem
# original do busctl sem o prefixo "Call failed: ".
vega::dbus::_friendly_error() {
  local msg="$1"
  case "$msg" in
  *"was not provided by any .service"* | *"is not activatable"*)
    echo "vegad não está disponível no D-Bus (serviço não instalado ou não ativável)."
    ;;
  *"Connection timed out"* | *"Message did not receive a reply"* | *"Activation request timed out"*)
    echo "vegad não respondeu a tempo (timeout)."
    ;;
  *"org.freedesktop.PolicyKit1.Error.NotAuthorized"* | *"Authorization"* | *"authentication"* | *"not authorized"*)
    echo "Ação não autorizada (autenticação polkit recusada ou cancelada)."
    ;;
  *)
    echo "${msg#Call failed: }"
    ;;
  esac
}
