import json, unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]

class StaticDurableControlPlaneTests(unittest.TestCase):
    def test_result_protocol_has_control_states(self):
        s=json.loads((ROOT/'protocol'/'result.schema.json').read_text(encoding='utf-8'))
        enum=s['properties']['status']['enum']
        self.assertIn('continuation',enum); self.assertIn('hard_blocker',enum); self.assertIn('quota_wait',enum)
    def test_wake_protocol_excludes_nonterminal_states(self):
        s=json.loads((ROOT/'protocol'/'wake.schema.json').read_text(encoding='utf-8'))
        enum=s['properties']['status']['enum']
        self.assertNotIn('continuation',enum); self.assertNotIn('quota_wait',enum); self.assertIn('hard_blocker',enum)
    def test_claude_requires_explicit_terminal_handshake(self):
        t=(ROOT/'runner'/'actions'/'ClaudeAction.ps1').read_text(encoding='utf-8')
        self.assertIn('GptLoopStatus.Continuation',t)
        self.assertIn('Convert-DurableTerminalStatus',t)
        self.assertIn('Audit-DurableEscapes',t)
        self.assertIn('Abort-DurableExecution',t)
        self.assertIn('Finalize-DurableExecution',t)
        self.assertIn('Invoke-DurableClaudeProcess',t)
    def test_workflow_continues_by_uuid_without_new_prompt(self):
        t=(ROOT/'deploy'/'private-fork'/'loop-runner.yml').read_text(encoding='utf-8')
        self.assertIn('workflow_dispatch:',t); self.assertIn('job_id:',t)
        self.assertIn("steps.result.outputs.status == 'continuation'",t)
        self.assertIn('requestsDir',t)
        self.assertIn("status != 'continuation'",t)
    def test_public_repo_ships_no_self_hosted_workflow(self):
        # A public repository must never run workflows on a self-hosted runner:
        # any pull request author could then execute code on the owner's machine.
        wf=ROOT/'.github'/'workflows'
        for f in (sorted(wf.glob('*.yml'))+sorted(wf.glob('*.yaml'))) if wf.is_dir() else []:
            code=[l.split('#',1)[0] for l in f.read_text(encoding='utf-8').splitlines()]
            self.assertFalse([l for l in code if 'self-hosted' in l],f.name)
    def test_durable_is_opt_in(self):
        t=(ROOT/'runner'/'lib'/'Durable.ps1').read_text(encoding='utf-8')
        self.assertIn("'enabled' $false",t)
        self.assertIn('python_executable is required',t)
        self.assertIn('Get-DurableOwnedProcessIds',t)
        self.assertIn("GptLoopStatus['Continuation']",t)
        self.assertIn("GptLoopStatus['HardBlocker']",t)
    def test_mac_hotfix_patches_real_cli_handlers_and_uses_group_provenance(self):
        src=(ROOT/'runner'/'durable_job.py').read_text(encoding='utf-8')
        self.assertIn('core.worker = worker',src)
        self.assertIn('core.cmd_slice_open = cmd_slice_open',src)
        self.assertIn('core.cmd_audit = cmd_audit',src)
        self.assertIn('core.cmd_abort = cmd_abort',src)
        self.assertIn('control-group.json',src)
        self.assertIn('control_group_delta',src)
        self.assertIn('st = capture_spawn_state(child.pid)',src)
        self.assertNotIn('GPTLOOP_AUDIT_PROBE',src)

if __name__=='__main__': unittest.main(verbosity=2)
