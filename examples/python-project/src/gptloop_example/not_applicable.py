"""Nonzero exit that is NOT a quality failure.

This is the shape of a real curated-eval incident: the benchmark could
not apply to the current corpus, which says nothing about model quality. The
profile maps exit code 3 to `inapplicable` so the brain is not misled.
"""

import sys


def main() -> int:
    print("preflight: fixture is incompatible with the current inputs")
    print("nothing was evaluated; this is not a regression")
    return 3


if __name__ == "__main__":
    sys.exit(main())
