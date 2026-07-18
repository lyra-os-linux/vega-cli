#!/usr/bin/env bash
# Smoke test do vega-cli (issue #116) — complementa scripts/qa-smoke.sh
# (que só verifica build/lint/empacotamento, sem rodar nada do vega-cli).
#
# O que este script cobre de forma automática e confiável, sem precisar de
# sessão gráfica nem de interação humana:
#   1. dialog/jq/busctl presentes;
#   2. sintaxe de bin/vega e de todo vega-cli/lib/*.sh;
#   3. os libs sourceiam limpo sob `set -euo pipefail` e toda função
#      vega::module_* esperada está definida (pega regressão de wiring, ex.:
#      um módulo esquecido em menu.sh apontando pro vega::module_placeholder
#      removido);
#   4. cada módulo tem pelo menos uma chamada D-Bus de leitura real
#      funcionando contra o vegad do host que rodar este script.
#
# O que este script NÃO consegue automatizar com confiança neste ambiente
# (script/dialog não dão um pty confiável o suficiente pra manipular
# dialog via stdin de forma estável) — ver critério de aceite da #116:
#   - abrir o `vega` de verdade e navegar pelas telas interativamente;
#   - sair via Ctrl+C e confirmar que o terminal volta ao normal;
#   - uma ação privilegiada pedindo e aceitando autenticação polkit via
#     pkttyagent numa sessão SSH real (sem agente gráfico).
# Esses três ficam como checklist manual no final — rodar isso numa
# VM/container limpo, só com acesso SSH, é o critério de aceite da issue,
# e exige um humano (ou outro agente) na sessão real pra digitar a senha.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cli_root="$repo_root/vega-cli"

echo "[1/4] Dependências de runtime (dialog, jq, busctl)"
missing=()
for cmd in dialog jq busctl; do
  command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "Erro: dependência(s) faltando: ${missing[*]}" >&2
  exit 1
fi
if ! command -v pkttyagent >/dev/null 2>&1; then
  echo "Aviso: 'pkttyagent' não encontrado — ações privilegiadas via SSH não vão"
  echo "conseguir pedir senha (term.sh trata isso como não-fatal, mas invalida"
  echo "o item de autenticação polkit do checklist manual abaixo)."
fi

echo "[2/4] Sintaxe de bin/vega e vega-cli/lib/*.sh"
bash -n "$cli_root/bin/vega"
for file in "$cli_root"/lib/*.sh; do
  bash -n "$file"
done

echo "[3/4] Sourcing limpo + wiring de todo módulo"
expected_modules=(
  vega::module_painel
  vega::module_software
  vega::module_backup
  vega::module_hardware
  vega::module_users
  vega::module_network
  vega::module_services
  vega::module_datetime
  vega::module_storage
  vega::module_logs
  vega::module_monitor
  vega::module_about
  vega::main_menu
)
# shellcheck disable=SC1091
source_check="$(
  bash -c '
    set -euo pipefail
    for f in "'"$cli_root"'"/lib/ui.sh "'"$cli_root"'"/lib/dbus.sh "'"$cli_root"'"/lib/term.sh \
             "'"$cli_root"'"/lib/painel.sh "'"$cli_root"'"/lib/software.sh "'"$cli_root"'"/lib/backup.sh \
             "'"$cli_root"'"/lib/hardware.sh "'"$cli_root"'"/lib/users.sh "'"$cli_root"'"/lib/network.sh \
             "'"$cli_root"'"/lib/services.sh "'"$cli_root"'"/lib/datetime.sh "'"$cli_root"'"/lib/storage.sh \
             "'"$cli_root"'"/lib/logs.sh "'"$cli_root"'"/lib/monitor.sh "'"$cli_root"'"/lib/menu.sh; do
      source "$f"
    done
    for fn in '"${expected_modules[*]}"'; do
      type "$fn" >/dev/null 2>&1 || { echo "FALTANDO: $fn"; exit 1; }
    done
    echo OK
  '
)"
if [ "$source_check" != "OK" ]; then
  echo "Erro no sourcing/wiring: $source_check" >&2
  exit 1
fi

echo "[4/4] Uma operação read-only real por módulo, contra o vegad deste host"
# shellcheck source=/dev/null
source "$cli_root/lib/dbus.sh"
declare -A module_probe=(
  ["Painel (System.Ping)"]="System Ping"
  ["Software (Software.ListRepos)"]="Software ListRepos"
  ["Backup (Backup.ListConfigs)"]="Backup ListConfigs"
  ["Hardware (Hardware.Inventory)"]="Hardware Inventory"
  ["Kernel (Kernel.ListInstalled)"]="Kernel ListInstalled"
  ["Usuários (Users.ListUsers)"]="Users ListUsers"
  ["Rede (Network.ListInterfaces)"]="Network ListInterfaces"
  ["Firewall (Firewall.Status)"]="Firewall Status"
  ["Serviços (Services.ListServices)"]="Services ListServices"
  ["Data/Hora (DateTime.Status)"]="DateTime Status"
  ["Armazenamento (Storage.ListVolumes)"]="Storage ListVolumes"
  ["Log do Sistema (Logs.ListUnits)"]="Logs ListUnits"
  ["Monitor (Monitor.Metrics)"]="Monitor Metrics"
)
failed=()
for label in "${!module_probe[@]}"; do
  read -r interface method <<<"${module_probe[$label]}"
  if vega::dbus::call_data "$interface" "$method" >/dev/null 2>&1; then
    echo "  OK  - $label"
  else
    echo "  FALHOU - $label ($VEGA_DBUS_LAST_ERROR)"
    failed+=("$label")
  fi
done
if [ "${#failed[@]}" -gt 0 ]; then
  echo "Erro: ${#failed[@]} módulo(s) falharam a checagem read-only." >&2
  exit 1
fi

cat <<'EOF'

Smoke test automatizado do vega-cli concluído.

Checklist manual — exige uma sessão SSH real (sem DISPLAY/WAYLAND_DISPLAY,
sem agente polkit gráfico concorrente), numa VM/container limpo:
  [ ] `vega` abre direto no Painel, sem nenhum erro relacionado a GTK/X11/
      Wayland.
  [ ] Navegar por alguns módulos funciona normalmente pelo teclado.
  [ ] Fechar uma tela com Esc/Não em qualquer módulo volta pro menu
      daquele módulo, não derruba a sessão inteira.
  [ ] Sair do vega (opção "Sair" e via Ctrl+C) restaura o terminal —
      sem tela do dialog "colada", prompt normal de volta.
  [ ] Uma ação privilegiada (ex.: Serviços → habilitar algo, ou Usuários →
      criar conta) pede senha em texto no próprio terminal via pkttyagent
      e a autenticação é aceita.
EOF
