#!/usr/bin/env python3
"""Durable subprocess ownership for gpt-loop (stdlib only)."""
from __future__ import annotations
import argparse, json, os, re, signal, subprocess, sys, time
from pathlib import Path

ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
TERMINAL = {"closed_pass", "hard_blocker", "failure"}
SENSITIVE = {"GITHUB_TOKEN","GH_TOKEN","ANTHROPIC_API_KEY","OPENAI_API_KEY","CLAUDE_CODE_OAUTH_TOKEN","SSH_AUTH_SOCK","GIT_ASKPASS"}


def now_iso():
    import datetime
    return datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")


def atomic_json(path: Path, obj):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + f".tmp-{os.getpid()}")
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2, sort_keys=True); f.write("\n"); f.flush(); os.fsync(f.fileno())
    os.replace(tmp, path)


def load_json(path: Path, default=None):
    try:
        with open(path, encoding="utf-8") as f: return json.load(f)
    except FileNotFoundError:
        return default


def ident(value, label):
    if not ID_RE.fullmatch(value or ""): raise SystemExit(f"{label} has invalid form")
    return value


def edir(state, eid): return Path(state) / "executions" / ident(eid, "execution id")
def jdir(state, eid, name): return edir(state, eid) / "jobs" / ident(name, "job name")


def process_identity(pid):
    if pid <= 0: return None
    if sys.platform.startswith("linux"):
        try: return Path(f"/proc/{pid}/stat").read_text().split()[21]
        except Exception: return None
    if os.name == "posix":
        try: return subprocess.check_output(["ps", "-o", "lstart=", "-p", str(pid)], text=True, stderr=subprocess.DEVNULL).strip() or None
        except Exception: return None
    return None


def alive(pid, identity=None):
    if pid <= 0: return False
    try: os.kill(pid, 0)
    except (ProcessLookupError, OSError): return False
    # kill(pid, 0) also succeeds for zombies. A dead waiter left as a zombie must
    # not make an orphaned child look still owned by a live worker.
    try:
        if sys.platform.startswith("linux"):
            if Path(f"/proc/{pid}/stat").read_text().split()[2] == "Z": return False
        elif os.name == "posix":
            stat = subprocess.check_output(["ps", "-o", "stat=", "-p", str(pid)], text=True, stderr=subprocess.DEVNULL).strip()
            if stat.startswith("Z"): return False
    except Exception:
        pass
    current = process_identity(pid)
    return not (identity and current is not None and current != identity)


def group_members(pgid):
    result = set()
    if os.name != "posix" or pgid <= 0: return result
    try:
        out = subprocess.check_output(["ps", "-A", "-o", "pid=,pgid="], text=True, stderr=subprocess.DEVNULL)
        for line in out.splitlines():
            p = line.split()
            if len(p) >= 2 and int(p[1]) == pgid: result.add(int(p[0]))
    except Exception: pass
    return result


def kill_group(pgid):
    if os.name != "posix": raise RuntimeError("durable process-group termination is POSIX-only")
    try: os.killpg(pgid, signal.SIGTERM)
    except ProcessLookupError: return
    until = time.time() + 3
    while time.time() < until:
        if not group_members(pgid): return
        time.sleep(.1)
    try: os.killpg(pgid, signal.SIGKILL)
    except ProcessLookupError: pass


def scrub_env(extra=None):
    env = {}
    for k, v in os.environ.items():
        u = k.upper()
        if u in SENSITIVE or u.startswith(("AWS_", "AZURE_")) or u.endswith(("_TOKEN", "_SECRET", "_PASSWORD", "_PRIVATE_KEY")): continue
        env[k] = v
    for k, v in (extra or {}).items():
        u=str(k).upper()
        if u in SENSITIVE or u.startswith(("AWS_","AZURE_")) or u.endswith(("_TOKEN","_SECRET","_PASSWORD","_PRIVATE_KEY")): continue
        env[str(k)] = str(v)
    return env


def meta(state, eid):
    value = load_json(edir(state, eid) / "execution.json")
    if not value: raise SystemExit("execution not found")
    return value


def terminal(state, eid): return load_json(edir(state, eid) / "terminal.json")
def finalized(state, eid): return load_json(edir(state, eid) / "finalized.json")


