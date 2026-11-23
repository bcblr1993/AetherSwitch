#!/usr/bin/env python3
"""Exercise the real popover + menu-bar settings window and enforce peak footprint."""

import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import time


TABS = ["overview", "cpu", "gpu", "ram", "disk", "network", "battery", "overview"]


def memory_mb(value: str, unit: str) -> float:
    return float(value) * {"K": 1 / 1024, "M": 1, "G": 1024}[unit]


def read_tail(path: pathlib.Path, limit: int = 4000) -> str:
    try:
        text = path.read_text(encoding="utf-8", errors="replace").strip()
    except OSError:
        return ""
    return text[-limit:] if len(text) > limit else text


def format_diagnostics(stdout_path: pathlib.Path, stderr_path: pathlib.Path) -> str:
    parts = []
    out = read_tail(stdout_path)
    err = read_tail(stderr_path)
    if out:
        parts.append(f"stdout:\n{out}")
    if err:
        parts.append(f"stderr:\n{err}")
    return ("\n" + "\n".join(parts)) if parts else ""


def parse_jsonl(path: pathlib.Path) -> list[dict]:
    records = []
    for raw_line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw_line.strip()
        if not line:
            continue
        try:
            records.append(json.loads(line))
        except json.JSONDecodeError:
            break
    return records


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
        temp_dir = pathlib.Path(directory)
        log = temp_dir / "tabs.jsonl"
        stdout_path = temp_dir / "app-stdout.log"
        stderr_path = temp_dir / "app-stderr.log"
        environment = os.environ.copy()
        environment.update(
            AETHERSWITCH_ACCEPTANCE_LOG=str(log),
            AETHERSWITCH_ACCEPTANCE_TABS=",".join(TABS),
            AETHERSWITCH_ACCEPTANCE_TAB_INTERVAL="3",
            AETHERSWITCH_ACCEPTANCE_MENU_BAR_SETTINGS="1",
            AETHERSWITCH_ACCEPTANCE_CLOSE_AFTER_CYCLE="1",
            AETHERSWITCH_RUNTIME_STATUS_DIR=str(temp_dir),
        )
        with stdout_path.open("w", encoding="utf-8") as stdout_file, stderr_path.open(
            "w", encoding="utf-8"
        ) as stderr_file:
            process = subprocess.Popen(
                [str(executable), "--acceptance-cycle"],
                env=environment,
                stdout=stdout_file,
                stderr=stderr_file,
            )
            try:
                deadline = time.monotonic() + 45
                records: list[dict] = []
                while time.monotonic() < deadline:
                    if process.poll() is not None:
                        raise RuntimeError(
                            f"app exited during UI exercise (code {process.returncode})"
                        )
                    if log.exists():
                        records = parse_jsonl(log)
                        if len(records) >= len(TABS):
                            break
                    time.sleep(0.2)
                if len(records) != len(TABS):
                    raise RuntimeError(
                        f"UI exercise timed out after {len(records)}/{len(TABS)} tabs"
                    )
                observed_tabs = [record.get("tab") for record in records]
                if observed_tabs != TABS or not all(
                    record.get("popoverShown") is True
                    and record.get("height", 0) > 0
                    and record.get("updaterRunning") is True
                    and record.get("menuBarSettingsShown") is True
                    for record in records
                ):
                    raise RuntimeError(
                        f"popover, menuBarSettings, or initialized Sparkle failed on records: {records}"
                    )

                # Allow AETHERSWITCH_ACCEPTANCE_CLOSE_AFTER_CYCLE=1 teardown & pressure relief to finish.
                time.sleep(0.6)
                if process.poll() is not None:
                    raise RuntimeError(
                        f"app exited during post-cycle close (code {process.returncode})"
                    )

                vmmap_proc = subprocess.run(
                    ["vmmap", "-summary", str(process.pid)],
                    capture_output=True,
                    text=True,
                    check=True,
                )
                vmmap = vmmap_proc.stdout
                peak_match = re.search(r"Physical footprint \(peak\):\s*([\d.]+)([KMG])", vmmap)
                if not peak_match:
                    raise RuntimeError("vmmap did not report a physical-footprint peak")
                current_match = re.search(r"Physical footprint:\s*([\d.]+)([KMG])", vmmap)
                if not current_match:
                    raise RuntimeError("vmmap did not report current physical footprint")

                peak = memory_mb(*peak_match.groups())
                post_close = memory_mb(*current_match.groups())
                sampled = max(float(record["footprintMB"]) for record in records)
                recorded_peak = max(
                    float(record.get("peakFootprintMB", record["footprintMB"]))
                    for record in records
                )
                effective_peak = max(peak, recorded_peak)

                result = {
                    "limitMB": limit,
                    "sampledMaximumMB": round(sampled, 2),
                    "postCloseFootprintMB": round(post_close, 2),
                    "processPeakMB": round(effective_peak, 2),
                    "tabs": observed_tabs,
                    "menuBarSettingsShown": True,
                    "closedAfterCycle": True,
                    "updaterRunning": True,
                    "passed": max(sampled, post_close, effective_peak) <= limit,
                }
                print(json.dumps(result, ensure_ascii=False))
                return 0 if result["passed"] else 1
            except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
                stdout_file.flush()
                stderr_file.flush()
                details = format_diagnostics(stdout_path, stderr_path)
                print(f"UI memory gate failed: {error}{details}", file=sys.stderr)
                return 1
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=3)


if __name__ == "__main__":
    raise SystemExit(main())
