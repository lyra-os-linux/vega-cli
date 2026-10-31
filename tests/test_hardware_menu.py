"""Hardware e Kernel never offers NVIDIA, even when an old vegad announces it."""
import unittest
import test_errors


class HardwareMenuTests(unittest.TestCase):
    setUp = test_errors.ErrorTests.setUp
    run_shell = test_errors.ErrorTests.run_shell

    def test_menu_has_no_nvidia_with_old_vegad_capabilities(self):
        output = self.run_shell('''
vega::ui::menu() { printf '%s\\n' "$@" > menu; return 1; }
vega::module_hardware || true
if declare -F vega::nvidia::open >/dev/null; then printf 'nvidia-module-loaded'; fi
''', {'methods': {'Capabilities': {'data': [['nvidia-official-v1', 'nvidia-recovery-v1']]}}})
        menu = (self.work / 'menu').read_text()
        self.assertIn('Hardware e Kernel', menu)
        self.assertIn('\nkernel\n', menu)
        self.assertNotIn('nvidia', menu.lower())
        self.assertNotIn('nvidia-module-loaded', output)

    def test_vega_entrypoint_does_not_load_nvidia(self):
        source = (test_errors.ROOT / 'bin/vega').read_text()
        self.assertNotIn('nvidia', source.lower())
        self.assertFalse((test_errors.ROOT / 'lib/nvidia.sh').exists())


if __name__ == '__main__':
    unittest.main()
