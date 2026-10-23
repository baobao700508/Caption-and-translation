"""Finite authorized file replay with Darwin TCP counters. Never logs credentials/audio payloads."""
import argparse
import asyncio
import base64
import json
import os
from pathlib import Path
import socket
import struct
import time
import wave

import websockets


def tcp_info(sock):
    raw = sock.getsockopt(socket.IPPROTO_TCP, socket.TCP_CONNECTION_INFO, 112)
    vals = struct.unpack("=4B13I7Q", raw[:112])
    names = ["state", "snd_wscale", "rcv_wscale", "padding", "options", "flags",
             "rto_ms", "mss", "ssthresh", "cwnd", "peer_window", "send_buffer",
             "receive_window", "rtt_ms", "srtt_ms", "rtt_variance", "tfo",
             "tx_packets", "tx_bytes", "retransmit_bytes", "rx_packets", "rx_bytes",
             "out_of_order_bytes", "retransmit_packets"]
    return dict(zip(names, vals))


async def main():
    os.umask(0o077)
    p = argparse.ArgumentParser()
    p.add_argument("audio", type=Path)
    p.add_argument("output", type=Path)
    p.add_argument("--seconds", type=float, default=30)
    p.add_argument("--address")
    p.add_argument("--mss", type=int, default=0)
    p.add_argument("--pace", type=float, default=1)
    args = p.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    cfg = json.loads((Path.home()/"Desktop/LiveCaption配置.json").read_text())
    assert cfg.get("bailianRegion") == "beijing"
    host = cfg["bailianWorkspaceID"] + ".cn-beijing.maas.aliyuncs.com"
    url = f"wss://{host}/api-ws/v1/realtime?model={cfg['bailianTranslateModel']}"
    with wave.open(str(args.audio)) as f:
        assert (f.getframerate(), f.getnchannels(), f.getsampwidth()) == (16000, 1, 2)
        pcm = f.readframes(int(args.seconds*16000))
    begin = time.monotonic()
    origin = None
    events, samples, writes = [], [], []
    ready, finished = asyncio.Event(), asyncio.Event()
    failure = None
    sent = 0
    family = socket.AF_INET6 if args.address and ":" in args.address else socket.AF_INET
    sock = socket.socket(family, socket.SOCK_STREAM)
    sock.setblocking(False)
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    ws = None
    receiver = monitor = None
    try:
        await asyncio.wait_for(asyncio.get_running_loop().sock_connect(sock, (args.address or host, 443)), 15)
        # Darwin permits reducing the negotiated MSS, not raising the pre-connect default.
        if args.mss:
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_MAXSEG, args.mss)
        peer = sock.getpeername()[0]
        ws = await websockets.connect(url, sock=sock, additional_headers={"Authorization": "Bearer "+cfg["bailianAPIKey"]},
                                      proxy=None, compression=None, max_size=4*1024*1024,
                                      write_limit=32768, close_timeout=1, open_timeout=15)
        observed = ws.transport.get_extra_info("socket")

        async def observe():
            while True:
                samples.append({"t": time.monotonic()-begin, **tcp_info(observed),
                                "asyncio_buffer": ws.transport.get_write_buffer_size()})
                await asyncio.sleep(0.2)

        async def receive():
            async for message in ws:
                root = json.loads(message)
                kind = root.get("type")
                entry = {"t": time.monotonic()-begin, "type": kind}
                for key in ("item_id", "audio_start_ms", "audio_end_ms"):
                    if key in root: entry[key] = root[key]
                if kind in ("conversation.item.input_audio_transcription.delta", "response.text.delta"):
                    entry["text"] = root.get("delta", "")
                if kind == "error": entry["code"] = root.get("error", {}).get("code")
                events.append(entry)
                if kind == "session.created":
                    await ws.send(json.dumps({"type": "session.update", "session": {
                        "output_modalities": ["text"], "audio": {"input": {"turn_detection": {
                            "type": "speaker_detection", "threshold": 0.5}}},
                        "enable_voice_clone": False, "voice": "Tina", "translation": {"language": "zh"}}}))
                if kind == "session.updated": ready.set()
                if kind == "session.finished": finished.set()

        monitor = asyncio.create_task(observe())
        receiver = asyncio.create_task(receive())
        await asyncio.wait_for(ready.wait(), 15)
        origin = time.monotonic()
        for offset in range(0, len(pcm), 3200):
            deadline = origin+(offset+3200)/32000/args.pace
            await asyncio.sleep(max(0, deadline-time.monotonic()))
            chunk = pcm[offset:offset+3200]
            before = time.monotonic()
            try:
                await asyncio.wait_for(ws.send(json.dumps({"type": "input_audio_buffer.append", "audio": base64.b64encode(chunk).decode()})), 5)
            finally:
                writes.append({"t": before-begin, "audio_end": (offset+len(chunk))/32000,
                               "write_seconds": time.monotonic()-before,
                               "schedule_lag": before-deadline})
            sent += len(chunk)
        await asyncio.wait_for(ws.send(json.dumps({"type": "session.finish"})), 5)
        await asyncio.wait_for(finished.wait(), 20)
    except Exception as e:
        # Error text can contain an authenticated URL, so retain only the type.
        failure = type(e).__name__
    finally:
        for task in (receiver, monitor):
            if task: task.cancel()
        for task in (receiver, monitor):
            if task:
                try: await task
                except BaseException: pass
        if ws: await ws.close()
        else: sock.close()
        result = {"failure": failure, "input_seconds": len(pcm)/32000, "sent_seconds": sent/32000,
                  "peer": peer if ws else None, "mss_requested": args.mss, "pace": args.pace, "input_start": None if origin is None else origin-begin,
                  "finished": finished.is_set(), "events": events, "writes": writes, "tcp": samples}
        (args.output/"result.json").write_text(json.dumps(result, ensure_ascii=False, indent=2))
        print(json.dumps({"output": str(args.output), "failure": failure, "sent_seconds": sent/32000,
                          "finished": finished.is_set(), "max_write": max((w["write_seconds"] for w in writes), default=0),
                          "max_lag": max((w["schedule_lag"] for w in writes), default=0),
                          "tcp_last": samples[-1] if samples else None}, ensure_ascii=False))


if __name__ == "__main__":
    asyncio.run(main())
