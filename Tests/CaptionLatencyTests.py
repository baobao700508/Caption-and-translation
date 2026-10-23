import json
from pathlib import Path
import runpy
import tempfile
import unittest
import wave
from datetime import datetime,timedelta,timezone

audit=runpy.run_path(str(Path(__file__).resolve().parents[1]/"scripts/analyze-caption-latency.py"))["audit"]
progress=runpy.run_path(str(Path(__file__).resolve().parents[1]/"scripts/compare-caption-progress.py"))

class CaptionLatencyTests(unittest.TestCase):
    def measure(self,events,uploads=()):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);(root/"audio").mkdir()
            (root/"events.jsonl").write_text("\n".join(json.dumps(e) for e in events))
            (root/"audio/upload-index.jsonl").write_text("\n".join(json.dumps(e) for e in uploads))
            return audit(root)

    def epoch(self,number,minute=0):
        return [
            {"event_type":"connection.active","connection_epoch":number,"received_at":f"2026-10-22T02:{minute:02}:00.000Z"},
            {"event_type":"transport.webrtc_stats","connection_epoch":number,"kind":"outbound-rtp","packetsSent":50,"received_at":f"2026-10-22T02:{minute:02}:01.000Z"},
            {"event_type":"transport.webrtc_stats","connection_epoch":number,"kind":"outbound-rtp","packetsSent":100,"received_at":f"2026-10-22T02:{minute:02}:02.000Z"},
        ]

    def test_twenty_second_provider_delay_is_not_subtracted_as_hardware_startup(self):
        events=self.epoch(1)+[{"event_type":"input_audio_buffer.speech_stopped","connection_epoch":1,"audio_end_ms":100000,"received_at":"2026-10-22T02:02:01.000Z"}]
        uploads=[{"capture_ended_at":"2026-10-22T02:00:13.000Z","submitted_at":"2026-10-22T02:00:13.110Z","send_completed_at":"2026-10-22T02:00:13.111Z"}]
        result=self.measure(events,uploads)
        self.assertAlmostEqual(result["maximum_provider_event_lag_seconds"],21)
        self.assertLess(result["capture_to_submit_max_seconds"],.12)

    def test_reconnect_restarts_the_provider_audio_clock(self):
        events=self.epoch(1)+self.epoch(2,minute=2)+[{"event_type":"input_audio_buffer.speech_stopped","connection_epoch":2,"audio_end_ms":3000,"received_at":"2026-10-22T02:02:04.000Z"}]
        self.assertAlmostEqual(self.measure(events)["maximum_provider_event_lag_seconds"],1)

    def test_unavailable_provider_timestamps_are_not_zero_latency(self):
        result=self.measure(self.epoch(1))
        self.assertIsNone(result["maximum_provider_event_lag_seconds"])

    def test_timely_vad_does_not_hide_seven_second_first_translation(self):
        events=self.epoch(1)+[
            {"event_type":"input_audio_buffer.speech_started","audio_start_ms":10000,"received_at":"2026-10-22T02:00:11.000Z"},
            {"event_type":"text.append","track":"translation","segment_id":"target","text":"第一批字幕", "audio_start_ms":10000,"received_at":"2026-10-22T02:00:17.000Z"},
            {"event_type":"text.append","track":"translation","segment_id":"target","text":"继续", "audio_start_ms":10000,"received_at":"2026-10-22T02:00:19.000Z"},
            {"event_type":"text.replace","track":"translation","segment_id":"target","text":"第一批字幕继续", "audio_start_ms":10000,"received_at":"2026-10-22T02:00:25.000Z"},
        ]
        result=self.measure(events)
        self.assertAlmostEqual(result["maximum_provider_event_lag_seconds"],1)
        self.assertEqual(len(result["first_text_events"]),1)
        self.assertAlmostEqual(result["maximum_first_text_delay_seconds"],7)

    def test_text_without_provider_start_is_not_a_zero_first_text_delay(self):
        events=self.epoch(1)+[{"event_type":"text.append","track":"source","segment_id":"source","text":"hello","received_at":"2026-10-22T02:00:17.000Z"}]
        result=self.measure(events)
        self.assertIsNone(result["maximum_first_text_delay_seconds"])
        self.assertEqual(len(result["unmeasured_first_text_events"]),1)

    def fixture(self,root,growth=0,pcm=b'\0\0'):
        root.mkdir();(root/'audio').mkdir()
        with wave.open(str(root/'audio/uploaded.wav'),'w') as f:
            f.setparams((1,2,16000,0,'NONE','not compressed'));f.writeframes(pcm)
        origin=datetime(2026,10,22,tzinfo=timezone.utc)
        stamp=lambda s:(origin+timedelta(seconds=s)).isoformat()
        rows=[{'event_type':'connection.active','received_at':stamp(0)},
              {'event_type':'transport.webrtc_stats','kind':'outbound-rtp','packetsSent':50,'received_at':stamp(1)},
              {'event_type':'input_audio_buffer.speech_stopped','audio_end_ms':1000,'received_at':stamp(2)},
              {'event_type':'connection.final_finish','confirmed':True,'received_at':stamp(100)}]
        text=''
        for i in range(40):
            word=f'word{i} ';text+=word
            rows.append({'event_type':'text.append','segment_id':'one','track':'source','text':word,'received_at':stamp(3+i+growth*i/39)})
        rows.append({'event_type':'text.replace','segment_id':'one','track':'source','text':text,'received_at':stamp(90)})
        (root/'events.jsonl').write_text('\n'.join(json.dumps(r) for r in rows))

    def test_final_replacement_preserves_first_interim_word_arrival(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp)/'a';self.fixture(root)
            words=progress['source_words'](root)
            self.assertEqual(words[0],('word0',3))
            self.assertEqual(words[-1],('word39',42))

    def test_same_pcm_progress_excludes_microphone_startup_silence(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp)/'a';self.fixture(root)
            rows=[json.loads(s) for s in (root/'events.jsonl').read_text().splitlines()]
            for row in rows:
                if row['event_type'].startswith('text.'):
                    row['received_at']=(datetime.fromisoformat(row['received_at'])+timedelta(seconds=7)).isoformat()
            rows.append({'event_type':'transport.webrtc_input','consumed_samples':16000,
                         'underflow_samples':0,'tail_padding_samples':0,'received_at':'2026-10-22T00:00:08+00:00'})
            (root/'events.jsonl').write_text('\n'.join(json.dumps(r) for r in rows))
            self.assertEqual(progress['source_words'](root)[0],('word0',3))

    def test_same_audio_caption_progress_rejects_accumulating_twenty_seconds(self):
        with tempfile.TemporaryDirectory() as temp:
            a,b=Path(temp)/'actual',Path(temp)/'reference';self.fixture(a,growth=20);self.fixture(b)
            result=progress['compare'](a,b)
            self.assertFalse(result['success'])
            self.assertGreater(result['last_minus_first_quarter_seconds'],14)
            self.assertEqual(result['maximum_extra_seconds'],20)

    def test_different_audio_cannot_be_a_passing_progress_comparison(self):
        with tempfile.TemporaryDirectory() as temp:
            a,b=Path(temp)/'actual',Path(temp)/'reference';self.fixture(a);self.fixture(b,pcm=b'\x01\0')
            with self.assertRaisesRegex(ValueError,'Recordings differ'):
                progress['compare'](a,b)

if __name__=="__main__":
    unittest.main()
