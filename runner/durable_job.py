#!/usr/bin/env python3
"""Third macOS rollout-gate fixes for durable continuation.

This entrypoint layers narrowly-scoped Darwin process semantics over the
already-reviewed durable_job_impl.py.  The patches are installed into the
implementation's core module before CLI parsing, so the real job-start/_worker
path and tests share the same snapshot/group termination behavior.
"""
from __future__ import annotations
import importlib.util
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

_IMPL_PATH = Path(__file__).with_name("durable_job_impl.py")
_spec = importlib.util.spec_from_file_location("gptloop_durable_job_impl", _IMPL_PATH)
if _spec is None or _spec.loader is None:
    raise RuntimeError(f"cannot load durable implementation: {_IMPL_PATH}")
impl = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(impl)

# Any worker/adopter spawned by the implementation must re-enter this top-level
# entrypoint so these patches remain active in child control processes.
_ENTRY = str(Path(__file__).resolve())
impl.__file__ = _ENTRY
impl.core.__file__ = _ENTRY

_original_group_members = impl.core.group_members
_original_kill_group = impl.core.kill_group


def _darwin_group_members(pgid: int) -> set[int]:
    """Return non-zombie members of a Darwin process group.

    `ps` continues to list an exited-but-unreaped child as Z.  Such a zombie is
    not executable work and cannot be killed again; treating it as live made the
    old kill_group wait three seconds and then hit macOS EPERM on SIGKILL.
    """
    result: set[int] = set()
    if pgid <= 0:
        return result
    try:
        out = subprocess.check_output(
            ["ps", "-A", "-o", "pid=,pgid=,stat="],
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except Exception:
        return result
    for line in out.splitlines():
        fields = line.split()
        if len(fields) < 3:
            continue
        try:
            pid, observed_pgid = int(fields[0]), int(fields[1])
        except ValueError:
            continue
        stat = fields[2]
        if observed_pgid == pgid and not stat.startswith("Z"):
            result.add(pid)
    return result


def group_members(pgid: int) -> set[int]:
    if sys.platform == "darwin":
        return _darwin_group_members(pgid)
    return _original_group_members(pgid)


def kill_group(pgid: int):
    """Terminate owned command work without treating zombie-only groups as live."""
    if sys.platform != "darwin":
        return _original_kill_group(pgid)
    if pgid <= 0 or not group_members(pgid):
        return

    try:
        os.killpg(pgid, signal.SIGTERM)
    except ProcessLookupError:
        return
    except PermissionError:
        # macOS may report EPERM for a group that became zombie-only between the
        # membership snapshot and killpg.  That is complete only if no non-zombie
        # work remains; otherwise preserve fail-closed semantics.
        if not group_members(pgid):
            return
        raise

    until = time.time() + 3.0
    while time.time() < until:
        if not group_members(pgid):
            return
        time.sleep(0.1)

    # Escalate only while executable members still exist.  A zombie-only group
    # must be reaped by child.wait(), not signalled again.
    if not group_members(pgid):
        return
    try:
        os.killpg(pgid, signal.SIGKILL)
    except ProcessLookupError:
        return
    except PermissionError:
        if not group_members(pgid):
            return
        raise

    until = time.time() + 1.0
    while time.time() < until:
        if not group_members(pgid):
            return
        time.sleep(0.05)
    if group_members(pgid):
        raise RuntimeError(f"durable process group {pgid} did not terminate")


def snapshot(state, eid, name):
    """Classify a job without racing macOS ps probes against rc publication."""
    d = impl.core.jdir(state, eid, name)
    req = impl.core.load_json(d / "request.json", {}) or {}
    st = impl.core.load_json(d / "state.json", {}) or {}
    rc = impl.core.load_json(d / "rc.json")
    if rc is not None:
        return {"name": name, "status": "terminal", "request": req, "state": st, "rc": rc}

    pid = int(st.get("child_pid") or 0)
    wid = int(st.get("worker_pid") or 0)
    child_alive = bool(pid and impl.core.alive(pid, st.get("child_identity")))
    worker_alive = bool(wid and impl.core.alive(wid, st.get("worker_identity")))

    # On macOS both alive() calls may shell out to ps.  The waiter can publish
    # rc.json during that window, so refresh terminal truth after slow probes.
    rc = impl.core.load_json(d / "rc.json")
    if rc is not None:
        return {"name": name, "status": "terminal", "request": req, "state": st, "rc": rc}

    if pid and child_alive:
        status = "running" if worker_alive else "orphaned_running"
    elif pid and worker_alive:
        # The command exited but its registered waiter is still reaping/trimming
        # logs/publishing rc.  This is owned in-flight finalization, not an orphan.
        status = "running"
    elif pid:
        # A final cheap reread narrows the only remaining edge: waiter exit after
        # the previous probe but after publishing terminal rc.
        rc = impl.core.load_json(d / "rc.json")
        status = "terminal" if rc is not None else "orphaned_lost"
    else:
        status = "starting" if worker_alive else "orphaned_lost"
    return {"name": name, "status": status, "request": req, "state": st, "rc": rc}


# Patch the exact core globals used by core.jobs(), impl.worker(), cancellation,
# log-limit enforcement, descendant checks, and control-group provenance.
impl.core.group_members = group_members
impl.core.kill_group = kill_group
impl.core.snapshot = snapshot


def main():
    return impl.main()


if __name__ == "__main__":
    raise SystemExit(main())
