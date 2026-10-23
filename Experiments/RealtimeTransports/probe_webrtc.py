"""Finite file-only WebRTC comparison; no audio devices or credential-bearing logs."""
import argparse
import asyncio
from fractions import Fraction
import json
import os
from pathlib import Path
import time
import wave
from datetime import datetime

import aiohttp
from aiortc import AudioStreamTrack, RTCPeerConnection, RTCConfiguration, RTCSessionDescription
from aiortc.mediastreams import MediaStreamError
from av import AudioFrame


class FileAudio(AudioStreamTrack):
    def __init__(self, pcm, ready, begin):
        super().__init__()
        self.pcm, self.ready, self.begin = pcm, ready, begin
        self.offset = 0
        self.origin = None
        self.last_media = None
        self.deliveries = []

    async def recv(self):
        await self.ready.wait()
        now = time.monotonic()
        if self.origin is None: self.origin = now
        pts = getattr(self, "frame_pts", 0)
        await asyncio.sleep(max(0, self.origin+pts/16000-now))
        # Keep RTP alive with explicit silence until session.finished arrives.
        chunk = self.pcm[self.offset:self.offset+640]
        if chunk:
            self.offset += len(chunk)
            if self.offset >= len(self.pcm): self.last_media = time.monotonic()
            self.deliveries.append({"audio_end": self.offset/32000, "t": time.monotonic()-self.begin})
        chunk = chunk.ljust(640, b"\0")
        frame = AudioFrame(format="s16", layout="mono", samples=320)
        frame.planes[0].update(chunk)
        frame.sample_rate = 16000
        frame.time_base = Fraction(1, 16000)
        # PTS must advance during the silence tail too.
        frame.pts = pts
        self.frame_pts = frame.pts+320
        return frame