def release_lease(state, m, eid):
    p = Path(state) / "execution-leases" / f"{m['project']}.json"
    cur = load_json(p)
    if cur and cur.get("execution_id") == eid:
        try: p.unlink()
        except FileNotFoundError: pass


def cmd_init(a):
    if os.name != "posix": raise SystemExit("durable continuation currently requires POSIX process-group semantics")
    state = Path(a.state_root); eid = ident(a.execution_id, "execution id"); project = ident(a.project, "project")
    workspace = str(Path(a.workspace).expanduser().resolve()); profiles = json.loads(a.profiles_json or "{}")
    d = edir(state, eid); d.mkdir(parents=True, exist_ok=True)
    desired = {"execution_id":eid,"project":project,"workspace":workspace,"request_sha256":a.request_sha,
               "created_at":now_iso(),"created_epoch":time.time(),"deadline_epoch":time.time()+a.max_seconds,
               "max_slices":a.max_slices,"log_max_bytes":a.log_max_bytes,"command_profiles":profiles}
    old = load_json(d / "execution.json")
    if old:
        for k in ("execution_id","project","workspace","request_sha256","max_slices","log_max_bytes","command_profiles"):
            if old.get(k) != desired.get(k): raise SystemExit(f"execution identity mismatch: {k}")
        desired = old
    else:
        atomic_json(d / "execution.json", desired); atomic_json(d / "checkpoint.json", {"slices":0,"updated_at":now_iso(),"note":"created"})
    # A finalized terminal execution must never reacquire the project lease on a
    # re-run. A terminal that is NOT finalized is different: the previous slice
    # may have crashed after Claude declared terminal but before the control-plane
    # ownership audit. The same execution is allowed to reacquire/retain its lease
    # so a later slice can finish that audit; a foreign execution is not.
    if terminal(state, eid) and finalized(state, eid):
        print(json.dumps(desired)); return
    lease_path = state / "execution-leases" / f"{project}.json"; lease = load_json(lease_path)
    if lease and lease.get("execution_id") != eid:
        old_id = lease.get("execution_id", "")
        if old_id and finalized(state, old_id):
            try: lease_path.unlink()
            except FileNotFoundError: pass
        else: raise SystemExit(f"project already owned by active execution {old_id}")
    atomic_json(lease_path, {"execution_id":eid,"project":project,"workspace":workspace,"request_sha256":a.request_sha,"updated_at":now_iso()})
    print(json.dumps(desired))


def cmd_slice_open(a):
    state = Path(a.state_root); m = meta(state, a.execution_id); t = terminal(state, a.execution_id)
    if t: print(json.dumps({"terminal":t})); return
    cp = load_json(edir(state, a.execution_id) / "checkpoint.json", {}) or {}; slices = int(cp.get("slices", 0))
    if time.time() >= float(m["deadline_epoch"]) or slices >= int(m["max_slices"]):
        # Packet budget is a terminal safety boundary. It must close owned work,
        # not merely change the outward status while children keep mutating.
        for j in jobs(state, a.execution_id):
            pgid=int(j["state"].get("pgid") or 0)
            if j["status"] != "terminal" and pgid:
                try: kill_group(pgid)
                except Exception: pass
        term = {"status":"hard_blocker","message":"execution budget exhausted","at":now_iso()}
        atomic_json(edir(state, a.execution_id) / "terminal.json", term)
        atomic_json(edir(state, a.execution_id) / "finalized.json", {"at":now_iso(),"reason":"execution budget exhausted"})
        release_lease(state, m, a.execution_id)
        print(json.dumps({"terminal":term})); return
    slices += 1; cp.update({"slices":slices,"updated_at":now_iso(),"last_slice_run_id":a.run_id or ""})
    atomic_json(edir(state, a.execution_id) / "checkpoint.json", cp)
    print(json.dumps({"terminal":None,"slices":slices,"deadline_epoch":m["deadline_epoch"]}))


def snapshot(state, eid, name):
    d = jdir(state, eid, name); req = load_json(d / "request.json", {}) or {}; st = load_json(d / "state.json", {}) or {}; rc = load_json(d / "rc.json")
    pid = int(st.get("child_pid") or 0); wid = int(st.get("worker_pid") or 0)
    if rc is not None: status = "terminal"
    elif pid and alive(pid, st.get("child_identity")): status = "running" if wid and alive(wid, st.get("worker_identity")) else "orphaned_running"
    elif pid: status = "orphaned_lost"
    else: status = "starting" if wid and alive(wid, st.get("worker_identity")) else "orphaned_lost"
    return {"name":name,"status":status,"request":req,"state":st,"rc":rc}


