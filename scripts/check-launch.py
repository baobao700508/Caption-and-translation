#!/usr/bin/env python3
from pathlib import Path
import json,subprocess,tempfile,time,sys
root=Path(__file__).resolve().parent.parent
marker=Path(tempfile.gettempdir())/('livecaption-launch-'+str(time.time_ns())+'.json')
subprocess.run(['open','-a',str(root/'dist/LiveCaption.app'),'--args','--verify-launch',str(marker)],check=True)
for _ in range(16):
    if marker.exists():
        d=json.loads(marker.read_text()); ok=d.get('event_loop_responsive') and d.get('visible_panels',0)>0
        print(('PASS' if ok else 'FAIL')+' launch event loop and visible subtitle panel')
        print('Evidence: '+str(marker));sys.exit(0 if ok else 1)
    time.sleep(.5)
print('FAIL launch: no event-loop marker within 8 seconds');sys.exit(1)
