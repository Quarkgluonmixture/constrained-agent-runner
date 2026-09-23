import importlib.util
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
LEGACY_PATH = HERE / 'test_durable_static_impl.py'
_spec = importlib.util.spec_from_file_location('gptloop_durable_static_impl', LEGACY_PATH)
legacy = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(legacy)
# The previous sixth test asserted the now-disproved ps-environment self-probe.
# Keep the five durable control-plane contract tests and replace that assertion.
for stale_name in (
    'test_darwin_provenance_uses_documented_environment_flag',
    'test_mac_hotfix_patches_real_cli_handlers_and_uses_group_provenance',
):
    if hasattr(legacy.StaticDurableControlPlaneTests, stale_name):
        delattr(legacy.StaticDurableControlPlaneTests, stale_name)
StaticDurableControlPlaneTests = legacy.StaticDurableControlPlaneTests
ROOT = Path(__file__).resolve().parents[2]


class MacGate3StaticTests(unittest.TestCase):
    def test_real_core_paths_are_patched_before_cli_main(self):
        src = (ROOT/'runner'/'durable_job.py').read_text(encoding='utf-8')
        self.assertIn('impl.core.snapshot = snapshot', src)
        self.assertIn('impl.core.group_members = group_members', src)
        self.assertIn('impl.core.kill_group = kill_group', src)
        self.assertIn('durable_job_impl.py', src)
        self.assertNotIn('GPTLOOP_AUDIT_PROBE', src)


if __name__ == '__main__':
    unittest.main(verbosity=2)
