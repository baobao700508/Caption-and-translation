import Foundation
import AVFoundation
import AppKit
import CoreAudio
import AudioBridge
import LiveCaptionCore

final class SystemCapture: @unchecked Sendable {
    private var tap: AudioObjectID = 0
    private var device: AudioObjectID = 0
    private var io: AudioDeviceIOProcID?
    private let ring: OpaquePointer
    private let callbackQueue = DispatchQueue(label: "LiveCaption.system.capture", qos: .userInteractive)
    private let managementQueue = DispatchQueue(label: "LiveCaption.system.management", qos: .userInitiated)
    init(ring: OpaquePointer) { self.ring = ring }
    func start(bundleID: String, onlyPID: pid_t? = nil, rootPIDs: [pid_t] = []) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void,Error>) in
            managementQueue.async {
                do { try self.startNow(bundleID: bundleID, onlyPID: onlyPID, rootPIDs:rootPIDs); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    private func startNow(bundleID: String, onlyPID: pid_t?, rootPIDs: [pid_t]) throws {
        let processes = audioProcesses()
        let own = processes.filter { $0.pid == getpid() }.map(\.id)
        let description: CATapDescription
        if let pid = onlyPID {
            let ids = processes.filter { $0.pid == pid }.map(\.id)
            guard !ids.isEmpty else { throw CaptionError.message("验证播放器尚未建立音频进程") }
            description = CATapDescription(stereoMixdownOfProcesses: ids)
        } else if bundleID.isEmpty { description = CATapDescription(stereoGlobalTapButExcludeProcesses: own) }
        else {
            let ids = processes.filter { p in p.pid != getpid() && (p.bundleID == bundleID || p.bundleID.hasPrefix(bundleID+".") || rootPIDs.contains(where: { lc_process_descends_from(p.pid,$0) != 0 })) }.map(\.id)
            guard !ids.isEmpty else { throw CaptionError.message("所选应用尚未产生音频；先在该应用播放声音，再开始") }
            description = CATapDescription(stereoMixdownOfProcesses: ids)
        }
        description.name = "LiveCaption 输入"; description.uuid = UUID(); description.isPrivate = true; description.muteBehavior = .unmuted
        do {
            try requireAudio(AudioHardwareCreateProcessTap(description, &tap), "创建系统音频采集")
            let format = try audioProperty(tap, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
            guard format.mSampleRate > 0, format.mFormatID == kAudioFormatLinearPCM else { throw CaptionError.message("系统音频格式不可用") }
            let definition: [String: Any] = [
                kAudioAggregateDeviceNameKey: "LiveCaption Capture", kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true, kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]]
            ]
            try requireAudio(AudioHardwareCreateAggregateDevice(definition as CFDictionary, &device), "创建聚合采集设备")
            let ring = self.ring
            try requireAudio(AudioDeviceCreateIOProcIDWithBlock(&io, device, callbackQueue) { _, input, time, _, _ in
                var f = format
                let frames = f.mBytesPerFrame == 0 ? 0 : input.pointee.mBuffers.mDataByteSize / f.mBytesPerFrame
                if frames > 0 { _ = lc_ring_write(ring, input, &f, frames, time.pointee.mHostTime) }
            }, "创建系统音频回调")
            try requireAudio(AudioDeviceStart(device, io), "开始系统采集")
        } catch { stopNow(); throw error }
    }
    func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void,Never>) in
            managementQueue.async { self.stopNow(); continuation.resume() }
        }
    }
    private func stopNow() {
        if device != 0 {
            AudioDeviceStop(device, io)
            if let io { AudioDeviceDestroyIOProcID(device, io) }
            AudioHardwareDestroyAggregateDevice(device); device = 0; io = nil
        }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap); tap = 0 }
    }
    deinit { stopNow() }
}
