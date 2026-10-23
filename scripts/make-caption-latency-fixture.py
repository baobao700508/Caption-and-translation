"""One finite, known-reference speech sequence. Writes files; never plays audio."""
import array
import json
from pathlib import Path
import subprocess
import sys
import wave

root = Path(sys.argv[1])
root.mkdir(parents=True, exist_ok=False)
sentences = [
    ("The deadline is Monday, not Friday.", "friday", "(?:星期五|周五|礼拜五)"),
    ("This lecture explains supply and demand.", "demand", "需求"),
    ("Please save the transcript as the class continues.", "continues", "(?:继续|进行)"),
    ("A price increase reduces quantity demanded.", "demanded", "需求量"),
    ("The lecture ends at four thirty.", "thirty", "(?:四点半|四点三十|4点半|4:30)"),
]
pcm = bytearray(32000)
references = []
for index, (text, last_word, translated_last) in enumerate(sentences):
    source = root/f"sentence-{index}.aiff"
    target = root/f"sentence-{index}.wav"
    subprocess.run(["say", "-v", "Samantha", "-r", "180", "-o", str(source), text], check=True)
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(source), str(target)], check=True)
    with wave.open(str(target)) as f:
        assert (f.getframerate(), f.getnchannels(), f.getsampwidth()) == (16000, 1, 2)
        chunk = f.readframes(f.getnframes())
    values = array.array("h", chunk)
    # End-of-voice estimate at 10 ms resolution, documented separately from a word alignment.
    active = [i for i in range(0, len(values), 160) if any(abs(v)>180 for v in values[i:i+160])]
    offset = len(pcm)/32000
    references.append({"text":text, "last_word":last_word, "translation_pattern":translated_last,
                       "voice_start":offset+active[0]/16000, "voice_end":offset+(active[-1]+160)/16000})
    pcm.extend(chunk)
    pcm.extend(bytes(32000))
with wave.open(str(root/"sentences.wav"), "wb") as f:
    f.setparams((1, 2, 16000, 0, "NONE", "not compressed")); f.writeframes(pcm)
(root/"reference.json").write_text(json.dumps({"scope":"Finite synthetic reference for sentence-end latency; real classroom replay remains separate.","sentences":references}, ensure_ascii=False, indent=2))
print(json.dumps({"audio":str(root/"sentences.wav"),"seconds":len(pcm)/32000,"sentences":len(sentences)}))
