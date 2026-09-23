"""Prints the fixture version. Exits 0 -> status `success`."""

import platform
import sys

from gptloop_example import __version__


def main() -> int:
    print(f"gptloop_example {__version__}")
    print(f"python {platform.python_version()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
