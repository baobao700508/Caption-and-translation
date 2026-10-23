import Foundation
import CoreAudio
var address = AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDefaultInputDevice,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
var device = AudioDeviceID(0);var size = UInt32(MemoryLayout<AudioDeviceID>.size)
let result = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&size,&device)
var name:CFString = "" as CFString
address.mSelector = kAudioObjectPropertyName;size=UInt32(MemoryLayout<CFString>.size)
AudioObjectGetPropertyData(device,&address,0,nil,&size,&name)
print("default input:",name,"device",device,"status",result)
address.mSelector=kAudioDevicePropertyStreamConfiguration;address.mScope=kAudioDevicePropertyScopeInput
var bytes:UInt32=0
AudioObjectGetPropertyDataSize(device,&address,0,nil,&bytes)
let raw = UnsafeMutableRawPointer.allocate(byteCount:Int(bytes),alignment:MemoryLayout<AudioBufferList>.alignment)
AudioObjectGetPropertyData(device,&address,0,nil,&bytes,raw)
let buffers=UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to:AudioBufferList.self))
print("physical input channels:",buffers.reduce(0){$0+Int($1.mNumberChannels)})
raw.deallocate()
