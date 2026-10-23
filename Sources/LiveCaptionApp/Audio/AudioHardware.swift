import Foundation
import AVFoundation
import AppKit
import CoreAudio
import AudioBridge
import LiveCaptionCore

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
