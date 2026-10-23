import Foundation

public enum TranscriptionProvider: String, Codable, CaseIterable, Sendable {
    case google, whisperKit
}

public struct LocalWhisperConfiguration: Codable, Sendable {
    public var model = "openai_whisper-large-v3-v20240930_turbo"
    public var language = "en"
    public var modelDirectory = ""
    public var updateIntervalSeconds: Double = 0.8
    public init() {}
    public var cacheDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LiveCaption/WhisperKit",isDirectory:true)
    }
    public func validate() throws {
        guard !model.isEmpty, !model.contains("/"), !model.contains("..") else { throw CaptionError.message("本地 Whisper 模型名称无效") }
        guard (0.4...3).contains(updateIntervalSeconds) else { throw CaptionError.message("本地识别更新间隔必须为 0.4–3 秒") }
        guard modelDirectory.isEmpty || modelDirectory.hasPrefix("/") || modelDirectory.hasPrefix("~/") else { throw CaptionError.message("本地模型目录须为绝对路径或 ~/ 路径") }
    }
}
