#!/usr/bin/env python3
"""macOS-safe entrypoint for the durable job core (stdlib only).

The durable core remains the baseline implementation.  This entrypoint patches
only the POSIX launch/provenance paths that the first two real macOS rollout
gates disproved.  All patched functions are installed into the core module
*before* core.parser() binds CLI handlers, so tests and production share the
same dispatch path.
"""
from __future__ import annotations
import importlib.util, json, os, signal, subprocess, sys, time
from pathlib import Path

_CORE_PATH = Path(__file__).with_name("durable_job_core.py")
_spec = importlib.util.spec_from_file_location("gptloop_durable_job_core", _CORE_PATH)
if _spec is None or _spec.loader is None:
    raise RuntimeError(f"cannot load durable core: {_CORE_PATH}")
core = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(core)
# Core worker/adopter launchers must re-enter this patched entrypoint.
core.__file__ = __file__


def capture_spawn_state(child_pid: int):
    """Capture ownership immediately after Popen, before slower identity probes."""
    # start_new_session=True guarantees that child_pid is the new PGID.  On
    # macOS a short-lived child can disappear while process_identity() launches
    # `ps`; PGID therefore has to be captured first, with child_pid as the safe
    # fallback if getpgid() already observes ESRCH.
    pgid = child_pid
    try:
        pgid = os.getpgid(child_pid)
    except ProcessLookupError:
        pass
    return {
        "worker_pid": os.getpid(),
        "worker_identity": core.process_identity(os.getpid()),
        "child_pid": child_pid,
        "child_identity": core.process_identity(child_pid),
        "pgid": pgid,
        "started_at": core.now_iso(),
    }


def _control_path(state: Path, eid: str) -> Path:
    return core.edir(state, eid) / "control-group.json"


def _registered_pids(state: Path, eid: str) -> set[int]:
    """Return every live PID already owned by the durable registry."""
    result: set[int] = set()
    for job in core.jobs(state, eid):
        st = job.get("state") or {}
        for pid_key, identity_key in (
            ("worker_pid", "worker_identity"),
            ("adopter_pid", "adopter_identity"),
            ("child_pid", "child_identity"),
        ):
            pid = int(st.get(pid_key) or 0)
            if pid and core.alive(pid, st.get(identity_key)):
                result.add(pid)
        pgid = int(st.get("pgid") or 0)
        if pgid:
            result.update(core.group_members(pgid))
    return result


def _capture_control_group(state: Path, eid: str, slice_number: int):
    """Persist the process-group membership that existed before Claude starts."""
    if os.name != "posix":
        return None
    try:
        pgid = os.getpgid(os.getpid())
    except Exception:
        return None
    baseline = {}
    for pid in core.group_members(pgid):
        if pid <= 0:
            continue
        identity = core.process_identity(pid)
        if identity is None or not core.alive(pid, identity):
            continue
        baseline[str(pid)] = identity
    own_identity = core.process_identity(os.getpid())
    if own_identity:
        baseline[str(os.getpid())] = own_identity
    payload = {
        "pgid": pgid,
        "slice": slice_number,
        "captured_at": core.now_iso(),
        "baseline": baseline,
    }
    core.atomic_json(_control_path(state, eid), payload)
    return payload


def _control_group_escapes(state: Path, eid: str):
    """Find live PIDs added to the slice's inherited POSIX process group."""
    record = core.load_json(_control_path(state, eid))
    if not record:
        return None
    pgid = int(record.get("pgid") or 0)
    if pgid <= 0:
        return None
    baseline = record.get("baseline") or {}

    # If a live process now owns the old PGID but its identity differs from the
    # process that owned that PID at slice-open, the PGID has been reused.  Do
    # not kill an unrelated new group; fail the provenance check instead.
    leader_key = str(pgid)
    if leader_key in baseline:
        current_leader = core.process_identity(pgid)
        if current_leader is not None and current_leader != baseline[leader_key]:
            return None

    owned = _registered_pids(state, eid)
    found = []
    for pid in core.group_members(pgid):
        if pid == os.getpid() or pid in owned:
            continue
        identity = core.process_identity(pid)
        if identity is None or not core.alive(pid, identity):
            continue
        old_identity = baseline.get(str(pid))
        if old_identity is not None and old_identity == identity:
            continue
        found.append({
            "pid": pid,
            "pgid": pgid,
            "identity": identity,
            "source": "control_group_delta",
        })
    return found


