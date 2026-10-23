import Foundation
import AVFoundation
import AudioBridge
import LiveCaptionCore

private actor MicrophoneNotices {
    var messages:[String] = []
    func add(_ text:String) { messages.append(text) }
    func result() -> [String] { messages }
}

/// One short local capture, without cloud traffic or speaker output.
@MainActor enum MicrophoneSmoke {
    static func run(output:String, rawComparison:Bool = false, session:AppSession) async {
        session.verificationInProgress = true; session.busy = true
        session.status = "本机麦克风校验中"
        session.sourceText = "正在短暂检查麦克风采集时序，仅在本机保存；不调用模型、不播放声音。"
        defer { session.verificationInProgress = false; session.busy = false }
        var config = session.config; config.systemAudioEnabled = false; config.microphoneEnabled = true
        let root = URL(fileURLWithPath:output).deletingLastPathComponent().appendingPathComponent("local-microphone")
        var report:[String:Any] = ["tested_at":SessionLog.timestamp(),"scope":"单次六秒本机麦克风采集，Apple VP→直接采集轨→时间轴→16kHz处理轨；没有云端发送和播放，不代表远场音质验收"]
        var frontend:AudioFrontend?; var worker:Task<Void,Never>?; var archive:AudioArchive?
        let notices = MicrophoneNotices()
        var rawProbe:RawMicrophoneProbe?
        do {
            let recorder = try AudioArchive(sessionDirectory:root); archive = recorder
            if rawComparison {
                guard await AVCaptureDevice.requestAccess(for:.audio) else { throw CaptionError.message("麦克风权限未获准") }
                let probe = RawMicrophoneProbe();rawProbe = probe
            }
            lc_ring_set_diagnostics(session.hardware.microphoneRing,1)
            let processing = try await session.hardware.start(config)
            report["processing"] = processing
            let front = AudioFrontend(systemRing:session.hardware.systemRing,microphoneRing:session.hardware.microphoneRing,
                config:config,nativeMic:session.hardware.microphoneUsesNative,archive:recorder,
                notice:{ text in Task { await notices.add(text) } },meter:{ _,_ in })
            if let rawProbe {
                // Voice Processing reconfigures I/O; initialize the independent tap only afterward.
                report["unprocessed_input"] = try rawProbe.startDevice(config:config)
                try rawProbe.startRecording(config:config,root:root.deletingLastPathComponent().appendingPathComponent("unprocessed-device"))
                guard session.hardware.engine.isRunning else { throw CaptionError.message("并行原始输入启动后语音处理引擎停止，不能对照") }
            }
            frontend = front; try front.start()
            worker = Task {
                for await _ in front.packets.signals {
                    while let packet = front.packets.takeBatch() { try? recorder.localProcessed(packet.data) }
                }
            }
            try await Task.sleep(nanoseconds:6_000_000_000)
            let voiceEngineRunning = session.hardware.engine.isRunning
            if let rawProbe { report["unprocessed_audio_directory"] = try await rawProbe.stop()?.path as Any? ?? NSNull() }
            await session.hardware.stop(); front.stop(); await worker?.value
            guard voiceEngineRunning else { throw CaptionError.message("语音处理引擎中途停止，不能对照") }
            try recorder.finish()
            let observedChannels = lc_ring_capture_channels(session.hardware.microphoneRing)
            report["actual_callback_channels"] = observedChannels
            report["channel_rms"] = (0..<min(observedChannels,16)).map { lc_ring_capture_channel_rms(session.hardware.microphoneRing,$0) }
            report["legacy_average_rms"] = lc_ring_capture_legacy_rms(session.hardware.microphoneRing)
            lc_ring_set_diagnostics(session.hardware.microphoneRing,0)
            let direct = try AVAudioFile(forReading:recorder.directory.appendingPathComponent("microphone-captured.wav"))
            let aligned = try AVAudioFile(forReading:recorder.directory.appendingPathComponent("microphone-input.wav"))
            let processed = try AVAudioFile(forReading:recorder.directory.appendingPathComponent("processed-local.wav"))
            let messages = await notices.result()
            report["notices"] = messages
            report["direct_frames"] = direct.length; report["aligned_frames"] = aligned.length; report["processed_frames"] = processed.length
            report["audio_directory"] = recorder.directory.path
            report["success"] = direct.length > 48000 && abs(Double(direct.length-aligned.length)/48000) < 0.15 && abs(Double(aligned.length)/48000-Double(processed.length)/16000)<0.02 && !messages.contains { $0.contains("时间轴缺失") || $0.contains("异常") }
            session.status = report["success"] as? Bool == true ? "麦克风时序校验通过" : "麦克风时序校验未通过"
        } catch {
            await session.hardware.stop(); frontend?.stop(); await worker?.value; _ = try? await rawProbe?.stop(); try? archive?.finish()
            report["success"] = false; report["error"] = error.localizedDescription
            session.status = "麦克风时序校验未通过"
        }
        let url = URL(fileURLWithPath:output)
        try? FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.atomic)
    }
}
