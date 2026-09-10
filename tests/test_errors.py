"""Run the real Bash library/modules with simulated busctl and dialog functions."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ErrorTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='vega-cli-errors-')
        self.addCleanup(self.tmp.cleanup)
        self.work = Path(self.tmp.name)
        self.config = self.work / 'config.json'
        self.log = self.work / 'calls.jsonl'
        shutil.copy2(ROOT / 'tests/busctl-fixture.py', self.work / 'busctl')
        (self.work / 'busctl').chmod(0o755)
        (self.work / 'temps').mkdir()

    def run_shell(self, body, config=None):
        self.config.write_text(json.dumps(config or {}))
        env = dict(os.environ, PATH=str(self.work) + ':' + os.environ['PATH'],
                   FIXTURE_CONFIG=str(self.config), FIXTURE_LOG=str(self.log),
                   TMPDIR=str(self.work / 'temps'), TEST_REPO=str(ROOT))
        script = '''set -euo pipefail
source "$TEST_REPO/lib/dbus.sh"
vega::dbus::locale() { printf 'pt-BR'; }
for module in backup datetime hardware logs monitor network painel services software storage users; do
  source "$TEST_REPO/lib/$module.sh"
done
vega::ui::infobox() { :; }
vega::ui::msgbox() { printf '%s\\n' "$1"; }
vega::ui::yesno() { return 0; }
vega::ui::inputbox() { printf 'fixture input'; }
vega::ui::menu() { return 1; }
''' + body
        result = subprocess.run(['bash', '-c', script], env=env, cwd=self.work,
                                text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(list((self.work / 'temps').iterdir()), [], 'Temporary files leaked')
        return result.stdout

    def test_errors_and_status_reach_all_three_output_apis(self):
        for api, args in [('call_into', 'System Ping'), ('call_data_into', 'System Ping'),
                          ('run_transaction_into', 'Software InstallNative TransactionFinished s fixture')]:
            for raw, expected in [
                ('Call failed: org.freedesktop.PolicyKit1.Error.NotAuthorized', 'não autorizada'),
                ('Call failed: service is not activatable', 'não está disponível'),
                ('Call failed: Message did not receive a reply', 'não respondeu'),
                ('Call failed: backend detail', 'backend detail'),
                ('', 'sem detalhes'),
            ]:
                with self.subTest(api=api, raw=raw):
                    out = self.run_shell(f'''
result=stale
VEGA_DBUS_LAST_ERROR=old
rc=0
vega::dbus::{api} result {args} || rc=$?
[[ $rc == 9 && -z $result ]]
printf '%s' "$VEGA_DBUS_LAST_ERROR"
''', {'default': {'error': raw}})
                    self.assertIn(expected, out)
                    self.assertNotIn('old', out)

    def test_success_clears_stale_error_and_preserves_data(self):
        out = self.run_shell('''
for target in result raw out err_file rc data; do
  VEGA_DBUS_LAST_ERROR=old
  vega::dbus::call_data_into "$target" System Ping
  [[ -z $VEGA_DBUS_LAST_ERROR ]]
  printf '%s\\n' "${!target}"
done
VEGA_DBUS_LAST_ERROR=old
vega::dbus::call System Ping >/dev/null
[[ -z $VEGA_DBUS_LAST_ERROR ]]
''', {'default': {'data': ['spaces "quotes" $(touch nope)', 42]}})
        self.assertEqual(len(out.splitlines()), 6)
        for line in out.splitlines():
            self.assertEqual(json.loads(line), ['spaces "quotes" $(touch nope)', 42])
        self.assertFalse((self.work / 'nope').exists())

    def test_invalid_json_and_missing_data_report_errors(self):
        for raw in ['', 'invalid', '{}', '{"data":null}', '{"data":"bad"}']:
            with self.subTest(raw=raw):
                out = self.run_shell('''
result=stale
if vega::dbus::call_data_into result System Ping; then exit 1; fi
[[ -z $result ]]
printf '%s' "$VEGA_DBUS_LAST_ERROR"
''', {'default': {'raw': raw}})
                self.assertIn('JSON inválida', out)

    def test_failure_then_success_and_invalid_output_names(self):
        self.run_shell('''
if vega::dbus::call_data_into result System Ping; then exit 1; fi
[[ $VEGA_DBUS_LAST_ERROR == 'first failure' ]]
vega::dbus::call_data_into result System Version
[[ -z $VEGA_DBUS_LAST_ERROR && $result == '[7]' ]]
for target in 'array[0]' '__vega_capture_file' VEGA_DBUS_LAST_ERROR '$(touch nope)'; do
  if vega::dbus::call_into "$target" System Version; then exit 1; fi
  [[ -n $VEGA_DBUS_LAST_ERROR ]]
done
''', {'methods': {'Ping': {'error': 'Call failed: first failure'}}})
        self.assertEqual(len(self.log.read_text().splitlines()), 2)
        self.assertFalse((self.work / 'nope').exists())

    def test_transaction_message_failure_success_and_timeout(self):
        for signal, expected in [([7, False, 'snapshot failed'], 'snapshot failed'),
                                 ([7, False, ''], 'sem detalhes'),
                                 (None, 'Tempo esgotado'),
                                 ([8, True, 'other'], 'não corresponde')]:
            with self.subTest(signal=signal):
                out = self.run_shell('''
result=old
if vega::dbus::run_transaction_into result Backup RunBackupNow BackupFinished s id; then exit 1; fi
[[ -z $result ]]
printf '%s' "$VEGA_DBUS_LAST_ERROR"
''', {'signal': signal})
                self.assertIn(expected, out)
        self.assertEqual(self.run_shell('''
VEGA_DBUS_LAST_ERROR=old
vega::dbus::run_transaction_into result Backup RunBackupNow BackupFinished s id
[[ -z $VEGA_DBUS_LAST_ERROR ]]
printf '%s' "$result"
'''), 'completed')

    def test_module_dialogs_and_dashboard_show_backend_detail(self):
        commands = ['vega::module_users', 'vega::module_storage', 'vega::module_logs',
                    'vega::module_datetime', 'vega::monitor::_processos',
                    'vega::network::_interfaces', 'vega::network::_proxy',
                    'vega::network::_firewall', 'vega::services::_listar ListServices',
                    'vega::hardware::_inventario', 'vega::hardware::_kernel_instalados',
                    'vega::hardware::_kernel_disponiveis', 'vega::hardware::_kernel_boot',
                    'vega::software::_listar_instalados', 'vega::software::_listar_atualizacoes',
                    'vega::software::_repositorios', 'vega::software::_adicionar_repositorio',
                    'vega::backup::_configuracoes', 'vega::backup::_pontos_restauracao',
                    'vega::backup::_ver_caminhos_snapshot id snapshot',
                    'vega::backup::_ver_snapshots id', 'vega::backup::_criar_snapshot',
                    'vega::backup::_diff_pacotes 1 || [[ $? == 1 ]]', 'vega::module_painel',
                    'vega::painel::_linha_backup',
                    'vega::software::_run_and_report waiting Software InstallNative s fixture']
        for command in commands:
            with self.subTest(command=command):
                out = self.run_shell('VEGA_DBUS_LAST_ERROR=stale\n' + command,
                                     {'default': {'error': 'Call failed: audit failure detail'}})
                self.assertIn('audit failure detail', out)
                self.assertNotIn('stale', out)

    def test_datetime_list_failure_aborts_before_apply(self):
        for method in ['ListTimezones', 'ListLocales', 'ListKeymaps']:
            with self.subTest(method=method):
                out = self.run_shell('vega::module_datetime', {'methods': {
                    'Status': {'data': [['UTC', True, 'en_US.UTF-8', 'us']]},
                    method: {'error': 'Call failed: list unavailable'}}, 'default': {'data': [['UTC']]}})
                self.assertIn('list unavailable', out)
        self.assertNotIn('"Apply"', self.log.read_text())

    def test_batch_preserves_failure_after_later_success(self):
        out = self.run_shell('''
vega::ui::checklist() { printf 'bad\\ngood'; }
vega::software::_repositorios
''', {'methods': {'ListRepos': {'data': [[['bad', False], ['good', False]]]}}})
        self.assertIn('1 de 2', out)
        self.assertIn('first repo failed', out)

    def test_timeout_locale_and_arguments_survive_capture(self):
        self.run_shell('''
VEGA_DBUS_CALL_TIMEOUT=60 vega::dbus::call_data_into result Software SearchNative s 'a b;$(touch nope)'
vega::dbus::call_into result Hardware Inventory
vega::dbus::call_into result Backup CreateConfig '(sassss)' id 1 '/a path' '/backup' uuid manual
''')
        calls = [json.loads(line) for line in self.log.read_text().splitlines()]
        self.assertIn('--timeout=60', calls[0])
        self.assertEqual(calls[0][-1], 'a b;$(touch nope)')
        self.assertEqual(calls[1][-4:], ['InventoryLocalized', '--', 's', 'pt-BR'])
        self.assertEqual(calls[2][-7:], ['(sassss)', 'id', '1', '/a path', '/backup', 'uuid', 'manual'])
        self.assertFalse((self.work / 'nope').exists())

    def test_capture_setup_failure_is_reported(self):
        out = self.run_shell('''
mktemp() { return 1; }
result=old
if vega::dbus::call_data_into result System Ping; then exit 1; fi
[[ -z $result ]]
printf '%s' "$VEGA_DBUS_LAST_ERROR"
''')
        self.assertIn('preparar', out)
        self.assertFalse(self.log.exists())

    def test_no_stateful_dbus_calls_in_substitutions_or_pipelines(self):
        pattern = re.compile(r'(?:\$|<)\([^\n]*vega::dbus::(?:call(?:_data)?|run_transaction)\b')
        for path in (ROOT / 'lib').glob('*.sh'):
            code = '\n'.join(line for line in path.read_text().splitlines() if not line.lstrip().startswith('#'))
            self.assertIsNone(pattern.search(code), str(path))


if __name__ == '__main__':
    unittest.main()
