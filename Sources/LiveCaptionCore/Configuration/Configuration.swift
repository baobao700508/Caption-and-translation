import Foundation

public struct Configuration: Codable, Sendable {
    /// Legacy Google credential; never used for Bailian.
    public var apiKey = ""
    public var translateProvider: TranslationProvider = .bailian
    public var bailianAPIKey = ""
    public var bailianWorkspaceID = ""
    public var bailianRegion: BailianRegion = .singapore
    public var bailianTranslateModel = "qwen3.8-livetranslate-flash-realtime"
    public var bailianTurnDetection: BailianTurnDetection = .automatic
    public var bailianTransport: BailianTransport = .webrtc
    public var playbackCatchUp = PlaybackCatchUpConfiguration()
    public var logDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/LiveCaption Logs").path
    public var pipeline: Pipeline = .transcribe
    public var translationMode: OutputMode = .subtitles
    public var subtitleLayout: SubtitleLayout = .bilingual
    public var targetLanguage = "zh-Hans"
    public var languageHints: [String] = []
    public var systemAudioEnabled = true
    public var microphoneEnabled = false
    public var systemNoiseSuppression = true
    public var microphoneVoiceProcessing = true
    public var applicationBundleID = ""
    public var microphoneDeviceUID = ""
    public var outputDeviceUID = ""
    public var systemChannelMode: ChannelSelection = .auto
    public var transcribeProvider: TranscriptionProvider = .google
    public var localWhisper = LocalWhisperConfiguration()
    public var transcribeModel = "gemini-3.5-transcribe-live"
    public var translateModel = "gemini-3.5-live-translate-preview"
    public var captionReflow = CaptionReflowConfiguration()
    public init() {}
    public var provider: TranslationProvider { pipeline == .translate ? translateProvider : (transcribeProvider == .whisperKit ? .whisperKit : .google) }
    public var providerName: String { provider == .whisperKit ? "本地 Whisper · GPU" : (provider == .bailian ? "阿里云百炼" : "Google") }
    public var activeAPIKey: String { provider == .whisperKit ? "" : (provider == .bailian ? bailianAPIKey : apiKey) }
    public var resolvedBailianTurnDetection:BailianTurnDetection { bailianTurnDetection.resolved(for:translationMode) }
    public var model: String { pipeline == .transcribe ? (transcribeProvider == .whisperKit ? localWhisper.model : transcribeModel) : (provider == .bailian ? bailianTranslateModel : translateModel) }
    /// LiveTranslate publishes no verified wall-clock connection deadline in its current contract.
    /// Do not reset a classroom's context every nine minutes based on a different provider's policy.
    public var scheduledConnectionRotationSeconds: TimeInterval? { provider == .google ? 540 : nil }
    public func redacted(_ message: String) -> String {
        [apiKey,bailianAPIKey].filter { !$0.isEmpty }.reduce(message) { $0.replacingOccurrences(of:$1,with:"[redacted]") }
    }
    public var bailianURL: URL {
        var parts = URLComponents()
        parts.scheme = "wss"
        parts.host = "\(bailianWorkspaceID).\(bailianRegion.endpointRegion).maas.aliyuncs.com"
        parts.path = "/api-ws/v1/realtime"
        parts.queryItems = [URLQueryItem(name:"model",value:bailianTranslateModel)]
        return parts.url!
    }
    public var inputKind: String { systemAudioEnabled ? (microphoneEnabled ? "mixed" : (applicationBundleID.isEmpty ? "system" : "application")) : "microphone" }
    public static var desktopURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/LiveCaption配置.json") }
    public static func load(from url: URL = desktopURL) throws -> Configuration {
        try decode(Data(contentsOf:url))
    }
    public static func decode(_ data: Data) throws -> Configuration {
        guard let supplied = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CaptionError.message("配置必须是 JSON 对象") }
        var merged = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Configuration())) as! [String: Any]
        supplied.forEach { key,value in
            if (key == "localWhisper" || key == "playbackCatchUp"),let partial=value as? [String:Any],let defaults=merged[key] as? [String:Any] {
                merged[key]=defaults.merging(partial) { _,new in new }
            } else { merged[key]=value }
        }
        var result = try JSONDecoder().decode(Configuration.self, from: JSONSerialization.data(withJSONObject: merged))
        result.apiKey = result.apiKey.trimmingCharacters(in:.whitespacesAndNewlines)
        result.bailianAPIKey = result.bailianAPIKey.trimmingCharacters(in:.whitespacesAndNewlines)
        result.bailianWorkspaceID = result.bailianWorkspaceID.trimmingCharacters(in:.whitespacesAndNewlines)
        // Existing Google configurations keep their routing until explicitly migrated.
        if supplied["translateProvider"] == nil { result.translateProvider = .google }
        return result
    }
    public func validate(requireKey: Bool = true) throws {
        if pipeline == .translate && translationMode == .subtitles && translateProvider == .google {
            throw CaptionError.message("Google 当前翻译线路会生成译音，不支持仅文字；为避免生成后丢弃译音，请将 translateProvider 设为 bailian 使用书面同译，或选择同声传译。")
        }
        if requireKey && provider != .whisperKit && (activeAPIKey.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || activeAPIKey.contains("YOUR_")) {
            throw CaptionError.message(provider == .bailian ? "请填写桌面配置的 bailianAPIKey（对应地区的百炼 API Key）" : "请填写桌面配置的 apiKey（Google）")
        }
        if translateProvider == .whisperKit { throw CaptionError.message("本地 Whisper 仅用于原文转写，请从原文转写的识别方式中选择") }
        if provider == .whisperKit { try localWhisper.validate() }
        if provider == .bailian {
            guard !bailianWorkspaceID.isEmpty, !bailianWorkspaceID.contains("YOUR_"),
                  bailianWorkspaceID.range(of:"^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$",options:.regularExpression) != nil else {
                throw CaptionError.message("请填写百炼工作空间 ID：bailianWorkspaceID")
            }
            guard bailianTranslateModel == "qwen3.8-livetranslate-flash-realtime" else { throw CaptionError.message("百炼适配器当前支持 qwen3.8-livetranslate-flash-realtime") }
        }
        guard systemAudioEnabled || microphoneEnabled else { throw CaptionError.message("至少选择一个音源") }
        try playbackCatchUp.validate()
        guard logDirectory.hasPrefix("/") || logDirectory.hasPrefix("~/") else { throw CaptionError.message("logDirectory 必须是绝对路径或 ~/ 路径") }
        guard !model.isEmpty else { throw CaptionError.message("模型名称不能为空") }
    }
    public func setup(resumptionHandle: String? = nil) -> [String: Any] {
        var generation: [String: Any] = ["responseModalities": [pipeline == .transcribe ? "TEXT" : "AUDIO"]]
        var setup: [String: Any] = ["model": "models/\(model)"]
        if pipeline == .transcribe {
            setup["inputAudioTranscription"] = ["mode": "VERBATIM", "languageCodes": languageHints]
        } else {
            setup["inputAudioTranscription"] = [String: String]()
            setup["outputAudioTranscription"] = [String: String]()
            generation["translationConfig"] = ["targetLanguageCode": targetLanguage, "echoTargetLanguage": false]
        }
        setup["generationConfig"] = generation
        if let handle = resumptionHandle { setup["sessionResumption"] = ["handle": handle] }
        else if pipeline == .translate { setup["sessionResumption"] = [String: String]() }
        return ["setup": setup]
    }
    public var safeMetadata: [String: Any] {
        ["provider": provider.rawValue, "provider_region": provider == .whisperKit ? "local" : (provider == .bailian ? bailianRegion.rawValue : "google"), "model": model, "pipeline": pipeline.rawValue, "mode": pipeline == .transcribe ? "transcript" : translationMode.rawValue,
         "input_kind": inputKind, "target_language": targetLanguage, "bailian_turn_detection":resolvedBailianTurnDetection.rawValue,
         "bailian_turn_detection_policy":bailianTurnDetection.rawValue, "transport":provider == .bailian ? bailianTransport.rawValue : (provider == .whisperKit ? "local" : "websocket"),
         "caption_reflow_enabled":captionReflow.enabled,"caption_reflow_engine":captionReflow.engine.rawValue,"caption_reflow_model":captionReflow.activeModel,"caption_sat_threshold":captionReflow.sat.paragraphThreshold,"caption_sat_minimum_characters":captionReflow.sat.minimumCharacters,
         "playback_catch_up_enabled":playbackCatchUp.enabled,"playback_maximum_rate":playbackCatchUp.maximumRate,"system_ns_requested": systemNoiseSuppression,
         "microphone_vp_requested": microphoneVoiceProcessing, "microphone_device_uid": microphoneDeviceUID, "output_device_uid": outputDeviceUID, "system_channel_mode":systemChannelMode.rawValue]
    }
}
