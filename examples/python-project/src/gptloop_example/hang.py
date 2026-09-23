"""Hangs, and spawns a child that also hangs.

The timeout test asserts that the whole process TREE is terminated, not just the
process gpt-loop started directly.
"""

import subprocess
import sys
import time


def main() -> int:
    # A grandchild that would outlive a naive single-process kill.
    child = subprocess.Popen(
        [sys.executable, "-c", "import time; time.sleep(600)"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    print(f"spawned child pid={child.pid}; now hanging", flush=True)
    time.sleep(600)
    return 0


if __name__ == "__main__":
    sys.exit(main())
