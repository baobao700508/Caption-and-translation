#!/usr/bin/env python3
"""External deadline and main-thread heartbeat monitor for the native file verification."""
import json
from pathlib import Path
import subprocess
import sys
import time
import wave

root = Path(sys.argv[1]).resolve()
command = sys.argv[2:]
deadline_seconds=180
if '--verify-file' in command:
    try:
        with wave.open(command[command.index('--verify-file')+1]) as audio:
            deadline_seconds=audio.getnframes()/audio.getframerate()+60
    except (OSError,wave.Error,IndexError):
        pass
began = last = time.monotonic()
tick = -1
metrics = []
failure = None
with (root/"native-process.log").open("w") as log:
    process = subprocess.Popen(command, stdout=log, stderr=log)
    next_metric = began
    try:
        while process.poll() is None and not (root/"result.json").exists():
            now = time.monotonic()
            heartbeat = root/"ui-heartbeat.json"
            if heartbeat.exists():
                beat = json.loads(heartbeat.read_text())
                if beat["tick"] != tick:
                    tick, last = beat["tick"], now
            if now >= next_metric:
                usage = subprocess.run(["ps", "-p", str(process.pid), "-o", "pcpu=,rss="],
                                       capture_output=True, text=True).stdout.strip()
                metrics.append({"seconds":now-began,"cpu_percent_rss_kb":usage,"tick":tick})
                next_metric = now+1
            if now-began > deadline_seconds or now-last > (15 if tick < 0 else 3):
                failure = "verification_deadline" if now-began > deadline_seconds else "main_actor_heartbeat_stalled"
                subprocess.run(["/usr/bin/sample",str(process.pid),"2","1","-file",str(root/"blocked.sample.txt")],
                               capture_output=True,timeout=6)
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
    if not (root/"result.json").exists():
        failure = failure or "native_process_exited_without_result"
        (root/"result.json").write_text(json.dumps({"success":False,"error":failure}))
    result = json.loads((root/"result.json").read_text())
    report = {"success":failure is None and result.get("success",False),"failure":failure,
              "elapsed_seconds":time.monotonic()-began,"deadline_seconds":deadline_seconds,"last_tick":tick,"metrics":metrics}
    (root/"ui-watchdog.json").write_text(json.dumps(report,indent=2))
    print(json.dumps({k:v for k,v in report.items() if k != "metrics"}))
