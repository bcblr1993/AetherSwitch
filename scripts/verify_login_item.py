#!/usr/bin/env python3
"""Verify the signed app's panel switch and registration, restoring its setting.

This gate checks persistence in a fresh process; it does not log out or reboot.
"""
import json
import os
import pathlib
import subprocess
import sys
import tempfile


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: verify_login_item.py /absolute/path/to/AetherSwitch")
    executable = pathlib.Path(sys.argv[1]).resolve()
    with tempfile.TemporaryDirectory(prefix="aetherswitch-login-gate-") as directory:
        log = pathlib.Path(directory) / "login-item.json"
        environment = os.environ.copy()
        environment["AETHERSWITCH_ACCEPTANCE_LOG"] = str(log)
        subprocess.run([str(executable), "--acceptance-login-item-cycle"], env=environment, timeout=30, check=True)
        result = json.loads(log.read_text())
        passed = result.get("passed") is True and result.get("restored") == result.get("original")
        result["passed"] = passed
        print(json.dumps(result, ensure_ascii=False))
        return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
