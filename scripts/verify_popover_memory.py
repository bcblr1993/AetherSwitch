#!/usr/bin/env python3
"""Exercise the real popover and enforce its physical-footprint peak."""

import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import time


TABS = ["overview", "cpu", "gpu", "ram", "disk", "network", "overview"]


def memory_mb(value: str, unit: str) -> float:
    return float(value) * {"K": 1 / 1024, "M": 1, "G": 1024}[unit]


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: verify_popover_memory.py /absolute/path/to/AetherSwitch", file=sys.stderr)
        return 2
    executable = pathlib.Path(sys.argv[1]).resolve()
    if not executable.is_file():
        print(f"app executable not found: {executable}", file=sys.stderr)
        return 2
    limit = float(os.environ.get("AETHERSWITCH_FOOTPRINT_LIMIT_MB", "50"))
    with tempfile.TemporaryDirectory(prefix="aetherswitch-ui-gate-") as directory:
        log = pathlib.Path(directory) / "tabs.jsonl"
        environment = os.environ.copy()
        environment.update(
            AETHERSWITCH_ACCEPTANCE_LOG=str(log),
            AETHERSWITCH_ACCEPTANCE_TABS=",".join(TABS),
        )
        process = subprocess.Popen(
            [str(executable), "--acceptance-cycle"],
            env=environment,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        try:
            deadline = time.monotonic() + 30
            records = []
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    raise RuntimeError(f"app exited during UI exercise ({process.returncode})")
                if log.exists():
                    records = [json.loads(line) for line in log.read_text().splitlines() if line]
                    if len(records) >= len(TABS):
                        break
                time.sleep(0.2)
            if len(records) != len(TABS):
                raise RuntimeError(f"UI exercise timed out after {len(records)}/{len(TABS)} tabs")
            observed_tabs = [record.get("tab") for record in records]
            if observed_tabs != TABS or not all(
                record.get("popoverShown") is True and record.get("height", 0) > 0
                for record in records
            ):
                raise RuntimeError(f"popover failed to show all tabs: {observed_tabs}")
            vmmap = subprocess.run(
                ["vmmap", "-summary", str(process.pid)],
                capture_output=True,
                text=True,
                check=True,
            ).stdout
            match = re.search(r"Physical footprint \(peak\):\s*([\d.]+)([KMG])", vmmap)
            if not match:
                raise RuntimeError("vmmap did not report a physical-footprint peak")
            peak = memory_mb(*match.groups())
            sampled = max(record["footprintMB"] for record in records)
            result = {
                "limitMB": limit,
                "sampledMaximumMB": round(sampled, 2),
                "processPeakMB": round(peak, 2),
                "tabs": observed_tabs,
                "passed": max(sampled, peak) <= limit,
            }
            print(json.dumps(result, ensure_ascii=False))
            return 0 if result["passed"] else 1
        except (OSError, ValueError, RuntimeError) as error:
            print(f"UI memory gate failed: {error}", file=sys.stderr)
            return 1
        finally:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=3)


if __name__ == "__main__":
    raise SystemExit(main())
