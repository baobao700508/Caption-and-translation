import Foundation
import AVFoundation
import LiveCaptionCore

/// A steady connection: no mode switches, microphone or user application audio.
@MainActor enum LatencySmoke {
    static func run(fixture:String, output:String, configurationPath:String, speech:Bool, session:AppSession) async {
        let original = session.config
        session.verificationInProgress = true
        defer { session.verificationInProgress = false; session.config = original; session.testOnlySystemPID = nil }
        let player = Process(); player.executableURL = URL(fileURLWithPath:"/usr/bin/afplay"); player.arguments = [fixture]
        var result:[String:Any] = ["scope":"固定公开测试音频、指定进程系统采集、单连接持续发送；记录采集估算时间、前处理完成、发送起止与首条文字接收。不是词级对齐延迟或真实课堂质量验收。","tested_at":SessionLog.timestamp(),"mode":speech ? "speech" : "subtitles"]
        do {
            session.config = try await Task.detached { try Configuration.load(from:URL(fileURLWithPath:configurationPath)) }.value
            session.config.pipeline = .translate; session.config.translationMode = speech ? .speech : .subtitles
            session.config.systemAudioEnabled = true; session.config.microphoneEnabled = false
            session.config.systemNoiseSuppression = true; session.config.applicationBundleID = ""
            session.config.logDirectory = URL(fileURLWithPath:output).deletingLastPathComponent().appendingPathComponent("latency-logs").path
            session.configurationReady = true
            try player.run(); try await Task.sleep(nanoseconds:800_000_000)
            session.testOnlySystemPID = player.processIdentifier
            await session.start(persistSettings:false)
            guard session.running, !session.busy, let directory = session.currentDirectory else { throw CaptionError.message(session.errorMessage ?? "采集未开始") }
            result["log_path"] = directory.path
            try await Task.sleep(nanoseconds:40_000_000_000)
            result["source_subtitle"] = session.sourceText; result["translated_subtitle"] = session.translatedText
            result["speech_scheduled_buffers"] = session.hardware.scheduledBuffers
            result["speech_completed_buffers"] = session.hardware.completedBuffers
            await session.stop()
            let uploaded = try AVAudioFile(forReading:directory.appendingPathComponent("audio/uploaded.wav"))
            result["audio_samples"] = uploaded.length
            result["success"] = uploaded.length > 16000 && session.lastCaptionAt != nil && session.errorMessage == nil
            result["error"] = session.errorMessage as Any? ?? NSNull()
        } catch {
            if session.running { await session.stop() }
            result["success"] = false; result["error"] = session.config.redacted(error.localizedDescription)
        }
        if player.isRunning { player.terminate() }
        let evidence = result
        await Task.detached {
            let url = URL(fileURLWithPath:output)
            try? FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
            try? JSONSerialization.data(withJSONObject:evidence,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.atomic)
        }.value
    }
}
