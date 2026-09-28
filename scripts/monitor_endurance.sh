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
cat > "$PROBE_DIR/cputime.c" <<'C'
#include <libproc.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/resource.h>
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    int pid = atoi(argv[1]);
    struct rusage_info_v4 usage = {0};
    if (pid <= 0 || proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&usage) != 0) return 1;
    printf("%llu\n", (unsigned long long)(usage.ri_user_time + usage.ri_system_time));
    return 0;
}
C
xcrun clang -O2 "$PROBE_DIR/cputime.c" -o "$PROBE_DIR/cputime"
python3 - "$DURATION_HOURS" "$INTERVAL_SEC" "$MONITOR_APP_PATH" "$MONITOR_LOG_DIR" "$PROBE_DIR/probe" "$PROBE_DIR/cputime" <<'PY'
import csv, json, math, pathlib, re, subprocess, sys, time
hours, interval = map(float, sys.argv[1:3])
app, directory, probe, cpu_probe = sys.argv[3:]
if hours <= 0 or interval <= 0:
    raise SystemExit('Duration and interval must be positive')
path = pathlib.Path(directory)
count = max(2, math.ceil(hours * 3600 / interval) + 1)
rows = []
expected_pid = None
previous_cpu_ns = None
previous_wall_ns = None
with (path / 'metrics.csv').open('w') as output:
    writer = csv.DictWriter(output, fieldnames=['timestamp', 'pid', 'cpu_pct', 'ps_cpu_pct', 'footprint_mb', 'peak_footprint_mb', 'popover_open', 'responsive', 'status'])
    writer.writeheader()
    for cycle in range(count):
        started = time.monotonic()
        matches = subprocess.run(['pgrep', '-f', app + '/Contents/MacOS/AetherSwitch'], capture_output=True, text=True).stdout.split()
        if len(matches) != 1:
            raise SystemExit('Expected exactly one monitored app process, found ' + str(len(matches)))
        pid = matches[0]
        if expected_pid is None: expected_pid = pid
        if pid != expected_pid: raise SystemExit('Monitored process restarted')
        cpu_ns = int(subprocess.check_output([cpu_probe, pid], text=True).strip())
        wall_ns = time.monotonic_ns()
        cpu = None if previous_cpu_ns is None or wall_ns <= previous_wall_ns or cpu_ns < previous_cpu_ns else 100 * (cpu_ns - previous_cpu_ns) / (wall_ns - previous_wall_ns)
        ps_cpu = float(subprocess.check_output(['ps', '-p', pid, '-o', '%cpu='], text=True).strip())
        previous_cpu_ns, previous_wall_ns = cpu_ns, wall_ns
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
        elif footprint > 50 or peak > 50: status = 'FAIL_MEMORY'
        elif opened is not False: status = 'FAIL_POPOVER_OPEN'
        elif cpu is None: status = 'BASELINE' if cycle == 0 else 'UNVERIFIED'
        elif cpu > 0.1: status = 'FAIL_IDLE_CPU'
        row = dict(timestamp=time.strftime('%Y-%m-%d %H:%M:%S'), pid=pid, cpu_pct=cpu, ps_cpu_pct=ps_cpu, footprint_mb=footprint, peak_footprint_mb=peak, popover_open=opened, responsive=responsive, status=status)
        rows.append(row)
        writer.writerow(row); output.flush()
        print(json.dumps(row), flush=True)
        if cycle + 1 < count: time.sleep(max(0, interval - (time.monotonic() - started)))
measured = [r['cpu_pct'] for r in rows if r['cpu_pct'] is not None]
summary = {'samples': len(rows), 'measured_intervals': len(measured), 'all_passed': bool(measured) and all(r['status'] in ('BASELINE', 'PASS') for r in rows), 'peak_footprint_mb': max((r['peak_footprint_mb'] for r in rows if r['peak_footprint_mb'] is not None), default=None), 'mean_cpu_pct': sum(measured) / len(measured) if measured else None, 'results': rows}
(path / 'report.json').write_text(json.dumps(summary, indent=2))
raise SystemExit(0 if summary['all_passed'] else 1)
PY
