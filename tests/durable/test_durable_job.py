import importlib.util
import json
import os
import signal
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
LEGACY_PATH = HERE / 'test_durable_job_impl.py'
_spec = importlib.util.spec_from_file_location('gptloop_durable_job_tests_impl', LEGACY_PATH)
legacy = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(legacy)
DurableTests = legacy.DurableTests
HELPER = Path(__file__).resolve().parents[2] / 'runner' / 'durable_job.py'


def load_helper():
    spec = importlib.util.spec_from_file_location('durable_job_gate3', HELPER)
    mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
    return mod


class MacGate3Regressions(unittest.TestCase):
    def test_snapshot_does_not_call_live_waiter_orphaned_lost(self):
        mod = load_helper()
        with tempfile.TemporaryDirectory() as td:
            root = Path(td); eid = '11111111-1111-4111-8111-111111111111'; name = 'race'
            d = root / 'executions' / eid / 'jobs' / name; d.mkdir(parents=True)
            (d/'request.json').write_text('{}', encoding='utf-8')
            state = {'child_pid': 999999, 'child_identity': 'gone', 'worker_pid': os.getpid(), 'worker_identity': mod.impl.core.process_identity(os.getpid())}
            (d/'state.json').write_text(json.dumps(state), encoding='utf-8')
            with mock.patch.object(mod.impl.core, 'alive', side_effect=[False, True]):
                snap = mod.impl.core.snapshot(root, eid, name)
            self.assertEqual(snap['status'], 'running')

    def test_snapshot_refreshes_rc_after_slow_probes(self):
        mod = load_helper()
        with tempfile.TemporaryDirectory() as td:
            root = Path(td); eid = '11111111-1111-4111-8111-111111111111'; name = 'race'
            d = root / 'executions' / eid / 'jobs' / name; d.mkdir(parents=True)
            (d/'request.json').write_text('{}', encoding='utf-8')
            (d/'state.json').write_text(json.dumps({'child_pid': 999999, 'worker_pid': 999998}), encoding='utf-8')
            real_load = mod.impl.core.load_json
            calls = {'rc': 0}
            terminal = {'exit_code': 0, 'finished_at': 'now', 'forced_reason': None}
            def load(path, default=None):
                if Path(path).name == 'rc.json':
                    calls['rc'] += 1
                    return None if calls['rc'] == 1 else terminal
                return real_load(path, default)
            with mock.patch.object(mod.impl.core, 'load_json', side_effect=load), \
                 mock.patch.object(mod.impl.core, 'alive', return_value=False):
                snap = mod.snapshot(root, eid, name)
            self.assertEqual(snap['status'], 'terminal')
            self.assertEqual(snap['rc']['exit_code'], 0)

    def test_darwin_group_members_excludes_zombies(self):
        mod = load_helper()
        ps = '71664 71664 Z\n71665 71664 S\n71666 71664 Z+\n71667 99999 S\n'
        with mock.patch.object(mod.subprocess, 'check_output', return_value=ps):
            self.assertEqual(mod._darwin_group_members(71664), {71665})

    def test_darwin_kill_group_stops_after_term_when_only_zombie_remains(self):
        mod = load_helper()
        with mock.patch.object(mod.sys, 'platform', 'darwin'), \
             mock.patch.object(mod, '_darwin_group_members', side_effect=[{71664}, set()]), \
             mock.patch.object(mod.os, 'killpg') as killpg:
            mod.kill_group(71664)
        killpg.assert_called_once_with(71664, signal.SIGTERM)


if __name__ == '__main__':
    unittest.main(verbosity=2)
