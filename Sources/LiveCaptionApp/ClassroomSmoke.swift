import Foundation
import AVFoundation
import LiveCaptionCore

@MainActor enum ClassroomSmoke {
    static func run(fixture: String, output: String, pipeline: Pipeline, configurationPath: String? = nil, exerciseSwitches: Bool = false, session: AppSession) async {
        if let path = configurationPath {
            do { session.config = try await Task.detached { try Configuration.load(from:URL(fileURLWithPath:path)) }.value; session.configurationReady = true }
            catch { session.configurationReady = false; session.errorMessage = "验证配置读取失败" }
        } else { await session.reloadConfiguration() }
        let original = session.config
        session.verificationInProgress = true
        defer { session.verificationInProgress = false; session.config = original }
        let player = Process(); player.executableURL = URL(fileURLWithPath:"/usr/bin/afplay"); player.arguments=[fixture]
        var result: [String: Any] = ["tested_at":SessionLog.timestamp(),"pipeline":pipeline.rawValue,
            "scope":"真实指定播放器→CoreAudio tap→WebRTC NS→所选云模型→字幕状态→活动课堂日志追读；不代表60分钟稳定性或扬声器AEC"]
        do {
            session.config.pipeline = pipeline
            try session.config.validate()
            result["provider"] = session.config.provider.rawValue
            result["model"] = session.config.model
            try player.run(); try await Task.sleep(nanoseconds:800_000_000)
            session.testOnlySystemPID = player.processIdentifier
            session.config.pipeline = pipeline; session.config.microphoneEnabled = false; session.config.systemAudioEnabled = true
            session.config.systemNoiseSuppression = true; session.config.applicationBundleID = ""; session.config.translationMode = .subtitles
            session.config.logDirectory = URL(fileURLWithPath:output).deletingLastPathComponent().appendingPathComponent("classroom-fixture-logs/\(pipeline.rawValue)").path
            await session.start(persistSettings:false)
            guard session.running, !session.busy, let directory = session.currentDirectory else { throw CaptionError.message(session.errorMessage ?? "未进入活动会话") }
            try await Task.sleep(nanoseconds:6_000_000_000)
            session.collapseSubtitles()
            let miniPass = session.running && session.presentation == .compact && session.overlay?.isInteractive == true
            session.showSettings(.records)
            let settingsPass = session.preferencesWindow?.isVisible == true && session.running
            result["mini_kept_session_running"] = miniPass
            result["settings_opened_while_recording"] = settingsPass
            session.preferencesWindow?.close()
            let hiddenAt = SessionLog.timestamp()
            session.overlay?.hide()
            if pipeline == .translate { await session.changeMode(.speech) }
            try await Task.sleep(nanoseconds:6_000_000_000)
            let (partial, midJournal) = try await Task.detached { (try String(contentsOf:directory.appendingPathComponent("live.md")),try String(contentsOf:directory.appendingPathComponent("events.jsonl"))) }.value
            let source = session.sourceText
            let translated = session.translatedText
            let hasSource = !source.isEmpty && !source.contains("等待") && !source.contains("选择音源")
            let hasTranslation = pipeline == .transcribe || (!translated.isEmpty && !translated.contains("等待"))
            let freshText = midJournal.split(separator:"\n").contains { line in
                guard let row = try? JSONSerialization.jsonObject(with:Data(line.utf8)) as? [String:Any],
                      let kind = row["event_type"] as? String, kind.hasPrefix("text."), let at = row["received_at"] as? String else { return false }
                return at>hiddenAt
            }
            let midClassReadable = partial.contains("活动：true") && !partial.isEmpty && hasSource && freshText
            result["source_subtitle"] = source; result["translated_subtitle"] = translated
            result["mid_class_log_readable"] = midClassReadable; result["log_path"] = directory.path
            result["hidden_overlay_log_readable"] = midClassReadable
            let playbackPass = pipeline == .transcribe ? session.hardware.scheduledBuffers == 0 : (session.hardware.scheduledBuffers>0 && session.hardware.completedBuffers>0)
            result["scheduled_speech_buffers"] = session.hardware.scheduledBuffers
            result["completed_speech_buffers"] = session.hardware.completedBuffers
            if pipeline == .translate { await session.changeMode(.subtitles) }
            result["speech_stopped_on_subtitles"] = !session.hardware.playbackIsActive && session.hardware.pendingPlaybackSeconds == 0
            session.overlay?.show()
            try await Task.sleep(nanoseconds:3_000_000_000)
            var switchPass = true
            if exerciseSwitches {
                let sessionID = directory.lastPathComponent
                await session.changePipeline(.translate)
                try await Task.sleep(nanoseconds:8_000_000_000)
                let translatedLive = !session.translatedText.isEmpty && !session.translatedText.contains("等待")
                await session.changePipeline(.transcribe)
                try await Task.sleep(nanoseconds:5_000_000_000)
                let transcribedLive = !session.sourceText.isEmpty && !session.sourceText.contains("等待")
                let validModel = session.config.translateProvider == .bailian ? session.config.bailianTranslateModel : session.config.translateModel
                if session.config.translateProvider == .bailian { session.config.bailianTranslateModel = "livecaption-deliberately-invalid-model" }
                else { session.config.translateModel = "livecaption-deliberately-invalid-model" }
                await session.changePipeline(.translate)
                let rejected = session.running && session.config.pipeline == .transcribe && session.errorMessage?.contains("切换失败") == true
                if session.config.translateProvider == .bailian { session.config.bailianTranslateModel = validModel }
                else { session.config.translateModel = validModel }
                session.errorMessage = nil
                try await Task.sleep(nanoseconds:4_000_000_000)
                switchPass = translatedLive && transcribedLive && rejected && session.currentDirectory?.lastPathComponent == sessionID
                result["live_pipeline_switch_passed"] = switchPass
                result["failed_switch_preserved_transcribe"] = rejected
            }
            await session.stop()
            let journal = try await Task.detached { try String(contentsOf:directory.appendingPathComponent("events.jsonl")) }.value
            let audio = directory.appendingPathComponent("audio")
            let uploaded = try AVAudioFile(forReading:audio.appendingPathComponent("uploaded.wav"))
            let rawInput = try AVAudioFile(forReading:audio.appendingPathComponent("system-before-ns.wav"))
            let index = try String(contentsOf:audio.appendingPathComponent("upload-index.jsonl")).split(separator:"\n").map { try JSONSerialization.jsonObject(with:Data($0.utf8)) as! [String:Any] }
            let frames = index.reduce(0) { $0 + ($1["sample_count"] as? Int ?? 0) }
            let archivePass = uploaded.length > 16000 && uploaded.processingFormat.sampleRate == 16000 && Int(uploaded.length) == frames && rawInput.length > 48000
            result["uploaded_wav_samples"] = uploaded.length
            result["input_comparison_samples"] = rawInput.length
            result["audio_archive_matches_index"] = archivePass
            session.playRecording(.uploaded)
            try await Task.sleep(nanoseconds:150_000_000)
            let replayPass = session.recordingPlayer?.isPlaying == true && session.recordingPlayback == RecordingTrack.uploaded.rawValue
            session.stopRecordingPlayback()
            result["saved_upload_playback_started"] = replayPass
            let processing = journal.contains("webrtc-apm-2.1-ns-low")
            result["system_ns_recorded"] = processing
            result["success"] = hasSource && hasTranslation && midClassReadable && processing && playbackPass && switchPass && miniPass && settingsPass && archivePass && replayPass && session.errorMessage == nil
            result["error"] = session.errorMessage as Any? ?? NSNull()
        } catch {
            if session.running { await session.stop() }
            result["success"] = false
            result["error"] = session.config.redacted(error.localizedDescription)
        }
        session.testOnlySystemPID = nil
        if player.isRunning { player.terminate() }
        let evidence = result
        await Task.detached {
            do { let url=URL(fileURLWithPath:output);try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true);try JSONSerialization.data(withJSONObject:evidence,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.atomic) }
            catch { }
        }.value
        session.status = result["success"] as? Bool == true ? "课堂端到端验证通过" : "课堂端到端验证未通过"
    }
}
