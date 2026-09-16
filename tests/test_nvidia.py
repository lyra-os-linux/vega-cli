import json
import unittest
import test_errors


class NvidiaTests(unittest.TestCase):
    setUp = test_errors.ErrorTests.setUp
    run_shell = test_errors.ErrorTests.run_shell
    def replies(self, state='available', recovery=True):
        return {'methods': {
            'Capabilities': {'data': [['nvidia-official-v1', 'nvidia-recovery-v1']]},
            'NvidiaStatus': {'data': [[True, False, False, 'Test GPU', 'enabled', state, 'diagnostic', 0]]},
            'NvidiaRecovery': {'data': [[recovery, 'restic-offline', 'a' * 32, 'ready', 'verified backup required']]},
        }}

    def flow(self, cancelled=False, state='available', recovery=True, failed=False):
        return self.run_shell('''
source "$TEST_REPO/lib/nvidia.sh"
vega::ui::menu() {
  printf '%s\n' "$@" >> menus
  if [ -f selected ]; then printf back; else touch selected; printf install; fi
}
vega::dbus::_transaction_helper() {
  printf '%s\n' "$@" > transaction-args
  printf '%s' ''' + ("'{\"success\":false,\"message\":\"backup failed\"}'" if failed else "'{\"success\":true,\"message\":\"verified\"}'") + '''
}
''' + ('vega::ui::yesno() { return 1; }\n' if cancelled else '') + '''
vega::nvidia::open || true
''', self.replies(state, recovery))

    def test_cancel_never_starts_install(self):
        self.flow(cancelled=True)
        self.assertFalse((self.work / 'transaction-args').exists())

    def test_install_waits_for_finished_and_refreshes_recovery(self):
        output = self.flow()
        self.assertIn('concluída e verificada', output)
        args = (self.work / 'transaction-args').read_text().splitlines()
        self.assertEqual(args[args.index('--timeout') + 1], '7200')
        self.assertEqual(args[-5:], ['Software', 'InstallNvidia', 'TransactionFinished', 'b', 'true'])
        calls = [json.loads(line) for line in self.log.read_text().splitlines()]
        self.assertEqual(sum('NvidiaRecovery' in call for call in calls), 2)

    def test_failure_is_not_success(self):
        output = self.flow(failed=True)
        self.assertIn('não confirmada', output)
        self.assertIn('backup failed', output)
        self.assertNotIn('concluída e verificada', output)

    def test_readonly_diagnostics_do_not_offer_install_on_unqualified_state(self):
        for state, recovery in [('no-gpu', True), ('active', True), ('conflict', True), ('available', False)]:
            self.run_shell('''
source "$TEST_REPO/lib/nvidia.sh"
vega::ui::menu() { printf '%s\n' "$@" > menu; return 1; }
vega::nvidia::open || true
''', self.replies(state, recovery))
            self.assertNotIn('\ninstall\n', (self.work / 'menu').read_text())

    def test_all_languages_explain_offline_recovery(self):
        output = self.run_shell('''
source "$TEST_REPO/lib/nvidia.sh"
for VEGA_NVIDIA_LOCALE in pt-BR en-US es-ES; do
 vega::nvidia::recovery_help restic-offline aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
 printf '\n'
done
''')
        for word in ['Recuperação ext4', 'ext4 recovery', 'Recuperación ext4']:
            self.assertIn(word, output)