def jobs(state, eid):
    base = edir(state, eid) / "jobs"
    return [] if not base.exists() else [snapshot(state, eid, p.name) for p in sorted(base.iterdir()) if p.is_dir()]


def cmd_summary(a):
    state = Path(a.state_root)
    print(json.dumps({"execution":meta(state,a.execution_id),"checkpoint":load_json(edir(state,a.execution_id)/"checkpoint.json",{}),"terminal":terminal(state,a.execution_id),"jobs":jobs(state,a.execution_id)}, ensure_ascii=False))


def cmd_checkpoint(a):
    state = Path(a.state_root); p = edir(state,a.execution_id)/"checkpoint.json"; cp = load_json(p,{}) or {}
    cp.update({"updated_at":now_iso(),"note":a.note or ""}); atomic_json(p,cp); print(json.dumps(cp))


def cmd_complete(a):
    state = Path(a.state_root); m = meta(state,a.execution_id)
    if a.status not in TERMINAL: raise SystemExit("invalid terminal status")
    cur = terminal(state,a.execution_id)
    if cur:
        if cur.get("status") != a.status: raise SystemExit("terminal status already differs")
        print(json.dumps(cur)); return
    unresolved = [j["name"] for j in jobs(state,a.execution_id) if j["status"] != "terminal"]
    if unresolved: raise SystemExit("cannot declare packet terminal while durable jobs are unresolved: " + ",".join(unresolved))
    # Terminal declaration is NOT lease release. Claude is still alive when it
    # calls this command; the dispatcher must audit process ownership first.
    term = {"status":a.status,"message":a.message or "","at":now_iso()}
    atomic_json(edir(state,a.execution_id)/"terminal.json",term); print(json.dumps(term))


def cmd_finalize(a):
    state = Path(a.state_root); m = meta(state,a.execution_id); term = terminal(state,a.execution_id)
    if not term: raise SystemExit("cannot finalize a nonterminal execution")
    marker = finalized(state,a.execution_id)
    if not marker:
        marker = {"at":now_iso(),"reason":a.reason or "ownership audit passed"}
        atomic_json(edir(state,a.execution_id)/"finalized.json",marker)
    release_lease(state,m,a.execution_id)
    print(json.dumps({"terminal":term,"finalized":marker}))


def cmd_abort(a):
    state = Path(a.state_root); m = meta(state,a.execution_id)
    cur = terminal(state,a.execution_id)
    # Once the control plane has finalized a terminal verdict after ownership
    # audit, later retries/cleanup must not rewrite that historical verdict.
    if cur and finalized(state,a.execution_id):
        release_lease(state,m,a.execution_id); print(json.dumps(cur)); return
    for j in jobs(state,a.execution_id):
        pgid = int(j["state"].get("pgid") or 0)
        if j["status"] != "terminal" and pgid:
            try: kill_group(pgid)
            except Exception: pass
    cur = terminal(state,a.execution_id)
    if cur and cur.get("status") in {"hard_blocker","failure"}:
        term = cur
    else:
        # The control plane may invalidate a model-declared closed_pass when a
        # post-slice ownership audit finds escaped work. Safety gating is final.
        term = {"status":"hard_blocker","message":a.message or "execution aborted","at":now_iso()}
        atomic_json(edir(state,a.execution_id)/"terminal.json",term)
    atomic_json(edir(state,a.execution_id)/"finalized.json",{"at":now_iso(),"reason":a.message or "execution aborted"})
    release_lease(state,m,a.execution_id); print(json.dumps(term))


def resolve_profile(m, name):
    p = (m.get("command_profiles") or {}).get(name)
    if not isinstance(p, dict): raise SystemExit(f"durable command profile not allowed: {name}")
    exe = str(p.get("executable") or "")
    if not exe or not Path(exe).is_absolute(): raise SystemExit("command profile executable must be absolute")
    ws = Path(m["workspace"]).resolve(); raw = Path(str(p.get("cwd", "."))); wd = (ws/raw).resolve() if not raw.is_absolute() else raw.resolve()
    try: wd.relative_to(ws)
    except ValueError: raise SystemExit("command profile cwd escapes registered workspace")
    return exe, [str(x) for x in p.get("args_prefix",[])], str(wd), {str(k):str(v) for k,v in p.get("env",{}).items()}


