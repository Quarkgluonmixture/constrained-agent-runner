"""Emits far more stdout than a GitHub comment can hold.

Exercises the bounded-comment / full-local-result split: the comment must be
truncated with `truncated: true`, while the complete text stays retrievable
locally via the `read_result` action.
"""

import sys

LINES = 20000


def main() -> int:
    for i in range(LINES):
        print(f"line {i:06d} " + "x" * 60)
    return 0


if __name__ == "__main__":
    sys.exit(main())
