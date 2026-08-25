#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary="$(mktemp -d)"
trap 'rm -rf -- "$temporary"' EXIT
export MOCK_BUSCTL_LOG="$temporary/busctl.log"

cat >"$temporary/busctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$MOCK_BUSCTL_LOG"
if [ "${MOCK_BUSCTL_FAIL:-0}" -ne 0 ]; then
  printf '%s\n' "${MOCK_BUSCTL_ERROR:-Call failed: mock failure}" >&2
  exit "$MOCK_BUSCTL_FAIL"
fi
printf '%s\n' "${MOCK_BUSCTL_OUTPUT:-{\"type\":\"s\",\"data\":[\"ok\"]}}"
EOF
chmod +x "$temporary/busctl"
PATH="$temporary:$PATH"
export PATH

# shellcheck source=/dev/null
source "$repo_root/lib/dbus.sh"
vega::dbus::locale() { printf 'pt-BR'; }

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_log() { grep -F -- "$1" "$MOCK_BUSCTL_LOG" >/dev/null || fail "missing busctl args: $1"; }

result="$(vega::dbus::call Logs Query ssssu system.service warning -1hour error 100)"
[ -n "$result" ] || fail "successful call returned no JSON"
assert_log '--system --json=short --timeout=30 call org.lyraos.Vega1 /org/lyraos/Vega1 org.lyraos.Vega1.Logs Query -- ssssu system.service warning -1hour error 100'

: >"$MOCK_BUSCTL_LOG"
vega::dbus::call Hardware Inventory >/dev/null
assert_log 'org.lyraos.Vega1.Hardware InventoryLocalized -- s pt-BR'

MOCK_BUSCTL_FAIL=1
MOCK_BUSCTL_ERROR='Call failed: org.freedesktop.PolicyKit1.Error.NotAuthorized'
export MOCK_BUSCTL_FAIL MOCK_BUSCTL_ERROR
if vega::dbus::call Users RemoveUser s alice >/dev/null; then
  fail "failed busctl call was accepted"
fi
[[ "$VEGA_DBUS_LAST_ERROR" == *"não autorizada"* ]] || fail "polkit error was not translated"

echo "vega-cli D-Bus mock tests passed"
