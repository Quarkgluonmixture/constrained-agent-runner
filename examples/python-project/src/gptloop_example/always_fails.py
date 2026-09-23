"""Deliberate failure path. Exits 1 -> status `failure`."""

import sys


def main() -> int:
    print("about to fail on purpose")
    print("this is the deliberate failure fixture", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
