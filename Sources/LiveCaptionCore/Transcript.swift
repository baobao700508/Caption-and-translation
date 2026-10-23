import Foundation

public enum TextFinality: String, Codable, Sendable { case interim, final, unconfirmed, unspecified }
public struct TextUpdate: Sendable {
    public var speakerID: Int?
    public var sourceProviderID: String?
    public var providerID: String?
    public var track: String
    public var text: String
    public var replace: Bool
    public var finality: TextFinality
    public var boundary: Bool
    public var start: Double?
    public var end: Double?
    public init(track: String, text: String, replace: Bool, finality: TextFinality = .unspecified, boundary: Bool = false, start: Double? = nil, end: Double? = nil, providerID: String? = nil, sourceProviderID: String? = nil, speakerID: Int? = nil) {
        self.speakerID = speakerID
        self.sourceProviderID = sourceProviderID
        self.providerID = providerID; self.track = track; self.text = text; self.replace = replace; self.finality = finality; self.boundary = boundary; self.start = start; self.end = end
    }
}
public struct Segment: Codable, Sendable {
    public var speakerID: Int?
    public var providerID: String?
    public var sourceProviderID: String?
    public var id: String
    public var epoch: Int
    public var track: String
    public var text: String
    public var revision: Int
    public var finality: TextFinality
    public var receivedAt: Date
    public var closed: Bool
    public var audioStart: Double?
    public var audioEnd: Double?
    public var pipeline: Pipeline
}
public struct Transcript: Sendable {
    public private(set) var segments: [Segment] = []
    private var current: [String: Int] = [:]
    private var identified: [String: Int] = [:]
    public init() {}
    public mutating func apply(_ update: TextUpdate, epoch: Int, pipeline: Pipeline, now: Date = Date()) -> Segment? {
        let key = "\(epoch):\(update.track)" + (update.providerID.map { ":"+$0 } ?? "")
        guard !update.text.isEmpty || (update.replace && identified[key] != nil) else { return nil }
        let index: Int
        if let existing = identified[key] ?? current[key] { index = existing; if !segments[index].closed { current[key] = index } }
        else {
            index = segments.count; current[key] = index
            if update.providerID != nil { identified[key] = index }
            segments.append(Segment(id: UUID().uuidString, epoch: epoch, track: update.track, text: "", revision: 0, finality: .unspecified, receivedAt: now, closed: false, pipeline: pipeline))
        }
        segments[index].text = update.replace ? update.text : segments[index].text + update.text
        segments[index].revision += 1
        segments[index].finality = update.finality
        segments[index].receivedAt = now
        segments[index].audioStart = update.start ?? segments[index].audioStart
        segments[index].audioEnd = update.end ?? segments[index].audioEnd
        segments[index].sourceProviderID = update.sourceProviderID ?? segments[index].sourceProviderID
        segments[index].speakerID = update.speakerID ?? segments[index].speakerID
        segments[index].providerID = update.providerID ?? segments[index].providerID
        if update.boundary { segments[index].closed = true; current.removeValue(forKey: key) }
        return segments[index]
    }
    public mutating func close(epoch: Int, providerBoundary: Bool) -> [Segment] {
        let keys = current.keys.filter { $0.hasPrefix("\(epoch):") }
        var result: [Segment] = []
        for key in keys {
            guard let i = current.removeValue(forKey: key) else { continue }
            segments[i].closed = true
            if segments[i].finality == .interim { segments[i].finality = .unconfirmed }
            result.append(segments[i])
        }
        return result
    }
    public func recentText(track: String, epoch: Int? = nil, limit: Int = 1000) -> String {
        let visible = segments.filter { $0.track == track && (epoch == nil || $0.epoch == epoch) }.suffix(6)
        return String(visible.map(\.text).joined(separator: "\n").suffix(limit))
    }
}

public enum ProviderEvent {
    case diagnostic(String,[String:Any])
    case ready
    case finished
    case text(TextUpdate)
    case audio(Data, sampleRate: Double)
    case boundary
    case resumption(String)
    case goAway
    case usage([String: Any])
    case error(String)
}

public enum GoogleProtocol {
    public static func events(from data: Data, pipeline: Pipeline) throws -> [ProviderEvent] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var events: [ProviderEvent] = []
        if let error = root["error"] as? [String: Any] { return [.error(error["message"] as? String ?? "Google 返回错误")] }
        if root["setupComplete"] != nil { events.append(.ready) }
        if let resume = root["sessionResumptionUpdate"] as? [String: Any], let handle = resume["newHandle"] as? String, resume["resumable"] as? Bool != false { events.append(.resumption(handle)) }
        if root["goAway"] != nil { events.append(.goAway) }
        if let usage = root["usageMetadata"] as? [String: Any] { events.append(.usage(usage)) }
        guard let content = root["serverContent"] as? [String: Any] else { return events }
        func emit(_ name: String, track: String, replace: Bool, finality: TextFinality, boundary: Bool, useFinished: Bool = true) {
            guard let item = content[name] as? [String: Any], let text = item["text"] as? String else { return }
            let finished = useFinished && (item["finished"] as? Bool == true)
            events.append(.text(TextUpdate(track: track, text: text, replace: replace, finality: finality, boundary: boundary || finished,
                                          start: seconds(item["startOffset"]), end: seconds(item["endOffset"]))))
        }
        if pipeline == .transcribe {
            emit("interimInputTranscription", track: "source", replace: true, finality: .interim, boundary: false, useFinished: false)
            emit("inputTranscription", track: "source", replace: true, finality: .final, boundary: true)
        } else {
            emit("inputTranscription", track: "source", replace: false, finality: .unspecified, boundary: false)
            emit("outputTranscription", track: "translation", replace: false, finality: .unspecified, boundary: false)
            if let turn = content["modelTurn"] as? [String: Any], let parts = turn["parts"] as? [[String: Any]] {
                for part in parts {
                    guard let inline = part["inlineData"] as? [String: Any], let mime = inline["mimeType"] as? String,
                          mime.hasPrefix("audio/pcm"), let encoded = inline["data"] as? String, let bytes = Data(base64Encoded: encoded) else { continue }
                    let rate = mime.components(separatedBy: "rate=").last.flatMap(Double.init) ?? 24000
                    events.append(.audio(bytes, sampleRate: rate))
                }
            }
        }
        if content["turnComplete"] as? Bool == true { events.append(.boundary) }
        return events
    }
    private static func seconds(_ value: Any?) -> Double? {
        if let s = value as? String, s.hasSuffix("s") { return Double(s.dropLast()).map { $0 * 1000 } }
        return nil
    }
    public static func audioMessage(_ pcm: Data) -> [String: Any] {
        ["realtimeInput": ["audio": ["data": pcm.base64EncodedString(), "mimeType": "audio/pcm;rate=16000"]]]
    }
}
