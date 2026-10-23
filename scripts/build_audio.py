#!/usr/bin/env python3
"""Build and bundle the standalone WebRTC APM; no runtime Python dependency."""
from pathlib import Path
import hashlib, os, subprocess, sys, tarfile, urllib.request
root=Path(__file__).resolve().parent.parent
os.chdir(root)
env=dict(os.environ, DEVELOPER_DIR=os.environ.get('LIVECAPTION_DEVELOPER_DIR') or os.environ.get('DEVELOPER_DIR') or subprocess.check_output(['xcode-select','-p'],text=True).strip(), MACOSX_DEPLOYMENT_TARGET='14.2')
vendor=root/'Vendor'; vendor.mkdir(exist_ok=True)
archive=vendor/'webrtc-audio-processing-2.1.tar.gz'
url='https://gstreamer.freedesktop.org/src/mirror/webrtc-audio-processing/webrtc-audio-processing-2.1.tar.gz'
if not archive.exists(): urllib.request.urlretrieve(url,archive)
digest=hashlib.sha256(archive.read_bytes()).hexdigest()
lock=root/'Documentation/audio-source.sha256'
if lock.exists() and digest!=lock.read_text().split()[0]: raise SystemExit('APM archive checksum mismatch')
source=vendor/'webrtc-audio-processing-2.1'
if not source.exists():
    with tarfile.open(archive) as t:
        for m in t.getmembers():
            dest=(vendor/m.name).resolve()
            if not dest.is_relative_to(vendor.resolve()) or m.issym() or m.islnk(): raise SystemExit('Unexpected archive path/link')
        t.extractall(vendor,filter='data')
tools=root/'.tools'
if not (tools/'bin/python3').exists(): subprocess.run([sys.executable,'-m','venv',str(tools)],check=True,env=env)
if not (tools/'bin/meson').exists(): subprocess.run([str(tools/'bin/pip'),'install','meson==1.9.1','ninja==1.13.0'],check=True,env=env)
env['PATH']=str(tools/'bin')+os.pathsep+env['PATH']
meson=str(tools/'bin/meson'); build=vendor/'build'; prefix=vendor/'install'
command=[meson,'setup',str(build),str(source),'--prefix',str(prefix),'--libdir','lib','--buildtype','release','-Ddefault_library=static','--force-fallback-for=abseil-cpp','-Dc_args=-mmacosx-version-min=14.2','-Dcpp_args=-mmacosx-version-min=14.2']
if (build/'build.ninja').exists(): command.insert(2,'--reconfigure')
subprocess.run(command,check=True,env=env)
subprocess.run([meson,'compile','-C',str(build),'-j','6'],check=True,env=env)
subprocess.run([meson,'install','-C',str(build),'--no-rebuild','--quiet'],check=True,env=env)
libs=sorted(build.rglob('*.a'))
subprocess.run(['xcrun','libtool','-static','-o',str(prefix/'lib/liblivecaption-apm.a'),*[str(p) for p in libs]],check=True,env=env)
notices=['LiveCaption audio dependencies\n\nWebRTC APM standalone 2.1\nSource: '+url+'\nSHA256: '+digest+'\n']
for p in [source/'COPYING',source/'webrtc/LICENSE',source/'webrtc/PATENTS',source/'subprojects/abseil-cpp-20240722.0/LICENSE']:
    if p.exists(): notices.append('\n--- '+str(p.relative_to(source))+' ---\n'+p.read_text())
for p in sorted((source/'webrtc/third_party').rglob('*')):
    if p.is_file() and (p.name.startswith('COPYING') or p.name.startswith('LICENSE')):
        notices.append('\n--- '+str(p.relative_to(source))+' ---\n'+p.read_text())
(root/'Resources/ThirdPartyNotices.txt').write_text('\n'.join(notices))
print('APM built; third-party notices generated.')
