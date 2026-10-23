from pathlib import Path
import wave,json,numpy as np,sys
p=Path(sys.argv[1]) if len(sys.argv)>1 else Path('TestResults/user-audio-diagnosis/weak-input-ab')
r=json.loads((p/'result.json').read_text())
if not r.get('success') or not r.get('unprocessed_audio_directory'): raise SystemExit('并行采集未完整成功，不能解释原始/处理后差异')
def read(path):
 with wave.open(str(path),'rb') as f: return np.frombuffer(f.readframes(f.getnframes()),'<i2').astype(float)/32768,f.getframerate()
raw,sr=read(Path(r['unprocessed_audio_directory'])/'microphone-captured.wav')
vp,pr=read(Path(r['audio_directory'])/'microphone-captured.wav')
assert sr==pr==48000
assert min(len(raw),len(vp))>=48000*4, "对照音频不足四秒，不能解释差异"
out={'sample_rate':sr,'tracks':{}}
for name,x in [('unprocessed',raw),('apple_voice_processing',vp)]:
 zero=x==0;d=np.diff(np.r_[False,zero,False].astype(int));s=np.where(d==1)[0];e=np.where(d==-1)[0];runs=(e-s)/sr
 out['tracks'][name]={'seconds':len(x)/sr,'rms_dbfs':float(20*np.log10(max(1e-12,np.sqrt(np.mean(x*x))))),'peak_dbfs':float(20*np.log10(max(1e-12,np.max(np.abs(x))))),'digital_zero_fraction':float(np.mean(zero)),'zero_runs_over20ms':int(np.sum(runs>=.02))}
# Locate the same content; both microphones sampled simultaneously but their taps have different origins/latency.
n=1<<(len(raw)+len(vp)-1).bit_length();cross=np.fft.irfft(np.fft.rfft(raw,n)*np.conj(np.fft.rfft(vp,n)),n)
lags=np.arange(-sr//2,sr//2+1);lag=int(lags[np.argmax(np.abs(cross[lags%n]))]);out['estimated_alignment_lag_samples']=lag
if lag>=0:x=raw[lag:];y=vp
else:x=raw;y=vp[-lag:]
k=min(len(x),len(y));x=x[:k];y=y[:k]
out['waveform_correlation']=float(np.corrcoef(x,y)[0,1])
block=480;count=k//block
xr=np.sqrt(np.mean(x[:count*block].reshape(count,block)**2,axis=1));yr=np.sqrt(np.mean(y[:count*block].reshape(count,block)**2,axis=1))
selected=xr>=np.percentile(xr,70)
gain=20*np.log10(np.maximum(yr[selected],1e-12)/np.maximum(xr[selected],1e-12))
out['relative_gain_db_in_raw_top30pct_energy_windows']={'p10':float(np.percentile(gain,10)),'p50':float(np.median(gain)),'p90':float(np.percentile(gain,90))}
out['scope']='One simultaneous real external quiet-source capture. Correlation/relative levels do not prove recognition accuracy.'
(p/'comparison.json').write_text(json.dumps(out,ensure_ascii=False,indent=2));print(json.dumps(out,ensure_ascii=False,indent=2))