async def main():
    os.umask(0o077)
    p = argparse.ArgumentParser()
    p.add_argument("audio", type=Path)
    p.add_argument("output", type=Path)
    p.add_argument("--mode", choices=["subtitles", "speech"], default="subtitles")
    p.add_argument("--detector", choices=["speaker_detection", "server_vad"], default="speaker_detection")
    p.add_argument("--jev-replay-log", type=Path, help="Replay recorded JEV requests at their original media-clock times; no Swift UI involved")
    args = p.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    cfg = json.loads((Path.home()/"Desktop/LiveCaption配置.json").read_text())
    assert cfg.get("bailianRegion") == "beijing"
    url = f"https://{cfg['bailianWorkspaceID']}.cn-beijing.maas.aliyuncs.com/api/v1/webrtc/realtime?model={cfg['bailianTranslateModel']}"
    with wave.open(str(args.audio)) as f:
        assert (f.getframerate(), f.getnchannels(), f.getsampwidth()) == (16000, 1, 2)
        pcm = f.readframes(f.getnframes())
    begin = time.monotonic()
    ready, finished = asyncio.Event(), asyncio.Event()
    events, stats = [], []
    failure = None
    http_status = None
    pc = RTCPeerConnection(RTCConfiguration(iceServers=[]))
    track = FileAudio(pcm, ready, begin)
    pc.addTrack(track)
    channel = pc.createDataChannel("oai-events")
    control = None
    output_samples = 0
    tasks = []
    jev_replay = []

    async def replay_jev():
        records=[json.loads(line) for line in args.jev_replay_log.read_text().splitlines() if line.strip()]
        # The application journals a proposed body before checking its 750 KB limit.
        # Replaying rejected proposals would add traffic the failing app never sent.
        requests=[row for row in records if row.get("event_type")=="caption.reflow.request" and row.get("encoded_bytes",0)<=750000]
        source_events=[json.loads(line) for line in args.jev_replay_log.with_name("events.jsonl").read_text().splitlines() if line.strip()]
        rtp=next(row for row in source_events if row.get("event_type")=="transport.webrtc_stats" and row.get("kind")=="outbound-rtp" and row.get("packetsSent",0)>0)
        parse=lambda value: datetime.fromisoformat(value.replace("Z","+00:00")).timestamp()
        media_origin=parse(rtp["received_at"])-rtp["packetsSent"]*.02
        configured=cfg["captionReflow"]["jev"]
        while track.origin is None:
            await asyncio.sleep(.01)
        async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=configured.get("timeoutSeconds",6))) as session:
            for row in requests:
                delay=track.origin+parse(row["received_at"])-media_origin-time.monotonic()
                if delay>0:
                    await asyncio.sleep(delay)
                started=time.monotonic()
                entry={"t":started-begin,"stage":row.get("stage"),"request":row["request"]}
                try:
                    async with session.post(configured["endpoint"],json=row["request"],headers={"Authorization":"Bearer "+configured["apiKey"]}) as response:
                        entry["http_status"]=response.status
                        if response.status==200:
                            entry["response"]=await response.json()
                except Exception as error:
                    entry["failure"]=type(error).__name__
                entry["elapsed_seconds"]=time.monotonic()-started
                jev_replay.append(entry)

    def configure_channel(ch):
        @ch.on("message")
        def message(data):
            nonlocal control
            try: root = json.loads(data)
            except (ValueError, TypeError): return
            kind = root.get("type")
            entry = {"t": time.monotonic()-begin, "type": kind}
            for key in ("item_id", "audio_start_ms", "audio_end_ms"):
                if key in root: entry[key] = root[key]
            if kind in ("conversation.item.input_audio_transcription.delta", "response.text.delta", "response.audio_transcript.delta"):
                entry["text"] = root.get("delta", "")
            if kind == "error": entry["code"] = root.get("error", {}).get("code")
            if kind == "session.updated":
                s = root.get("session", {})
                entry["configuration"] = {k: s.get(k) for k in ("model", "output_modalities", "translation", "audio")}
                assert s.get("model") == cfg["bailianTranslateModel"]
                assert s.get("translation", {}).get("language") == "zh"
                ready.set()
            events.append(entry)
            if kind == "session.created":
                control = ch
                ch.send(json.dumps({"type": "session.update", "session": {
                    "output_modalities": ["text", "audio"] if args.mode == "speech" else ["text"],
                    "audio": {"input": {"turn_detection": {"type": args.detector, **({"threshold": 0.5} if args.detector == "speaker_detection" else {})}}},
                    "enable_voice_clone": False, "voice": "Tina", "translation": {"language": "zh"}}}))
            if kind == "session.finished": finished.set()

    configure_channel(channel)
    pc.on("datachannel", configure_channel)

    @pc.on("track")
    def remote_track(remote):
        async def drain():
            nonlocal output_samples
            try:
                while True:
                    frame = await remote.recv()
                    if remote.kind == "audio": output_samples += frame.samples
            except MediaStreamError: pass
        tasks.append(asyncio.create_task(drain()))

    async def observe():
        while True:
            report = await pc.getStats()
            for row in report.values():
                safe = {k:v for k,v in vars(row).items() if isinstance(v, (str, int, float, bool)) and k not in ("id", "transportId", "ssrc")}
                stats.append({"t": time.monotonic()-begin, **safe})
            await asyncio.sleep(1)

    try:
        await pc.setLocalDescription(await pc.createOffer())
        async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=20)) as session:
            async with session.post(url, data=pc.localDescription.sdp,
                                    headers={"Authorization": "Bearer "+cfg["bailianAPIKey"], "Content-Type": "application/sdp"}) as response:
                http_status = response.status
                answer = await response.text()
                if response.status != 200: raise RuntimeError("SDP exchange failed")
        await pc.setRemoteDescription(RTCSessionDescription(sdp=answer, type="answer"))
        tasks.append(asyncio.create_task(observe()))
        await asyncio.wait_for(ready.wait(), 20)
        if args.jev_replay_log:
            tasks.append(asyncio.create_task(replay_jev()))
        limit = time.monotonic()+len(pcm)/32000+10
        while track.last_media is None:
            if time.monotonic() > limit: raise TimeoutError("input stalled")
            await asyncio.sleep(0.05)
        # Flush encoder/resampler remainder and the last RTP packet before finish control.
        await asyncio.sleep(0.2)
        if control is None: raise RuntimeError("no control channel")
        control.send(json.dumps({"type": "session.finish"}))
        await asyncio.wait_for(finished.wait(), 20)
    except Exception as e:
        failure = type(e).__name__
    finally:
        for task in tasks: task.cancel()
        await pc.close()
        for task in tasks:
            try: await task
            except BaseException: pass
        result = {"failure": failure, "http_status": http_status, "mode": args.mode, "detector": args.detector,
                  "input_seconds": len(pcm)/32000, "submitted_seconds": track.offset/32000,
                  "input_start": None if track.origin is None else track.origin-begin,
                  "finished": finished.is_set(), "output_samples": output_samples,
                  "events": events, "deliveries": track.deliveries, "stats": stats,
                  "jev_replay":jev_replay}
        (args.output/"result.json").write_text(json.dumps(result, ensure_ascii=False, indent=2))
        print(json.dumps({k:v for k,v in result.items() if k not in ("events", "deliveries", "stats", "jev_replay")}, ensure_ascii=False))


if __name__ == "__main__":
    asyncio.run(main())
