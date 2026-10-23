from pathlib import Path
import json,wave,numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
root=Path('/Users/jinliangjian/Documents/LiveCaption Logs/2026-10-21/30666428-1c9f-43b7-9214-624ea1f13037/audio')
def load(name):
 with wave.open(str(root/name),'rb') as f:return np.frombuffer(f.readframes(f.getnframes()),'<i2').astype(float)/32768,f.getframerate()
source,rate=load('microphone-input.wav');upload,ur=load('uploaded.wav')
fig,axes=plt.subplots(3,1,figsize=(12,7),gridspec_kw={'height_ratios':[1,1,1.6]},layout='constrained')
for ax,(x,r,title,color) in zip(axes[:2],[(source,rate,'Microphone after alignment: 62.62 s','#277bba'),(upload,ur,'Successful uploads, concatenated: 34.60 s','#d27b25')]):
 step=480 if r==48000 else 160;n=len(x)//step;b=x[:n*step].reshape(n,step);t=np.arange(n)*step/r
 ax.fill_between(t,b.min(axis=1),b.max(axis=1),color=color,alpha=.9);ax.set_title(title,loc='left');ax.set_ylabel('Amplitude');ax.set_xlim(0,len(x)/r);ax.grid(alpha=.2)
start=5;length=.6;x=source[int(start*rate):int((start+length)*rate)];t=np.arange(len(x))/rate
axes[2].plot(t*1000,x,color='#277bba',linewidth=.5)
z=x==0;d=np.diff(np.r_[False,z,False].astype(int));starts=np.where(d==1)[0];ends=np.where(d==-1)[0]
for a,b in zip(starts,ends):
 if (b-a)/rate>.02:axes[2].axvspan(a/rate*1000,b/rate*1000,color='#e63946',alpha=.2)
axes[2].set_title('Microphone zoom at file time 5.0 s: 50–60 ms zeros every 100 ms',loc='left')
axes[2].set_xlabel('Milliseconds within this 600 ms excerpt');axes[2].set_ylabel('Amplitude');axes[2].set_xlim(0,600);axes[2].grid(alpha=.2)
fig.suptitle('Actual user recording — periodic audio holes before upload',fontsize=15)
fig.savefig('TestResults/user-audio-diagnosis/waveform.png',dpi=160)
