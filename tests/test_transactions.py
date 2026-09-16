"""Real Gio connections on a private broker; fake service never mutates a host."""
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


class TransactionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='cli-transactions-')
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.log = self.work / 'calls.jsonl'
        self.broker = self.process(['dbus-daemon', '--session', '--nofork', '--print-address=1'])
        self.address = self.ready(self.broker)
        self.env = dict(os.environ, DBUS_SYSTEM_BUS_ADDRESS=self.address,
                        PYTHONDONTWRITEBYTECODE='1')

    def process(self, args, env=None):
        process = subprocess.Popen(args, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        def cleanup():
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
            process.stdout.close()
            process.stderr.close()
        self.addCleanup(cleanup)
        return process

    def ready(self, process):
        self.assertTrue(select.select([process.stdout], [], [], 5)[0], 'Startup timed out')
        line = process.stdout.readline().strip()
        if not line:
            raise AssertionError('Startup failed: ' + process.stderr.read())
        return line

    def service(self, mode):
        service = self.process([sys.executable, str(ROOT / 'tests/transaction-service.py'), mode, str(self.log)], self.env)
        self.ready(service)

    def helper(self, timeout=.35, method='Start', args=(), call_timeout=1,
               interface='Software', finished='TransactionFinished'):
        return self.process([sys.executable, str(ROOT / 'lib/transaction.py'),
                             '--timeout', str(timeout), '--call-timeout', str(call_timeout),
                             '--', interface, method, finished, *args], self.env)

    def result(self, helper):
        out, err = helper.communicate(timeout=5)
        self.assertEqual(err, '', err)
        value = json.loads(out)
        self.assertEqual(helper.returncode, 0 if value['success'] else 1)
        return value

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def test_completion_before_method_reply(self):
        self.service('immediate')
        value = self.result(self.helper())
        self.assertTrue(value['success'])
        self.assertEqual(value['message'], 'finished before reply')
        self.assertEqual(len(self.calls()), 1)

    def test_nvidia_confirmation_uses_a_boolean_on_the_wire(self):
        self.service('immediate')
        value = self.result(self.helper(method='InstallNvidia', args=('b', 'true')))
        self.assertTrue(value['success'])
        self.assertEqual(self.calls()[0]['args'], [True])

    def test_nvidia_rejects_ambiguous_confirmation_before_dbus(self):
        self.service('immediate')
        for args in [('s', 'true'), ('b', 'yes'), ('b', '1'), ('b', 'true', 'extra')]:
            self.assertFalse(self.result(self.helper(method='InstallNvidia', args=args))['success'])
        self.assertFalse(self.calls())

    def test_backup_and_restore_use_their_own_finished_signals(self):
        self.service('immediate')
        for method, finished, args in [('RunBackupNow', 'BackupFinished', ('s', 'config')),
                                       ('RestoreSnapshot', 'RestoreFinished', ('sss', 'snapshot', '/a path', 'separate-folder'))]:
            with self.subTest(method=method):
                value = self.result(self.helper(interface='Backup', method=method, finished=finished, args=args))
                self.assertTrue(value['success'])
        self.assertEqual(len(self.calls()), 2)

    def test_interleaved_early_signals_are_correlated(self):
        self.service('interleaved')
        value = self.result(self.helper())
        self.assertTrue(value['success'])
        self.assertEqual(value['transaction_id'], 7)

    def test_unrelated_signal_after_reply_does_not_end_wait(self):
        self.service('delayed')
        self.assertEqual(self.result(self.helper())['message'], 'own completion')

    def test_key_pending_uses_same_transaction_and_preserves_arguments(self):
        self.service('key')
        value = self.result(self.helper(method='AddRepo', args=('ss', 'repo', '-url with spaces')))
        self.assertFalse(value['success'])
        self.assertEqual(value['key_pending'], ['repo', 'key-id', 'fingerprint', 'signer'])
        self.assertEqual(self.calls()[0]['args'], ['repo', '-url with spaces'])

    def test_owner_release_while_connection_lives(self):
        self.service('release')
        value = self.result(self.helper())
        self.assertFalse(value['success'])
        self.assertIn('nome D-Bus', value['message'])

    def test_replacement_reusing_id_is_not_success_or_retry(self):
        self.service('replace')
        value = self.result(self.helper())
        self.assertFalse(value['success'])
        self.assertNotIn('replacement success', value['message'])
        self.assertEqual(len(self.calls()), 1)

    def test_daemon_disconnect(self):
        self.service('disconnect')
        self.assertFalse(self.result(self.helper())['success'])

    def test_spoofed_sender_and_wrong_path_are_ignored(self):
        self.service('forged')
        value = self.result(self.helper())
        self.assertFalse(value['success'])
        self.assertIn('Tempo esgotado', value['message'])

    def test_deadline_does_not_reset_with_unrelated_signals(self):
        self.service('flood')
        start = time.monotonic()
        value = self.result(self.helper(timeout=.2))
        self.assertIn('Tempo esgotado', value['message'])
        self.assertLess(time.monotonic() - start, 1.5)

    def test_call_timeout(self):
        self.service('silent-call')
        start = time.monotonic()
        self.assertFalse(self.result(self.helper(timeout=2, call_timeout=.1))['success'])
        self.assertLess(time.monotonic() - start, 1.5)

    def wait_called(self):
        for _ in range(200):
            if self.log.exists():
                return
            time.sleep(.005)
        self.fail('Method was not called')

    def test_bus_disconnect(self):
        self.service('flood')
        helper = self.helper(timeout=2)
        self.wait_called()
        self.broker.terminate()
        self.assertFalse(self.result(helper)['success'])

    def test_interrupt_exits_without_cancel_or_retry(self):
        self.service('flood')
        helper = self.helper(timeout=2)
        self.wait_called()
        helper.send_signal(signal.SIGTERM)
        value = self.result(helper)
        self.assertIn('interrompida', value['message'])
        self.assertEqual(len(self.calls()), 1)

    def test_backend_error(self):
        self.service('error')
        value = self.result(self.helper())
        self.assertIn('NotAuthorized', value['message'])
        self.assertFalse(value['success'])

    def test_failed_transaction(self):
        self.service('failure')
        self.assertEqual(self.result(self.helper())['message'], 'operation failed')

    def test_invalid_reply(self):
        self.service('invalid-reply')
        self.assertIn('ID de transação inválido', self.result(self.helper())['message'])

    def test_no_daemon(self):
        self.assertFalse(self.result(self.helper())['success'])
        self.assertFalse(self.calls())

    def shell(self, body):
        env = dict(self.env, TEST_REPO=str(ROOT), TMPDIR=str(self.work))
        script = '''set -euo pipefail
source "$TEST_REPO/lib/dbus.sh"
source "$TEST_REPO/lib/software.sh"
''' + body
        result = subprocess.run(['bash', '-c', script], env=env, text=True,
                                capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(list(self.work.glob('tmp.*')), [], 'Shell temporary files leaked')
        return result.stdout

    def test_shell_output_variable_uses_real_helper(self):
        self.service('interleaved')
        out = self.shell('''
VEGA_DBUS_LAST_ERROR=stale
vega::dbus::run_transaction_into result Software Start TransactionFinished
[[ -z $VEGA_DBUS_LAST_ERROR && -z $VEGA_DBUS_TRANSACTION_KEY_PENDING ]]
printf '%s' "$result"
''')
        self.assertEqual(out, 'finished before reply')

    def test_shell_authorization_error_reaches_caller(self):
        self.service('error')
        out = self.shell('''
result=stale
if vega::dbus::run_transaction_into result Software Start TransactionFinished; then exit 1; fi
[[ -z $result && -z $VEGA_DBUS_TRANSACTION_KEY_PENDING ]]
printf '%s' "$VEGA_DBUS_LAST_ERROR"
''')
        self.assertIn('não autorizada', out)

    def test_add_repo_dialog_uses_only_own_key(self):
        self.service('key')
        out = self.shell('''
vega::ui::infobox() { :; }
vega::ui::inputbox() { printf repo; }
vega::ui::msgbox() { printf 'unexpected dialog: %s' "$1"; }
vega::software::_confirmar_confiar_chave() { printf '%s:%s:%s:%s' "$@"; }
vega::software::_adicionar_repositorio
''')
        self.assertEqual(out, 'repo:key-id:fingerprint:signer')

    def test_rejected_subscription_prevents_method_call(self):
        config = self.work / 'broker.conf'
        config.write_text('''<busconfig><type>session</type><listen>unix:tmpdir=/tmp</listen>
<policy context="default"><allow own="*"/><allow send_destination="*"/>
<allow receive_sender="*"/><deny send_destination="org.freedesktop.DBus"
send_interface="org.freedesktop.DBus" send_member="AddMatch"/></policy></busconfig>''')
        broker = self.process(['dbus-daemon', '--nofork', '--print-address=1', '--config-file=' + str(config)])
        self.env['DBUS_SYSTEM_BUS_ADDRESS'] = self.ready(broker)
        self.service('immediate')
        value = self.result(self.helper())
        self.assertFalse(value['success'])
        self.assertIn('AccessDenied', value['message'])
        self.assertFalse(self.calls())


if __name__ == '__main__':
    unittest.main()
