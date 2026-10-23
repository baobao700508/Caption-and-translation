import Foundation
import CoreAudio
import AVFoundation
import LiveCaptionCore

struct AudioDeviceChoice: Identifiable, Sendable {
    let id: String
    let objectID: AudioObjectID
    let name: String
}
func availableAudioDevices(input: Bool) -> [AudioDeviceChoice] {
    var address = AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDevices,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    let system = AudioObjectID(kAudioObjectSystemObject)
    guard AudioObjectGetPropertyDataSize(system,&address,0,nil,&size) == noErr else { return [] }
    var ids = [AudioObjectID](repeating:0,count:Int(size)/MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(system,&address,0,nil,&size,&ids) == noErr else { return [] }
    return ids.compactMap { id in
        var scope = AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyStreamConfiguration,mScope:input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput,mElement:kAudioObjectPropertyElementMain)
        var bytes: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id,&scope,0,nil,&bytes) == noErr, bytes>=MemoryLayout<AudioBufferList>.size else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount:Int(bytes),alignment:MemoryLayout<AudioBufferList>.alignment); defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id,&scope,0,nil,&bytes,raw) == noErr else { return nil }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to:AudioBufferList.self))
        guard list.contains(where: { $0.mNumberChannels>0 }), let uid = try? audioStringProperty(id,kAudioDevicePropertyDeviceUID),
              let name = try? audioStringProperty(id,kAudioObjectPropertyName), !name.hasPrefix("LiveCaption") else { return nil }
        return AudioDeviceChoice(id:uid,objectID:id,name:name)
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
}
@MainActor func selectAudioDevice(uid: String, input: Bool, node: AVAudioIONode) throws {
    guard !uid.isEmpty else { return }
    guard let device = availableAudioDevices(input:input).first(where: { $0.id == uid }), let unit = node.audioUnit else { throw CaptionError.message("所选\(input ? "输入" : "输出")设备不可用，请重新选择") }
    var id = device.objectID
    try requireAudio(AudioUnitSetProperty(unit,kAudioOutputUnitProperty_CurrentDevice,kAudioUnitScope_Global,0,&id,UInt32(MemoryLayout<AudioObjectID>.size)),"切换音频设备")
}
