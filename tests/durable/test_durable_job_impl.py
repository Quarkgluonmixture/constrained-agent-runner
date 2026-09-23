import json, os, signal, subprocess, sys, tempfile, time, unittest
from pathlib import Path

HELPER = Path(__file__).resolve().parents[2] / 'runner' / 'durable_job.py'
PYTHON = sys.executable

class DurableTests(unittest.TestCase):
    def setUp(self):
        self.td=tempfile.TemporaryDirectory(); self.root=Path(self.td.name); self.ws=self.root/'ws'; self.ws.mkdir()
        self.eid='11111111-1111-4111-8111-111111111111'
        self.profiles={
            'py': {'executable':PYTHON,'cwd':'.'},
            'sh': {'executable':'/bin/sh','cwd':'.'},
        }
        self.invoke('init','--project','demo','--workspace',str(self.ws),'--request-sha','abc','--max-seconds','30','--max-slices','4','--log-max-bytes','4096','--profiles-json',json.dumps(self.profiles))
    def tearDown(self):
        try: self.invoke('abort','--message','test cleanup',check=False)
        finally: self.td.cleanup()
    def invoke(self,cmd,*args,check=True,env=None):
        p=subprocess.run([PYTHON,str(HELPER),cmd,'--state-root',str(self.root),'--execution-id',self.eid,*args],text=True,capture_output=True,env=env)
        if check and p.returncode: self.fail(f'{cmd} rc={p.returncode} stdout={p.stdout} stderr={p.stderr}')
        return p
    def js(self,p): return json.loads(p.stdout)
    def wait_terminal(self,name,timeout=8):
        end=time.time()+timeout
        while time.time()<end:
            s=self.js(self.invoke('job-status','--job',name))
            if s['status']=='terminal': return s
            time.sleep(.1)
        self.fail('job did not terminate')

    def test_fast_child_uses_real_job_start_worker_path(self):
        # This is deliberately end-to-end.  The first Mac rollout failed because
        # a helper-level race test was green while core.worker never called it.
        for i in range(3):
            name=f'fast-{i}'
            s=self.js(self.invoke('job-start','--job',name,'--profile','py','--arg=-c','--arg','print("fast")'))
            self.assertIn(s['status'],('running','terminal'))
            done=self.wait_terminal(name)
            self.assertEqual(done['rc']['exit_code'],0)
            self.assertGreater(int(done['state']['pgid']),0)

    def test_slice_and_immutable_execution(self):
        self.assertEqual(self.js(self.invoke('slice-open'))['slices'],1)
        bad=self.invoke('init','--project','demo','--workspace',str(self.ws),'--request-sha','DIFFERENT','--profiles-json',json.dumps(self.profiles),check=False)
        self.assertNotEqual(bad.returncode,0)

    def test_stable_job_identity_and_rc_logs(self):
        s=self.js(self.invoke('job-start','--job','one','--profile','py','--arg=-c','--arg','print("hello")'))
        self.assertIn(s['status'],('running','terminal'))
        done=self.wait_terminal('one'); self.assertEqual(done['rc']['exit_code'],0)
        tail=self.js(self.invoke('job-tail','--job','one')); self.assertIn('hello',tail['stdout'])
        same=self.invoke('job-start','--job','one','--profile','py','--arg=-c','--arg','print("hello")'); self.assertEqual(same.returncode,0)
        diff=self.invoke('job-start','--job','one','--profile','py','--arg=-c','--arg','print("different")',check=False); self.assertNotEqual(diff.returncode,0)

    def test_terminal_gate_rejects_running_job(self):
        self.invoke('job-start','--job','slow','--profile','py','--arg=-c','--arg','import time; time.sleep(3)')
        p=self.invoke('complete','--status','closed_pass',check=False); self.assertNotEqual(p.returncode,0)
        self.invoke('job-cancel','--job','slow'); self.invoke('complete','--status','failure','--message','cancelled')

    def test_credentials_are_scrubbed(self):
        env=os.environ.copy(); env['GITHUB_TOKEN']='topsecret'
        p=subprocess.run([PYTHON,str(HELPER),'job-start','--state-root',str(self.root),'--execution-id',self.eid,'--job','secret','--profile','py','--arg=-c','--arg','import os; print(os.getenv("GITHUB_TOKEN","NONE"))'],text=True,capture_output=True,env=env)
        self.assertEqual(p.returncode,0,p.stderr); done=self.wait_terminal('secret'); self.assertEqual(done['rc']['exit_code'],0)
        self.assertIn('NONE',self.js(self.invoke('job-tail','--job','secret'))['stdout'])

    def test_worker_death_is_explicit_orphan(self):
        self.invoke('job-start','--job','orphan','--profile','py','--arg=-c','--arg','import time; time.sleep(4)')
        s=self.js(self.invoke('job-status','--job','orphan')); os.kill(int(s['state']['worker_pid']),signal.SIGKILL)
        time.sleep(.2); s=self.js(self.invoke('job-status','--job','orphan')); self.assertEqual(s['status'],'orphaned_running')
        adopted=self.js(self.invoke('job-adopt','--job','orphan')); self.assertEqual(adopted['status'],'orphaned_running')
        self.invoke('job-cancel','--job','orphan')

    def test_running_registered_job_is_not_an_escape(self):
        self.invoke('slice-open')
        self.invoke('job-start','--job','owned','--profile','py','--arg=-c','--arg','import time; time.sleep(3)')
        audit=self.js(self.invoke('audit')); self.assertTrue(audit['supported']); self.assertEqual(audit['escapes'],[])
        self.invoke('job-cancel','--job','owned')

    def test_background_descendant_cannot_fake_success(self):
        self.invoke('job-start','--job','bg','--profile','sh','--arg=-c','--arg','sleep 30 & exit 0')
        done=self.wait_terminal('bg'); self.assertNotEqual(done['rc']['exit_code'],0)
        self.assertIn('descendants',done['rc']['forced_reason'])

    def test_log_limit_bounds_job(self):
        self.invoke('job-start','--job','loud','--profile','py','--arg=-c','--arg','import sys,time; print("x"*20000); sys.stdout.flush(); time.sleep(2)')
        done=self.wait_terminal('loud'); self.assertNotEqual(done['rc']['exit_code'],0)
        self.assertLessEqual((self.root/'executions'/self.eid/'jobs'/'loud'/'stdout.log').stat().st_size,4096)

    def test_terminal_lease_released_only_after_finalize(self):
        lease=self.root/'execution-leases'/'demo.json'
        self.assertTrue(lease.exists())
        self.invoke('complete','--status','closed_pass','--message','done')
        self.assertTrue(lease.exists(), 'terminal declaration must retain lease until ownership audit finalizes')
        other='22222222-2222-4222-8222-222222222222'
        p=subprocess.run([PYTHON,str(HELPER),'init','--state-root',str(self.root),'--execution-id',other,'--project','demo','--workspace',str(self.ws),'--request-sha','def','--profiles-json',json.dumps(self.profiles)],text=True,capture_output=True)
        self.assertNotEqual(p.returncode,0)
        self.invoke('finalize','--reason','audit passed')
        self.assertFalse(lease.exists())
        self.invoke('init','--project','demo','--workspace',str(self.ws),'--request-sha','abc','--max-seconds','30','--max-slices','4','--log-max-bytes','4096','--profiles-json',json.dumps(self.profiles))
        self.assertFalse(lease.exists())

    def test_owned_pids_exposes_registered_process_group(self):
        self.invoke('job-start','--job','ownedpids','--profile','py','--arg=-c','--arg','import time; time.sleep(3)')
        s=self.js(self.invoke('job-status','--job','ownedpids'))
        owned=self.js(self.invoke('owned-pids'))['pids']
        self.assertIn(int(s['state']['worker_pid']), owned)
        self.assertIn(int(s['state']['child_pid']), owned)
        self.invoke('job-cancel','--job','ownedpids')

    @unittest.skipUnless(os.name=='posix','POSIX provenance audit')
    def test_escape_audit_catches_sip_like_process_without_environment_marker(self):
        # Slice-open snapshots the inherited control group.  The escape carries
        # no GPTLOOP_EXECUTION_ID at all, matching macOS SIP's environment blind
        # spot for /bin/sleep.  It still must be found from process ownership.
        self.invoke('slice-open')
        env=os.environ.copy(); env.pop('GPTLOOP_EXECUTION_ID',None)
        p=subprocess.Popen(['/bin/sleep','30'],env=env,start_new_session=False,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        try:
            time.sleep(.2)
            audit=self.js(self.invoke('audit','--kill'))
            self.assertTrue(audit['supported'])
            self.assertTrue(any(x['pid']==p.pid and 'control_group_delta' in x.get('source','') for x in audit['escapes']))
            p.wait(timeout=5)
        finally:
            if p.poll() is None:
                try: os.kill(p.pid,signal.SIGKILL)
                except Exception: pass
                try: p.wait(timeout=2)
                except Exception: pass

if __name__=='__main__': unittest.main(verbosity=2)
