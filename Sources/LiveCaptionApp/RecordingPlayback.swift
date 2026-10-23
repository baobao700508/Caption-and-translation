import AppKit
import AVFoundation
import UniformTypeIdentifiers
import LiveCaptionCore

enum RecordingTrack: String, CaseIterable, Identifiable {
    case uploaded, translated, system = "system-before-ns", microphone = "microphone-input", capturedMicrophone = "microphone-captured"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .uploaded: "送入模型的音频"
        case .translated: "模型返回的译音"
        case .system: "系统声 · 降噪前"
        case .microphone: "麦克风 · 对齐后输入"
        case .capturedMicrophone: "麦克风 · 采集原片（Apple 处理后）"
        }
    }
}

extension AppSession {
    func recordingURL(_ track: RecordingTrack) -> URL? {
        currentDirectory?.appendingPathComponent("audio").appendingPathComponent(track.rawValue + ".wav")
    }
    func hasRecording(_ track: RecordingTrack) -> Bool {
        guard let url = recordingURL(track), let size = try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize else { return false }
        return size > 44
    }
    func playRecording(_ track: RecordingTrack) {
        guard !running, !busy, hasRecording(track), let url = recordingURL(track) else { return }
        stopRecordingPlayback()
        do {
            let player = try AVAudioPlayer(contentsOf:url)
            player.volume = 1; player.numberOfLoops = 0
            guard player.prepareToPlay(), player.play() else { throw CaptionError.message("无法播放保存的 WAV") }
            recordingPlayer = player; recordingPlayback = track.rawValue
            recordingPlaybackTask = Task { [weak self, weak player] in
                while !Task.isCancelled, player?.isPlaying == true {
                    try? await Task.sleep(nanoseconds:200_000_000)
                }
                guard !Task.isCancelled else { return }; self?.stopRecordingPlayback()
            }
        } catch { errorMessage = "录音回听失败：" + config.redacted(error.localizedDescription) }
    }
    func stopRecordingPlayback() {
        recordingPlaybackTask?.cancel(); recordingPlaybackTask = nil
        recordingPlayer?.stop(); recordingPlayer = nil; recordingPlayback = nil
    }
    func endAndListen() async {
        await stop()
        guard hasRecording(.uploaded) else {
            if !hasRecording(.uploaded) { errorMessage = "本次会话没有保存的上传音频；请用新版开始一次记录后回听。" }
            return
        }
        playRecording(.uploaded)
    }
    func chooseAudioSession() {
        guard !running && !busy else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.wav]
        panel.message = "选择历史会话 audio 文件夹里的 uploaded.wav"
        panel.directoryURL = URL(fileURLWithPath:(config.logDirectory as NSString).expandingTildeInPath)
        guard panel.runModal() == .OK, let url = panel.url,
              url.lastPathComponent == "uploaded.wav", url.deletingLastPathComponent().lastPathComponent == "audio" else { return }
        stopRecordingPlayback()
        currentDirectory = url.deletingLastPathComponent().deletingLastPathComponent()
        playRecording(.uploaded)
    }
    func revealAudio() {
        guard let directory = currentDirectory?.appendingPathComponent("audio"), FileManager.default.fileExists(atPath:directory.path) else {
            announce("本次会话尚无录音；新版开始记录后自动保存"); return
        }
        NSWorkspace.shared.open(directory)
    }
}