def cmd_job_start(a):
    state = Path(a.state_root); m = meta(state,a.execution_id)
    if terminal(state,a.execution_id): raise SystemExit("execution already terminal")
    name = ident(a.job,"job name"); d = jdir(state,a.execution_id,name); d.mkdir(parents=True,exist_ok=True)
    exe,prefix,cwd,extra = resolve_profile(m,a.profile); req = {"profile":a.profile,"argv":[exe,*prefix,*a.arg],"cwd":cwd,"worktree":cwd,"env":extra}
    old = load_json(d/"request.json")
    if old:
        if old != req: raise SystemExit("job identity already exists with a different command")
        print(json.dumps(snapshot(state,a.execution_id,name))); return
    atomic_json(d/"request.json",req)
    worker = [sys.executable,str(Path(__file__).resolve()),"_worker","--state-root",str(state),"--execution-id",a.execution_id,"--job",name]
    p = subprocess.Popen(worker,cwd=cwd,stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True,env=scrub_env({"GPTLOOP_EXECUTION_ID":a.execution_id}))
    until = time.time()+10
    while time.time() < until:
        st = load_json(d/"state.json",{}) or {}
        if st.get("child_pid") and st.get("child_identity"):
            print(json.dumps(snapshot(state,a.execution_id,name))); return
        if p.poll() is not None: break
        time.sleep(.05)
    try: os.killpg(p.pid,signal.SIGKILL)
    except Exception: pass
    raise SystemExit("durable child failed to publish process identity before start returned")


def worker(a):
    state=Path(a.state_root); m=meta(state,a.execution_id); d=jdir(state,a.execution_id,a.job); req=load_json(d/"request.json")
    if not req: return 111
    out=d/"stdout.log"; err=d/"stderr.log"; env=scrub_env({"GPTLOOP_EXECUTION_ID":a.execution_id,"GPTLOOP_DURABLE_JOB":a.job,**req.get("env",{})})
    with open(out,"ab",buffering=0) as fo, open(err,"ab",buffering=0) as fe:
        child=subprocess.Popen(req["argv"],cwd=req["cwd"],stdin=subprocess.DEVNULL,stdout=fo,stderr=fe,start_new_session=True,env=env)
        st={"worker_pid":os.getpid(),"worker_identity":process_identity(os.getpid()),"child_pid":child.pid,"child_identity":process_identity(child.pid),"pgid":os.getpgid(child.pid),"started_at":now_iso()}; atomic_json(d/"state.json",st)
        maxb=int(m.get("log_max_bytes",8388608)); forced=None
        while child.poll() is None:
            if time.time() >= float(m["deadline_epoch"]): forced="execution deadline exceeded"
            elif out.exists() and out.stat().st_size > maxb: forced="stdout log limit exceeded"
            elif err.exists() and err.stat().st_size > maxb: forced="stderr log limit exceeded"
            if forced: kill_group(st["pgid"]); break
            time.sleep(.25)
        try: rc=child.wait(timeout=5)
        except Exception: rc=125
        # A root command is not terminal while anything in its owned process
        # group survives. This is the durable equivalent of Process.ps1's tree
        # kill: background grandchildren are owned work, never detached work.
        leftovers = group_members(st["pgid"])
        leftovers.discard(child.pid)
        if leftovers:
            forced = forced or "owned descendants remained after root exit"
            kill_group(st["pgid"])
            if rc == 0: rc = 125
        if forced and rc==0: rc=125
        for p in (out,err):
            try:
                size=p.stat().st_size
                if size>maxb:
                    with open(p,"rb") as f: f.seek(max(0,size-maxb)); tail=f.read()
                    tmp=p.with_suffix(p.suffix+".tail")
                    with open(tmp,"wb") as f: f.write(tail); f.flush(); os.fsync(f.fileno())
                    os.replace(tmp,p)
            except Exception: pass
        atomic_json(d/"rc.json",{"exit_code":rc,"finished_at":now_iso(),"forced_reason":forced})
    return 0


def cmd_job_status(a): print(json.dumps(snapshot(Path(a.state_root),a.execution_id,a.job),ensure_ascii=False))

