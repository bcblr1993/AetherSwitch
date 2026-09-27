#!/bin/bash
set -euo pipefail
# 记录真实资源与主线程回执；缺失数据或失败不能生成通过结论。
DURATION_HOURS="${1:-6}"
INTERVAL_SEC="${2:-30}"
MONITOR_APP_PATH="${MONITOR_APP_PATH:-/Applications/AetherSwitch.app}"
MONITOR_LOG_DIR="${MONITOR_LOG_DIR:-$HOME/aetherswitch_monitor/$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$MONITOR_LOG_DIR"
PROBE_DIR="$(mktemp -d /tmp/aetherswitch-probe.XXXXXX)"
trap 'rm -rf "$PROBE_DIR"' EXIT
cat > "$PROBE_DIR/probe.swift" <<'SWIFT'
import Foundation
DistributedNotificationCenter.default().postNotificationName(NSNotification.Name("com.aethernative.aetherswitch.reportStatus"), object: nil, deliverImmediately: true)
SWIFT
swiftc "$PROBE_DIR/probe.swift" -o "$PROBE_DIR/probe"
python3 - "$DURATION_HOURS" "$INTERVAL_SEC" "$MONITOR_APP_PATH" "$MONITOR_LOG_DIR" "$PROBE_DIR/probe" <<'PY'
import csv, json, math, pathlib, re, subprocess, sys, time
hours, interval = map(float, sys.argv[1:3])
app, directory, probe = sys.argv[3:]
if hours <= 0 or interval <= 0:
    raise SystemExit('Duration and interval must be positive')
path = pathlib.Path(directory)
count = max(1, math.ceil(hours * 3600 / interval))
rows = []
expected_pid = None
with (path / 'metrics.csv').open('w') as output:
    writer = csv.DictWriter(output, fieldnames=['timestamp', 'pid', 'cpu_pct', 'footprint_mb', 'peak_footprint_mb', 'popover_open', 'responsive', 'status'])
    writer.writeheader()
    for cycle in range(count):
        started = time.monotonic()
        matches = subprocess.run(['pgrep', '-f', app + '/Contents/MacOS/AetherSwitch'], capture_output=True, text=True).stdout.split()
        if len(matches) != 1:
            raise SystemExit('Expected exactly one monitored app process, found ' + str(len(matches)))
        pid = matches[0]
        if expected_pid is None: expected_pid = pid
        if pid != expected_pid: raise SystemExit('Monitored process restarted')
        cpu = float(subprocess.check_output(['ps', '-p', pid, '-o', '%cpu='], text=True).strip())
        memory = subprocess.run(['vmmap', '-summary', pid], capture_output=True, text=True)
        (path / 'latest-vmmap.txt').write_text(memory.stdout)
        match = re.search(r'Physical footprint:\s*([\d.]+)([KMG])', memory.stdout)
        footprint = float(match[1]) * {'K': 1/1024, 'M': 1, 'G': 1024}[match[2]] if match else None
        peak_match = re.search(r'Physical footprint \(peak\):\s*([\d.]+)([KMG])', memory.stdout)
        peak = float(peak_match[1]) * {'K': 1/1024, 'M': 1, 'G': 1024}[peak_match[2]] if peak_match else None
        request_time = time.time()
        subprocess.run([probe], check=True)
        receipt = {}
        for _ in range(20):
            time.sleep(0.1)
            try: receipt = json.loads(pathlib.Path('/tmp/AetherSwitch-runtime.json').read_text())
            except (OSError, ValueError): continue
            if receipt.get('timestamp', 0) >= request_time: break
        responsive = receipt.get('timestamp', 0) >= request_time
        opened = receipt.get('popoverOpen') if responsive else None
        status = 'PASS'
        if footprint is None or peak is None or not responsive: status = 'UNVERIFIED'
        elif footprint >= 30 or peak >= 30: status = 'FAIL_MEMORY'
        elif opened is False and cpu > 0.1: status = 'FAIL_IDLE_CPU'
        row = dict(timestamp=time.strftime('%Y-%m-%d %H:%M:%S'), pid=pid, cpu_pct=cpu, footprint_mb=footprint, peak_footprint_mb=peak, popover_open=opened, responsive=responsive, status=status)
        rows.append(row)
        writer.writerow(row); output.flush()
        print(json.dumps(row), flush=True)
        if cycle + 1 < count: time.sleep(max(0, interval - (time.monotonic() - started)))
summary = {'samples': len(rows), 'all_passed': all(r['status'] == 'PASS' for r in rows), 'peak_footprint_mb': max((r['peak_footprint_mb'] for r in rows if r['peak_footprint_mb'] is not None), default=None), 'mean_cpu_pct': sum(r['cpu_pct'] for r in rows) / len(rows), 'results': rows}
(path / 'report.json').write_text(json.dumps(summary, indent=2))
raise SystemExit(0 if summary['all_passed'] else 1)
PY
