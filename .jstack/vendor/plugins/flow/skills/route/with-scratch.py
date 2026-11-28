#!/usr/bin/env python3
"""Run one command with an automatically removed scratch directory."""

import argparse
import os
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", nargs=argparse.REMAINDER, help="command and arguments after --")
    args = parser.parse_args()
    command = args.command
    if command[:1] == ["--"]:
        command = command[1:]
    if not command:
        parser.error("a command is required")

    try:
        with tempfile.TemporaryDirectory(prefix="jstack-worker-") as scratch:
            env = {**os.environ, "TMPDIR": scratch, "JSTACK_SCRATCH_DIR": scratch}
            result = subprocess.run(command, env=env)
        return result.returncode if result.returncode >= 0 else 128 - result.returncode
    except KeyboardInterrupt:
        return 130
    except OSError as exc:
        parser.exit(1, f"with-scratch: {exc}\n")


if __name__ == "__main__":
    raise SystemExit(main())
