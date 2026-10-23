#!/usr/bin/env python3
"""Bound native caption replay from outside the UI process, including main-actor stalls."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

p = argparse.ArgumentParser(description=__doc__)
p.add_argument("app", type=Path)
p.add_argument("snapshot", type=Path)
p.add_argument("output", type=Path)
p.add_argument("--unique-ids", action="store_true")
p.add_argument("--live-state", action="store_true")
p.add_argument("--select-text", action="store_true")
p.add_argument("--settings", action="store_true")
args = p.parse_args()
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=True)
binary = args.app.resolve() / "Contents/MacOS/LiveCaption"
# Native test bundles must not require Desktop/Documents privacy prompts.
with tempfile.TemporaryDirectory(prefix="LiveCaption-hang-") as temp:
    root = Path(temp)
    snapshot = root / "snapshot.json"
    shutil.copyfile(args.snapshot, snapshot)
    command = [str(binary), "--verify-caption-layout", str(root / "result.json"),
               "--verification-exit", "--caption-hang-snapshot", str(snapshot)]
    if args.unique_ids:
        command.append("--unique-replay-ids")
    if args.live_state:
        command.append("--replay-live-state")
    if args.select_text:
        command.append("--replay-select-text")
    if args.settings:
        command.append("--replay-settings")
    with (out / "process.log").open("w") as log:
        process = subprocess.Popen(command, stdout=log, stderr=log)
        began = time.monotonic()
        last = began
        tick = -1
        reason = None
        metrics = []
        next_metric = began
        try:
            while process.poll() is None:
                now = time.monotonic()
                # A live-state replay can ask AppKit to confirm termination; that is not a UI stall.
                if (root/"result.json").exists():
                    break
                if (root / "heartbeat.json").exists():
                    beat = json.loads((root / "heartbeat.json").read_text())
                    if beat["tick"] != tick:
                        tick, last = beat["tick"], now
                if now >= next_metric:
                    usage = subprocess.run(["ps", "-p", str(process.pid), "-o", "pcpu=,rss="],
                                           capture_output=True, text=True).stdout.strip()
                    metrics.append({"seconds": now-began, "cpu_percent_rss_kb": usage, "tick": tick})
                    next_metric = now+1
                if now-began > 65 or now-last > (8 if tick < 0 else 3):
                    reason = "main_actor_heartbeat_stalled" if tick >= 0 else "no_initial_heartbeat"
                    subprocess.run(["/usr/bin/sample", str(process.pid), "2", "1", "-file",
                                    str(out / "blocked.sample.txt")], capture_output=True, timeout=6)
                    break
                time.sleep(.1)
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=2)
        for name in ["result.json", "heartbeat.json", "replay.png"]:
            if (root/name).exists():
                shutil.copyfile(root/name, out/name)
        result = json.loads((root/"result.json").read_text()) if (root/"result.json").exists() else {}
        report = {"success": reason is None and result.get("success", False), "failure": reason,
                  "last_tick": tick, "exit_code": process.returncode, "metrics": metrics,
                  "native_result": result}
        (out/"watchdog.json").write_text(json.dumps(report, ensure_ascii=False, indent=2))
        print(json.dumps({"success": report["success"], "failure": reason, "last_tick": tick,
                          "report": str(out/"watchdog.json")}, ensure_ascii=False))
        raise SystemExit(0 if report["success"] else 1)
