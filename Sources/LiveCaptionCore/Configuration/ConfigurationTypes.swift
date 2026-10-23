import Foundation

public enum TranslationProvider: String, Codable, Sendable { case google, bailian, whisperKit }
public enum BailianRegion: String, Codable, Sendable { case singapore, beijing
    public var endpointRegion: String { self == .singapore ? "ap-southeast-1" : "cn-beijing" }
}
public enum Pipeline: String, Codable, CaseIterable, Sendable { case transcribe, translate }
public enum OutputMode: String, Codable, CaseIterable, Sendable { case subtitles, speech }
public enum BailianTransport: String, Codable, Sendable {
    case webrtc, websocket
    public func make(audioArchive:AudioArchive? = nil,epoch:Int = 0) -> any RealtimeTransport {
        switch self {
        case .websocket: return WebSocketTransport()
        case .webrtc: return BailianWebRTCTransport(audioArchive:audioArchive,epoch:epoch)
        }
    }
}
public enum BailianTurnDetection: String, Codable, CaseIterable, Sendable {
    case automatic = "auto", serverVAD = "server_vad", speakerDetection = "speaker_detection"
    public func resolved(for mode:OutputMode) -> BailianTurnDetection {
        // Both translation modes keep server VAD; speaker detection is explicit opt-in.
        self == .automatic ? .serverVAD : self
    }
    public func settings(for mode:OutputMode) -> [String:Any] {
        let detector=resolved(for:mode)
        return detector == .speakerDetection ? ["type":detector.rawValue,"threshold":0.5] : ["type":detector.rawValue]
    }
}
public enum SubtitleLayout: String, Codable, CaseIterable, Sendable { case source, translation, bilingual }
public enum ChannelSelection: String, Codable, CaseIterable, Sendable { case auto, left, right }
public enum CaptionError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}
