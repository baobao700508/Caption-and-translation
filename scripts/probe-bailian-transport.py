"""Finite, real-time file replay; no microphone, speaker, or credentials in reports."""
import asyncio, base64, json, pathlib, sys, time, wave, socket
import websockets

async def main():
    audio, output = map(pathlib.Path, sys.argv[1:3])
    mode = sys.argv[3] if len(sys.argv) > 3 else 'subtitles'
    config = json.loads((pathlib.Path.home()/'Desktop/LiveCaption配置.json').read_text())
    region = 'cn-beijing' if config.get('bailianRegion') == 'beijing' else 'ap-southeast-1'
    url = f"wss://{config['bailianWorkspaceID']}.{region}.maas.aliyuncs.com/api-ws/v1/realtime?model={config.get('bailianTranslateModel','qwen3.8-livetranslate-flash-realtime')}"
    with wave.open(str(audio)) as f:
        assert (f.getframerate(),f.getnchannels(),f.getsampwidth()) == (16000,1,2)
        pcm = f.readframes(f.getnframes())
    output.mkdir(parents=True,exist_ok=True)
    events=[]; writes=[]; ready=asyncio.Event(); finished=asyncio.Event()
    started=time.monotonic()
    setup={'type':'session.update','session':{'output_modalities':['text','audio'] if mode=='speech' else ['text'],'audio':{'input':{'turn_detection':{'type':'speaker_detection','threshold':0.5}}},'enable_voice_clone':False,'translation':{'language':'zh'}}}
    if '--server-vad' in sys.argv: setup['session']['audio']['input']['turn_detection']={'type':'server_vad'}
    async with websockets.connect(url,additional_headers={'Authorization':'Bearer '+config['bailianAPIKey']},compression='deflate',max_size=4*1024*1024,write_limit=1024*1024,close_timeout=2,**({'family':socket.AF_INET} if '--ipv4' in sys.argv else {})) as ws:
        print(json.dumps({'negotiated_extensions':ws.response.headers.get('Sec-WebSocket-Extensions','none')}),flush=True)
        async def receive():
            async for message in ws:
                root=json.loads(message); kind=root.get('type')
                safe={k:v for k,v in root.items() if k not in ('session','delta')}
                if kind=='response.audio.delta': safe={'type':kind,'bytes':len(base64.b64decode(root['delta']))}
                elif 'delta' in root: safe['delta']=root['delta']
                if kind=='session.updated':
                    session=root.get('session',{}); safe['configuration']={k:session.get(k) for k in ('model','output_modalities','translation','audio')}; ready.set()
                events.append({'t':time.monotonic()-started,**safe})
                with (output/'events.jsonl').open('a') as f: f.write(json.dumps(events[-1],ensure_ascii=False)+'\n')
                if kind=='session.created': await ws.send(json.dumps(setup))
                if kind=='session.finished': finished.set()
        receiver=asyncio.create_task(receive())
        await asyncio.wait_for(ready.wait(),20)
        origin=time.monotonic()
        for offset in range(0,len(pcm),3200):
            deadline=origin+offset/32000
            await asyncio.sleep(max(0,deadline-time.monotonic()))
            before=time.monotonic()
            chunk=pcm[offset:offset+3200]
            await asyncio.wait_for(ws.send(json.dumps({'type':'input_audio_buffer.append','audio':base64.b64encode(chunk).decode()})),5)
            writes.append({'sample_offset':offset//2,'sample_count':len(chunk)//2,'t':before-started,'write_seconds':time.monotonic()-before,'schedule_lag':before-deadline})
            with (output/'writes.json').open('w') as f: json.dump(writes,f)
        with (output/'writes.json').open('w') as f: json.dump(writes,f)
        await ws.send(json.dumps({'type':'session.finish'}))
        try: await asyncio.wait_for(finished.wait(),25)
        except asyncio.TimeoutError: pass
        receiver.cancel()
    result={'mode':mode,'input_seconds':len(pcm)/32000,'writes':writes,'events':events,'finish_acknowledged':finished.is_set()}
    (output/'result.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))
    print(json.dumps({'output':str(output),'input_seconds':result['input_seconds'],'packets':len(writes),'max_write_seconds':max(x['write_seconds'] for x in writes),'max_schedule_lag':max(x['schedule_lag'] for x in writes),'finished':finished.is_set(),'event_types':sorted(set(x['type'] for x in events))},ensure_ascii=False))

if __name__=='__main__': asyncio.run(main())