def cmd_job_wait(a):
    state=Path(a.state_root); until=time.time()+a.timeout
    while True:
        s=snapshot(state,a.execution_id,a.job)
        if s["status"] in {"terminal","orphaned_lost"} or time.time()>=until: print(json.dumps(s)); return
        time.sleep(.5)

def cmd_job_tail(a):
    d=jdir(a.state_root,a.execution_id,a.job); result={}
    for name in ("stdout","stderr"):
        p=d/f"{name}.log"
        try:
            with open(p,"rb") as f: size=f.seek(0,2); f.seek(max(0,size-a.bytes)); result[name]=f.read().decode("utf-8","replace")
        except FileNotFoundError: result[name]=""
    print(json.dumps(result,ensure_ascii=False))

def cmd_job_cancel(a):
    state=Path(a.state_root); s=snapshot(state,a.execution_id,a.job); pgid=int(s["state"].get("pgid") or 0)
    if s["status"]!="terminal" and pgid: kill_group(pgid)
    d=jdir(state,a.execution_id,a.job)
    if not load_json(d/"rc.json"): atomic_json(d/"rc.json",{"exit_code":130,"finished_at":now_iso(),"forced_reason":"cancelled"})
    print(json.dumps(snapshot(state,a.execution_id,a.job)))

def cmd_job_adopt(a):
    state=Path(a.state_root); s=snapshot(state,a.execution_id,a.job)
    if s["status"]=="orphaned_running":
        st=s["state"]
        adopter=int(st.get("adopter_pid") or 0)
        if not (adopter and alive(adopter,st.get("adopter_identity"))):
            argv=[sys.executable,str(Path(__file__).resolve()),"_adopter","--state-root",str(state),"--execution-id",a.execution_id,"--job",a.job]
            p=subprocess.Popen(argv,stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True,env=scrub_env({"GPTLOOP_EXECUTION_ID":a.execution_id}))
            st["adopted_at"]=now_iso(); st["adopter_pid"]=p.pid; st["adopter_identity"]=process_identity(p.pid); atomic_json(jdir(state,a.execution_id,a.job)/"state.json",st)
    print(json.dumps(snapshot(state,a.execution_id,a.job)))

def adopter(a):
    state=Path(a.state_root); d=jdir(state,a.execution_id,a.job); m=meta(state,a.execution_id); st=load_json(d/"state.json",{}) or {}
    pid=int(st.get("child_pid") or 0); identity=st.get("child_identity"); pgid=int(st.get("pgid") or 0)
    while pid and alive(pid,identity):
        if time.time() >= float(m["deadline_epoch"]):
            try: kill_group(pgid)
            except Exception: pass
            atomic_json(d/"rc.json",{"exit_code":124,"finished_at":now_iso(),"forced_reason":"execution deadline exceeded after adoption","lost_rc":True}); return 0
        time.sleep(.5)
    if not load_json(d/"rc.json"):
        atomic_json(d/"rc.json",{"exit_code":None,"finished_at":now_iso(),"forced_reason":"original waiter died; terminal rc unavailable","lost_rc":True})
    return 0


def escaped(eid, registered_pgids):
    if os.name!="posix": return None
    found=[]
    if sys.platform.startswith("linux"):
        for p in Path("/proc").iterdir():
            if not p.name.isdigit(): continue
            pid=int(p.name)
            try:
                env=(p/"environ").read_bytes().split(b"\0")
                if f"GPTLOOP_EXECUTION_ID={eid}".encode() not in env: continue
                pgid=os.getpgid(pid)
                if pgid not in registered_pgids: found.append({"pid":pid,"pgid":pgid})
            except Exception: pass
        return found
    try: out=subprocess.check_output(["ps","eww","-A","-o","pid=,pgid=,command="],text=True,stderr=subprocess.DEVNULL)
    except Exception: return None
    token=f"GPTLOOP_EXECUTION_ID={eid}"
    for line in out.splitlines():
        if token not in line: continue
        parts=line.strip().split(None,2)
        if len(parts)>=2:
            pid,pgid=int(parts[0]),int(parts[1])
            if pid!=os.getpid() and pgid not in registered_pgids: found.append({"pid":pid,"pgid":pgid,"command":parts[2] if len(parts)>2 else ""})
    return found


