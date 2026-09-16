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

# Capture stdout while running the function in THIS shell, so its error state
# survives. Only the file read uses command substitution (same trailing-newline
# behavior as Bash's $(...)); no stateful D-Bus function runs in a subshell.
# Output names must be ordinary scalar variables. The __vega_capture_ prefix
# is reserved for this helper's locals to avoid Bash dynamic-scope collisions.
vega::dbus::_capture() {
  local __vega_capture_name="${1:-}"
  shift
  VEGA_DBUS_LAST_ERROR=""
  if [[ ! $__vega_capture_name =~ ^[a-zA-Z_][a-zA-Z_0-9]*$ ||
        $__vega_capture_name == __vega_capture_* ||
        $__vega_capture_name == VEGA_DBUS_* ]]; then
    VEGA_DBUS_LAST_ERROR="Variável de saída inválida para chamada D-Bus."
    return 2
  fi
  printf -v "$__vega_capture_name" '%s' ""
  local __vega_capture_file __vega_capture_rc=0
  __vega_capture_file="$(mktemp)" || {
    VEGA_DBUS_LAST_ERROR="Não foi possível preparar a saída da chamada D-Bus."
    return 1
  }
  "$@" >"$__vega_capture_file" || __vega_capture_rc=$?
  if [ "$__vega_capture_rc" -eq 0 ]; then
    printf -v "$__vega_capture_name" '%s' "$(<"$__vega_capture_file")"
  fi
  rm -f -- "$__vega_capture_file"
  return "$__vega_capture_rc"
}

# Prefer these APIs when the caller needs both a result and LAST_ERROR.
# Usage: vega::dbus::call_data_into data System Ping
vega::dbus::call_into() {
  vega::dbus::_capture "$1" vega::dbus::call "${@:2}"
}
vega::dbus::call_data_into() {
  vega::dbus::_capture "$1" vega::dbus::call_data "${@:2}"
}
vega::dbus::run_transaction_into() {
  VEGA_DBUS_TRANSACTION_KEY_PENDING=""
  vega::dbus::_capture "$1" vega::dbus::run_transaction "${@:2}"
}

# Locale enviado explicitamente nas chamadas que retornam texto de interface.
# Nunca deixamos o locale global do serviço decidir a resposta de outro usuário.
vega::dbus::_gnome_language() {
  local username="${SUDO_USER:-${USER:-}}" user_reply user_path language_reply
  [ -n "$username" ] || return 1
  user_reply="$(busctl --system call org.freedesktop.Accounts \
    /org/freedesktop/Accounts org.freedesktop.Accounts \
    FindUserByName s "$username" 2>/dev/null)" || return 1
  user_path="${user_reply#*\"}"
  user_path="${user_path%%\"*}"
  [ -n "$user_path" ] || return 1
  language_reply="$(busctl --system get-property org.freedesktop.Accounts \
    "$user_path" org.freedesktop.Accounts.User Language 2>/dev/null)" || return 1
  language_reply="${language_reply#*\"}"
  language_reply="${language_reply%%\"*}"
  [ -n "$language_reply" ] || return 1
  printf '%s' "$language_reply"
}

vega::dbus::locale() {
  local value
  value="$(vega::dbus::_gnome_language)" || value="${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}"
  value="${value%%@*}"
  value="${value%%.*}"
  value="${value/_/-}"
  case "${value,,}" in
  en-us) printf 'en-US' ;;
  pt-br) printf 'pt-BR' ;;
  es-es) printf 'es-ES' ;;
  *) printf 'en-US' ;;
  esac
}

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
  VEGA_DBUS_LAST_ERROR=""
  local interface="$1" method="$2"
  shift 2
  local request_locale
  request_locale="$(vega::dbus::locale)"
  case "$interface:$method" in
  Hardware:Inventory | Hardware:FirmwareStatus | Services:ListServices | Services:ListAllServices)
    method="${method}Localized"
    set -- s "$request_locale" "$@"
    ;;
  Snapshots:DiffPackages)
    method="DiffPackagesLocalized"
    set -- us "${2:?snapshot id missing}" "$request_locale"
    ;;
  esac
  local out err_file rc=0
  err_file="$(mktemp)" || {
    VEGA_DBUS_LAST_ERROR="Não foi possível preparar a chamada D-Bus."
    return 1
  }
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
  local raw parsed rc=0
  vega::dbus::call_into raw "$@" || return $?
  parsed="$(printf '%s' "$raw" | jq -ce '.data | if type == "array" then . else error("invalid data") end' 2>/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    VEGA_DBUS_LAST_ERROR="Resposta JSON inválida recebida do vegad."
    return "$rc"
  fi
  printf '%s\n' "$parsed"
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
# O helper usa uma conexão dedicada Gio e confirma AddMatch antes de chamar
# o método. Filtra por unique owner + transactionId e mantém prazo absoluto.
# RepoKeyPending, quando presente, vem apenas da mesma transação AddRepo.
VEGA_DBUS_TRANSACTION_KEY_PENDING=""

vega::dbus::_transaction_helper() {
  /usr/bin/python3 "${BASH_SOURCE[0]%/*}/transaction.py" "$@"
}

vega::dbus::run_transaction() {
  VEGA_DBUS_LAST_ERROR=""
  VEGA_DBUS_TRANSACTION_KEY_PENDING=""
  local reply err_file rc=0 transaction_timeout="$VEGA_DBUS_TRANSACTION_TIMEOUT"
  # A verified OS backup plus RPM downloads may exceed the ordinary 15-minute
  # observation budget. Keep the exception fixed to this one typed operation.
  if [ "${1:-}" = Software ] && [ "${2:-}" = InstallNvidia ]; then transaction_timeout=7200; fi
  err_file="$(mktemp)" || {
    VEGA_DBUS_LAST_ERROR="Não foi possível preparar a espera da transação."
    return 1
  }
  reply="$(vega::dbus::_transaction_helper \
    --timeout "$transaction_timeout" \
    --call-timeout "${VEGA_DBUS_CALL_TIMEOUT:-$VEGA_DBUS_TIMEOUT}" -- "$@" 2>"$err_file")" || rc=$?
  if ! printf '%s' "$reply" | jq -e 'type == "object" and (.success | type == "boolean") and (.message | type == "string")' >/dev/null 2>&1; then
    VEGA_DBUS_LAST_ERROR="$(vega::dbus::_friendly_error "$(<"$err_file")")"
    rm -f -- "$err_file"
    return 1
  fi
  rm -f -- "$err_file"
  if [ "$rc" -eq 0 ] && [ "$(printf '%s' "$reply" | jq -r '.success')" = true ]; then
    printf '%s' "$reply" | jq -j '.message'
    return 0
  fi
  # shellcheck disable=SC2034 # output consumed by the Software module
  VEGA_DBUS_TRANSACTION_KEY_PENDING="$(printf '%s' "$reply" | jq -c '.key_pending // empty')"
  # shellcheck disable=SC2034 # output consumed by the calling module
  VEGA_DBUS_LAST_ERROR="$(vega::dbus::_friendly_error "$(printf '%s' "$reply" | jq -r '.message')")"
  return 1
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
    msg="${msg#Call failed: }"
    printf '%s\n' "${msg:-A chamada ao vegad falhou sem detalhes.}"
    ;;
  esac
}
