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

@MainActor final class AudioHardware {
    let systemRing = lc_ring_create()!
    let microphoneRing = lc_ring_create()!
    private var system: SystemCapture?
    private(set) var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var timePitch = AVAudioUnitTimePitch()
    private var catchUp = PlaybackCatchUpController()
    private var playbackControlTask: Task<Void,Never>?
    private var lastControlUptime = 0.0
    private var lastPlaybackReport = 0.0
    private var lastReportedRate = 1.0
    private var playbackScheduledSamples = 0
    private var playbackCompletedSamples = 0
    private var hasMicrophoneTap = false
    private var queuedSeconds = 0.0
    private var playbackGeneration = 0
    private(set) var scheduledBuffers = 0
    private(set) var completedBuffers = 0
    var playbackEvent: ((String,[String:Any]) -> Void)?
    var playbackIsActive: Bool { player.isPlaying && queuedSeconds>0 }
    var pendingPlaybackSeconds: Double { queuedSeconds }
    var playbackEnabled = false
    var volume: Float = 0.7 { didSet { player.volume = volume } }
    private(set) var microphoneUsesNative = false
    func start(_ config: Configuration, onlySystemPID: pid_t? = nil) async throws -> [String: Any] {
        await stop()
        lc_ring_reset(systemRing); lc_ring_reset(microphoneRing)
        lc_ring_set_channel_mode(systemRing,config.systemChannelMode == .left ? 1 : (config.systemChannelMode == .right ? 2 : 0))
        lc_ring_set_channel_mode(microphoneRing,0)
        engine = AVAudioEngine(); player = AVAudioPlayerNode(); timePitch = AVAudioUnitTimePitch()
        catchUp = PlaybackCatchUpController(configuration:config.playbackCatchUp)
        scheduledBuffers = 0; completedBuffers = 0
        engine.attach(player); engine.attach(timePitch)
        let playbackFormat = AVAudioFormat(standardFormatWithSampleRate:24000,channels:1)!
        engine.connect(player,to:timePitch,format:playbackFormat)
        engine.connect(timePitch,to:engine.mainMixerNode,format:playbackFormat)
        timePitch.pitch = 0; timePitch.rate = 1
        player.volume = volume
        var info: [String: Any] = ["system_processor": config.systemNoiseSuppression ? "webrtc-apm-2.1-ns-low" : "bypass", "system_aec": false, "system_agc": false]
        do {
            if config.microphoneEnabled {
                let authorized = await AVCaptureDevice.requestAccess(for: .audio)
                guard authorized else { throw CaptionError.message("麦克风权限未获准，请在系统隐私设置允许 LiveCaption") }
                let input = engine.inputNode
                microphoneUsesNative = false
                if config.microphoneVoiceProcessing {
                    do {
                        try input.setVoiceProcessingEnabled(true)
                        input.isVoiceProcessingBypassed = false
                        input.isVoiceProcessingAGCEnabled = true
                        input.voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
                        microphoneUsesNative = input.isVoiceProcessingEnabled
                    } catch { info["microphone_degraded"] = true }
                }
                try selectAudioDevice(uid:config.microphoneDeviceUID,input:true,node:input)
                let format = input.outputFormat(forBus: 0)
                guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptionError.message("麦克风没有有效音频格式") }
                info["microphone_channel_mode"] = "mono-average"
                info["microphone_sample_rate"] = format.sampleRate
                info["microphone_channels"] = format.channelCount
                info["microphone_requested_tap_frames"] = 1024
                let ring = microphoneRing
                input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, time in
                    var description = buffer.format.streamDescription.pointee
                    _ = lc_ring_write(ring, buffer.audioBufferList, &description, buffer.frameLength, time.hostTime)
                }
                hasMicrophoneTap = true
                info["microphone_processor"] = microphoneUsesNative ? "apple-voice-processing" : (config.microphoneVoiceProcessing ? "webrtc-ns-fallback" : "bypass")
                info["microphone_aec"] = microphoneUsesNative
                info["microphone_agc"] = microphoneUsesNative
            }
            try selectAudioDevice(uid:config.outputDeviceUID,input:false,node:engine.outputNode)
            engine.prepare(); try engine.start()
            if config.systemAudioEnabled {
                let capture = SystemCapture(ring: systemRing); system = capture
                let roots = NSRunningApplication.runningApplications(withBundleIdentifier:config.applicationBundleID).map(\.processIdentifier)
                try await capture.start(bundleID: config.applicationBundleID, onlyPID: onlySystemPID, rootPIDs:roots)
            }
            return info
        } catch { await stop(); throw error }
    }
    func play(_ data: Data, rate: Double) -> Bool {
        guard playbackEnabled else { return true }
        guard rate == 24000, data.count % 2 == 0, engine.isRunning else { return false }
        guard queuedSeconds+Double(data.count/2)/rate <= catchUp.configuration.maximumBufferedSeconds else {
            playbackEvent?("playback.overflow",["queued_media_seconds":queuedSeconds,"incoming_media_seconds":Double(data.count/2)/rate,"limit_seconds":catchUp.configuration.maximumBufferedSeconds]);return false
        }
        let count = data.count / 2
        guard count > 0 else { return true }
        let format = AVAudioFormat(standardFormatWithSampleRate:rate,channels:1)!
        // Completion accounting is bounded to 100 ms of source PCM, even when the server sends a large burst.
        // Validate every allocation before scheduling any of this message.
        var buffers:[AVAudioPCMBuffer] = []
        for offset in stride(from:0,to:count,by:2400) {
            let n = min(2400,count-offset)
            guard let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(n)),let samples=buffer.floatChannelData?[0] else { return false }
            buffer.frameLength=AVAudioFrameCount(n)
            data.withUnsafeBytes { bytes in
                for i in 0..<n { samples[i]=Float(Int16(littleEndian:bytes.loadUnaligned(fromByteOffset:(offset+i)*2,as:Int16.self)))/32768 }
            }
            buffers.append(buffer)
        }
        let seconds = Double(count)/rate; queuedSeconds += seconds
        playbackScheduledSamples += count
        scheduledBuffers += 1
        let bufferID = UUID().uuidString
        playbackEvent?("playback.scheduled",["buffer_id":bufferID,"duration_ms":seconds*1000,"scheduled_at":SessionLog.timestamp()])
        let generation = playbackGeneration
        for (index,buffer) in buffers.enumerated() {
            let samples=Int(buffer.frameLength),isLast=index == buffers.count-1
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor in
                    guard let self, generation == self.playbackGeneration else { return }
                    self.playbackCompletedSamples += samples
                    self.queuedSeconds = max(0,Double(self.playbackScheduledSamples-self.playbackCompletedSamples)/rate)
                    if isLast {
                        self.completedBuffers += 1
                        self.playbackEvent?("playback.completed",["buffer_id":bufferID,"playback_completed_at":SessionLog.timestamp()])
                    }
                }
            }
        }
        if !player.isPlaying { player.play() }
        if playbackControlTask == nil {
            lastControlUptime=ProcessInfo.processInfo.systemUptime
            playbackControlTask=Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds:100_000_000)
                    guard !Task.isCancelled,let self else { return }
                    self.updatePlaybackRate()
                    if self.queuedSeconds == 0 { self.playbackControlTask=nil;return }
                }
            }
        }
        return true
    }
    private func updatePlaybackRate() {
        let now=ProcessInfo.processInfo.systemUptime,previousState=catchUp.catchingUp
        let elapsed=max(0,now-lastControlUptime)
        let speed=catchUp.update(queuedSeconds:queuedSeconds,elapsedSeconds:elapsed)
        lastControlUptime=now;timePitch.rate=Float(speed)
        if now-lastPlaybackReport>=1 || speed != lastReportedRate || previousState != catchUp.catchingUp {
            lastPlaybackReport=now;lastReportedRate=speed
            let reason = !catchUp.configuration.enabled ? "disabled" : (queuedSeconds == 0 ? "queue_drained" : (previousState != catchUp.catchingUp ? (catchUp.catchingUp ? "crossed_enter_watermark" : "crossed_exit_watermark") : (catchUp.catchingUp ? "follow_queue_target" : "restore_normal_rate")))
            playbackEvent?("playback.catch_up",["state":catchUp.catchingUp ? "catching_up" : (speed>1 ? "returning_to_normal" : "normal"),"reason":reason,
                "rate":Double(timePitch.rate),"requested_rate":speed,"target_rate":catchUp.targetRate,"control_uptime_seconds":now,"control_elapsed_seconds":elapsed,
                "queued_media_seconds":queuedSeconds,"scheduled_samples":playbackScheduledSamples,"completed_samples":playbackCompletedSamples,
                "maximum_rate":catchUp.configuration.maximumRate,"enter_seconds":catchUp.configuration.enterSeconds,"exit_seconds":catchUp.configuration.exitSeconds,
                "queue_measurement":"uncompleted_100ms_PCM_blocks; includes render pipeline, not microphone-to-speaker latency","preserve_pitch":true,"generation":playbackGeneration])
        }
    }
    func clearPlayback() {
        let discarded = queuedSeconds
        playbackGeneration += 1; player.stop(); queuedSeconds = 0
        timePitch.auAudioUnit.reset()
        playbackControlTask?.cancel();playbackControlTask=nil
        catchUp.reset();timePitch.rate=1;playbackScheduledSamples=0;playbackCompletedSamples=0
        lastControlUptime=0;lastPlaybackReport=0;lastReportedRate=1
        if discarded>0 { playbackEvent?("playback.cleared",["discarded_audio_ms":discarded*1000]) }
    }
    func stop() async {
        playbackEnabled = false
        if let system { await system.stop() }; system = nil
        if hasMicrophoneTap { engine.inputNode.removeTap(onBus: 0); hasMicrophoneTap = false }
        clearPlayback(); engine.stop(); microphoneUsesNative = false
    }
}
