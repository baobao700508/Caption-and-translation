import Foundation
import AVFoundation
import AppKit
import CoreAudio
import AudioBridge
import LiveCaptionCore

func requireAudio(_ status: OSStatus, _ action: String) throws {
    guard status == noErr else { throw CaptionError.message("\(action)失败（Core Audio \(status)），请检查音频录制权限和设备") }
}
func audioProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T) throws -> T {
    var a = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var result = initial; var size = UInt32(MemoryLayout<T>.size)
    try withUnsafeMutablePointer(to: &result) { pointer in
        try requireAudio(AudioObjectGetPropertyData(object, &a, 0, nil, &size, pointer), "读取音频设备")
    }
    return result
}
func audioStringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
    var a = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    try requireAudio(AudioObjectGetPropertyData(object, &a, 0, nil, &size, &value), "读取音频进程标识")
    return value.map { $0.takeRetainedValue() as String } ?? ""
}
struct AudioProcess: Identifiable {
    let id: AudioObjectID
    let pid: pid_t
    let bundleID: String
}
func audioProcesses() -> [AudioProcess] {
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.compactMap { id in
        guard let pid = try? audioProperty(id, kAudioProcessPropertyPID, initial: pid_t(0)) else { return nil }
        let bundle = (try? audioStringProperty(id, kAudioProcessPropertyBundleID)) ?? ""
        return AudioProcess(id: id, pid: pid, bundleID: bundle)
    }
}

// HAL state is confined to managementQueue; IOProc only accesses the SPSC ring.