def _environment_escapes(eid: str, registered_pgids: set[int], registered_pids: set[int]):
    """Supplement control-group provenance for processes that changed groups."""
    if os.name != "posix":
        return None
    found = []
    if sys.platform.startswith("linux"):
        for p in Path("/proc").iterdir():
            if not p.name.isdigit():
                continue
            pid = int(p.name)
            if pid == os.getpid() or pid in registered_pids:
                continue
            try:
                env = (p / "environ").read_bytes().split(b"\0")
                if f"GPTLOOP_EXECUTION_ID={eid}".encode() not in env:
                    continue
                pgid = os.getpgid(pid)
                if pgid not in registered_pgids:
                    found.append({"pid": pid, "pgid": pgid, "source": "environment_marker"})
            except Exception:
                pass
        return found

    # Darwin can hide another process's environment for SIP-protected system
    # binaries.  This scan is therefore supplemental only; an empty result is
    # never used to prove safety.  The control-group delta above is the primary
    # signal and does not depend on environment visibility.
    try:
        out = subprocess.check_output(
            ["ps", "-E", "-ww", "-A", "-o", "pid=,pgid=,command="],
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except Exception:
        return []
    token = f"GPTLOOP_EXECUTION_ID={eid}"
    for line in out.splitlines():
        if token not in line:
            continue
        parts = line.strip().split(None, 2)
        if len(parts) < 2:
            continue
        try:
            pid, pgid = int(parts[0]), int(parts[1])
        except ValueError:
            continue
        if pid == os.getpid() or pid in registered_pids or pgid in registered_pgids:
            continue
        found.append({
            "pid": pid,
            "pgid": pgid,
            "command": parts[2] if len(parts) > 2 else "",
            "source": "environment_marker",
        })
    return found


def _kill_pids(items):
    """Kill exactly observed escape PIDs, identity-checked; never their whole shared group."""
    pending = []
    for item in items:
        pid = int(item.get("pid") or 0)
        identity = item.get("identity")
        if pid <= 0 or pid == os.getpid() or not core.alive(pid, identity):
            continue
        try:
            os.kill(pid, signal.SIGTERM)
            pending.append((pid, identity))
        except (ProcessLookupError, OSError):
            pass
    until = time.time() + 1.0
    while pending and time.time() < until:
        pending = [(pid, ident) for pid, ident in pending if core.alive(pid, ident)]
        if pending:
            time.sleep(0.05)
    for pid, identity in pending:
        if core.alive(pid, identity):
            try:
                os.kill(pid, signal.SIGKILL)
            except (ProcessLookupError, OSError):
                pass


def _audit(state: Path, eid: str, kill: bool):
    jobs = core.jobs(state, eid)
    registered_pgids = {
        int(j["state"].get("pgid") or 0)
        for j in jobs
        if int(j["state"].get("pgid") or 0) > 0
    }
    registered_pids = _registered_pids(state, eid)
    for j in jobs:
        st = j.get("state") or {}
        for key in ("worker_pid", "adopter_pid"):
            pid = int(st.get(key) or 0)
            if pid and core.alive(pid, st.get(key.replace("_pid", "_identity"))):
                try:
                    registered_pgids.add(os.getpgid(pid))
                except Exception:
                    pass

    control = _control_group_escapes(state, eid)
    supplemental = _environment_escapes(eid, registered_pgids, registered_pids)
    supported = control is not None or supplemental is not None
    merged = {}
    for item in (control or []) + (supplemental or []):
        pid = int(item.get("pid") or 0)
        if pid <= 0 or pid in registered_pids or pid == os.getpid():
            continue
        if pid not in merged:
            merged[pid] = item
        elif item.get("source") and item.get("source") not in str(merged[pid].get("source", "")):
            merged[pid]["source"] = f"{merged[pid].get('source','')}+{item['source']}".strip("+")
    escapes = list(merged.values())
    if kill and escapes:
        _kill_pids(escapes)
    return {"supported": bool(supported), "escapes": escapes}


def cmd_job_start(a):
    state = Path(a.state_root)
    m = core.meta(state, a.execution_id)
    if core.terminal(state, a.execution_id):
        raise SystemExit("execution already terminal")
    name = core.ident(a.job, "job name")
    d = core.jdir(state, a.execution_id, name)
    d.mkdir(parents=True, exist_ok=True)
    exe, prefix, cwd, extra = core.resolve_profile(m, a.profile)
    req = {"profile": a.profile, "argv": [exe, *prefix, *a.arg], "cwd": cwd, "worktree": cwd, "env": extra}
    old = core.load_json(d / "request.json")
    if old:
        if old != req:
            raise SystemExit("job identity already exists with a different command")
        print(json.dumps(core.snapshot(state, a.execution_id, name)))
        return
    core.atomic_json(d / "request.json", req)
    worker_argv = [
        sys.executable, str(Path(__file__).resolve()), "_worker",
        "--state-root", str(state), "--execution-id", a.execution_id, "--job", name,
    ]
    p = subprocess.Popen(
        worker_argv, cwd=cwd, stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        start_new_session=True,
        env=core.scrub_env({"GPTLOOP_EXECUTION_ID": a.execution_id}),
    )
    until = time.time() + 10
    while time.time() < until:
        st = core.load_json(d / "state.json", {}) or {}
        # For a fast child, persisted rc is stronger terminal evidence than a
        # live identity that may already be impossible to query on macOS.
        if st.get("child_pid") and (st.get("child_identity") or core.load_json(d / "rc.json") is not None):
            print(json.dumps(core.snapshot(state, a.execution_id, name)))
            return
        if p.poll() is not None:
            break
        time.sleep(0.05)
    try:
        os.killpg(p.pid, signal.SIGKILL)
    except Exception:
        pass
    raise SystemExit("durable child failed to publish process identity before start returned")


def worker(a):
    state = Path(a.state_root)
    m = core.meta(state, a.execution_id)
    d = core.jdir(state, a.execution_id, a.job)
    req = core.load_json(d / "request.json")
    if not req:
        return 111
    out = d / "stdout.log"
    err = d / "stderr.log"
    env = core.scrub_env({"GPTLOOP_EXECUTION_ID": a.execution_id, "GPTLOOP_DURABLE_JOB": a.job, **req.get("env", {})})
    with open(out, "ab", buffering=0) as fo, open(err, "ab", buffering=0) as fe:
        child = subprocess.Popen(
            req["argv"], cwd=req["cwd"], stdin=subprocess.DEVNULL,
            stdout=fo, stderr=fe, start_new_session=True, env=env,
        )
        st = capture_spawn_state(child.pid)
        core.atomic_json(d / "state.json", st)
        maxb = int(m.get("log_max_bytes", 8388608))
        forced = None
        while child.poll() is None:
            if time.time() >= float(m["deadline_epoch"]):
                forced = "execution deadline exceeded"
            elif out.exists() and out.stat().st_size > maxb:
                forced = "stdout log limit exceeded"
            elif err.exists() and err.stat().st_size > maxb:
                forced = "stderr log limit exceeded"
            if forced:
                core.kill_group(st["pgid"])
                break
            time.sleep(0.25)
        try:
            rc = child.wait(timeout=5)
        except Exception:
            rc = 125
        leftovers = core.group_members(st["pgid"])
        leftovers.discard(child.pid)
        if leftovers:
            forced = forced or "owned descendants remained after root exit"
            core.kill_group(st["pgid"])
            if rc == 0:
                rc = 125
        if forced and rc == 0:
            rc = 125
        for p in (out, err):
            try:
                size = p.stat().st_size
                if size > maxb:
                    with open(p, "rb") as f:
                        f.seek(max(0, size - maxb))
                        tail = f.read()
                    tmp = p.with_suffix(p.suffix + ".tail")
                    with open(tmp, "wb") as f:
                        f.write(tail)
                        f.flush()
                        os.fsync(f.fileno())
                    os.replace(tmp, p)
            except Exception:
                pass
        core.atomic_json(d / "rc.json", {"exit_code": rc, "finished_at": core.now_iso(), "forced_reason": forced})
    return 0


def cmd_slice_open(a):
    state = Path(a.state_root)
    m = core.meta(state, a.execution_id)
    t = core.terminal(state, a.execution_id)
    if t:
        print(json.dumps({"terminal": t}))
        return
    cp = core.load_json(core.edir(state, a.execution_id) / "checkpoint.json", {}) or {}
    slices = int(cp.get("slices", 0))
    if time.time() >= float(m["deadline_epoch"]) or slices >= int(m["max_slices"]):
        for j in core.jobs(state, a.execution_id):
            pgid = int(j["state"].get("pgid") or 0)
            if j["status"] != "terminal" and pgid:
                try:
                    core.kill_group(pgid)
                except Exception:
                    pass
        # The previous slice may also have left unregistered same-group work.
        try:
            _audit(state, a.execution_id, True)
        except Exception:
            pass
        term = {"status": "hard_blocker", "message": "execution budget exhausted", "at": core.now_iso()}
        core.atomic_json(core.edir(state, a.execution_id) / "terminal.json", term)
        core.atomic_json(core.edir(state, a.execution_id) / "finalized.json", {"at": core.now_iso(), "reason": "execution budget exhausted"})
        core.release_lease(state, m, a.execution_id)
        print(json.dumps({"terminal": term}))
        return
    slices += 1
    cp.update({"slices": slices, "updated_at": core.now_iso(), "last_slice_run_id": a.run_id or ""})
    core.atomic_json(core.edir(state, a.execution_id) / "checkpoint.json", cp)
    baseline = _capture_control_group(state, a.execution_id, slices)
    if baseline is None:
        raise SystemExit("durable control-group baseline is unavailable on this platform")
    print(json.dumps({"terminal": None, "slices": slices, "deadline_epoch": m["deadline_epoch"]}))


def cmd_audit(a):
    result = _audit(Path(a.state_root), a.execution_id, bool(a.kill))
    print(json.dumps(result))


def cmd_abort(a):
    state = Path(a.state_root)
    m = core.meta(state, a.execution_id)
    cur = core.terminal(state, a.execution_id)
    if cur and core.finalized(state, a.execution_id):
        core.release_lease(state, m, a.execution_id)
        print(json.dumps(cur))
        return
    for j in core.jobs(state, a.execution_id):
        pgid = int(j["state"].get("pgid") or 0)
        if j["status"] != "terminal" and pgid:
            try:
                core.kill_group(pgid)
            except Exception:
                pass
    try:
        _audit(state, a.execution_id, True)
    except Exception:
        pass
    cur = core.terminal(state, a.execution_id)
    if cur and cur.get("status") in {"hard_blocker", "failure"}:
        term = cur
    else:
        term = {"status": "hard_blocker", "message": a.message or "execution aborted", "at": core.now_iso()}
        core.atomic_json(core.edir(state, a.execution_id) / "terminal.json", term)
    core.atomic_json(core.edir(state, a.execution_id) / "finalized.json", {"at": core.now_iso(), "reason": a.message or "execution aborted"})
    core.release_lease(state, m, a.execution_id)
    print(json.dumps(term))


# Critical: patch the exact callables core.parser() binds for CLI dispatch.
core.capture_spawn_state = capture_spawn_state
core.cmd_job_start = cmd_job_start
core.worker = worker
core.cmd_slice_open = cmd_slice_open
core.cmd_audit = cmd_audit
core.cmd_abort = cmd_abort


def main():
    return core.main()


if __name__ == "__main__":
    raise SystemExit(main())