def cmd_owned_pids(a):
    state=Path(a.state_root); result=set()
    for j in jobs(state,a.execution_id):
        st=j["state"]
        for key in ("worker_pid","adopter_pid"):
            pid=int(st.get(key) or 0)
            if pid and alive(pid, st.get(key.replace("_pid","_identity"))): result.add(pid)
        pgid=int(st.get("pgid") or 0)
        if pgid: result.update(group_members(pgid))
    print(json.dumps({"pids":sorted(result)}))


def cmd_audit(a):
    state=Path(a.state_root); js=jobs(state,a.execution_id)
    pgids={int(j["state"].get("pgid") or 0) for j in js if int(j["state"].get("pgid") or 0)>0}
    # The durable waiter/adopter are themselves owned control-plane processes.
    # Their groups differ from the command group, so include them explicitly.
    for j in js:
        for key in ("worker_pid","adopter_pid"):
            pid=int(j["state"].get(key) or 0)
            if pid and alive(pid):
                try: pgids.add(os.getpgid(pid))
                except Exception: pass
    found=escaped(a.execution_id,pgids)
    if found is None: print(json.dumps({"supported":False,"escapes":[]})); return
    if a.kill:
        for x in found:
            try: kill_group(int(x["pgid"]))
            except Exception:
                try: os.kill(int(x["pid"]),signal.SIGKILL)
                except Exception: pass
    print(json.dumps({"supported":True,"escapes":found}))


def parser():
    p=argparse.ArgumentParser(); sp=p.add_subparsers(dest="cmd",required=True)
    def base(name):
        q=sp.add_parser(name); q.add_argument("--state-root",required=True); q.add_argument("--execution-id",required=True); return q
    q=base("init"); q.add_argument("--project",required=True); q.add_argument("--workspace",required=True); q.add_argument("--request-sha",required=True); q.add_argument("--max-seconds",type=int,default=21600); q.add_argument("--max-slices",type=int,default=12); q.add_argument("--log-max-bytes",type=int,default=8388608); q.add_argument("--profiles-json",default="{}"); q.set_defaults(fn=cmd_init)
    q=base("slice-open"); q.add_argument("--run-id",default=""); q.set_defaults(fn=cmd_slice_open)
    q=base("summary"); q.set_defaults(fn=cmd_summary)
    q=base("checkpoint"); q.add_argument("--note",default=""); q.set_defaults(fn=cmd_checkpoint)
    q=base("complete"); q.add_argument("--status",required=True); q.add_argument("--message",default=""); q.set_defaults(fn=cmd_complete)
    q=base("finalize"); q.add_argument("--reason",default=""); q.set_defaults(fn=cmd_finalize)
    q=base("abort"); q.add_argument("--message",default=""); q.set_defaults(fn=cmd_abort)
    q=base("job-start"); q.add_argument("--job",required=True); q.add_argument("--profile",required=True); q.add_argument("--arg",action="append",default=[]); q.set_defaults(fn=cmd_job_start)
    q=base("job-status"); q.add_argument("--job",required=True); q.set_defaults(fn=cmd_job_status)
    q=base("job-wait"); q.add_argument("--job",required=True); q.add_argument("--timeout",type=int,default=300); q.set_defaults(fn=cmd_job_wait)
    q=base("job-tail"); q.add_argument("--job",required=True); q.add_argument("--bytes",type=int,default=8192); q.set_defaults(fn=cmd_job_tail)
    q=base("job-cancel"); q.add_argument("--job",required=True); q.set_defaults(fn=cmd_job_cancel)
    q=base("job-adopt"); q.add_argument("--job",required=True); q.set_defaults(fn=cmd_job_adopt)
    q=base("owned-pids"); q.set_defaults(fn=cmd_owned_pids)
    q=base("audit"); q.add_argument("--kill",action="store_true"); q.set_defaults(fn=cmd_audit)
    q=base("_worker"); q.add_argument("--job",required=True); q.set_defaults(fn=worker)
    q=base("_adopter"); q.add_argument("--job",required=True); q.set_defaults(fn=adopter)
    return p


def main():
    a=parser().parse_args()
    try: return int(a.fn(a) or 0)
    except SystemExit: raise
    except Exception as e: print(json.dumps({"error":str(e)}),file=sys.stderr); return 2

if __name__=="__main__": raise SystemExit(main())
