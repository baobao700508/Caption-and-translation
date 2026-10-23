import Foundation
import CoreFoundation

/// Qwen 3.8 protocol. In particular, 3.5 snapshot events must not be treated as 3.8 deltas.
public struct BailianProtocol {
    private var seen: Set<String> = []
    private var responses: [String: [String: String]] = [:]
    private var starts: [String:Double] = [:], ends: [String:Double] = [:]
    private var sourceItems: Set<String> = []
    private var sourceForTarget: [String:String] = [:]
    private var speakers: [String:Int] = [:]
    public init() {}
    public static func confirmedSession(_ root:[String:Any], configuration:Configuration) throws -> [String:Any] {
        guard let session = root["session"] as? [String:Any],
              session["model"] as? String == configuration.bailianTranslateModel,
              let translation = session["translation"] as? [String:Any],
              translation["language"] as? String == (configuration.targetLanguage.hasPrefix("zh") ? "zh" : configuration.targetLanguage),
              Set(session["output_modalities"] as? [String] ?? []) == Set(configuration.translationMode == .speech ? ["text","audio"] : ["text"]) else {
            throw CaptionError.message("百炼未确认所选模型、目标语言或输出模式，已停止发送音频")
        }
        let audio = session["audio"] as? [String:Any] ?? [:]
        let input = audio["input"] as? [String:Any] ?? [:]
        let format = input["format"] as? [String:Any]
        guard (format?["type"] as? String == "pcm" && format?["sample_rate"] as? Int == 16000) else {
            throw CaptionError.message("百炼未确认 16 kHz PCM 输入格式")
        }
        let detection = input["turn_detection"] as? [String:Any] ?? [:]
        guard detection["type"] as? String == configuration.resolvedBailianTurnDetection.rawValue,
              configuration.resolvedBailianTurnDetection != .speakerDetection || (detection["threshold"] as? Double) == 0.5 else {
            throw CaptionError.message("百炼未确认所选语段检测设置，已停止发送音频")
        }
        if configuration.translationMode == .speech {
            let output = audio["output"] as? [String:Any] ?? [:],format = output["format"] as? [String:Any]
            guard (format?["type"] as? String == "pcm" && format?["sample_rate"] as? Int == 24000) else { throw CaptionError.message("百炼未确认 24 kHz PCM 译音格式") }
            guard session["enable_voice_clone"] as? Bool == false,
                  (session["voice"] as? String ?? output["voice"] as? String) == "Tina" else {
                throw CaptionError.message("百炼未确认关闭声音复刻及默认 Tina 音色，已停止发送音频")
            }
        }
        var confirmed:[String:Any] = ["model":configuration.bailianTranslateModel,"target_language":translation["language"]!,"output_modalities":session["output_modalities"]!,"input_sample_rate":16000,"audio_output_requested":configuration.translationMode == .speech,"turn_detection":configuration.resolvedBailianTurnDetection.rawValue,
                "turn_detection_policy":configuration.bailianTurnDetection.rawValue]
        confirmed["requested_turn_detection"] = configuration.resolvedBailianTurnDetection.rawValue
        confirmed["server_turn_detection"] = detection.filter { ["type","threshold","silence_duration_ms","create_response","interrupt_response"].contains($0.key) }
        confirmed["turn_detection_confirmation_source"] = "session.updated"
        confirmed["turn_detection_configuration_matched"] = true
        if configuration.translationMode == .speech {
            confirmed["output_sample_rate"] = 24000
            confirmed["voice_clone_requested"] = false
            confirmed["requested_voice"] = "Tina"
            if let enabled = session["enable_voice_clone"] as? Bool { confirmed["server_enable_voice_clone"] = enabled }
            if let voice = session["voice"] as? String { confirmed["server_voice"] = voice }
            if let output=audio["output"] as? [String:Any],let voice=output["voice"] as? String {
                confirmed["server_audio_output_voice"] = voice
            }
            if let options = session["voice_clone_options"] as? [String:Any] { confirmed["server_voice_clone_options"] = options }
        }
        return confirmed
    }
    public static func setup(configuration: Configuration) -> [String: Any] {
        let language = configuration.targetLanguage.hasPrefix("zh") ? "zh" : configuration.targetLanguage
        var session:[String:Any] = [
            "output_modalities":configuration.translationMode == .speech ? ["text","audio"] : ["text"],
            "audio":["input":["turn_detection":configuration.bailianTurnDetection.settings(for:configuration.translationMode)] ],
            "translation":["language":language]
        ]
        if configuration.translationMode == .speech {
            session["enable_voice_clone"] = false
            session["voice"] = "Tina"
        }
        return ["type":"session.update", "session":session]
    }
    public static func audioMessage(_ pcm: Data) -> [String: Any] {
        ["type":"input_audio_buffer.append","audio":pcm.base64EncodedString()]
    }
    public mutating func events(from data: Data) throws -> [ProviderEvent] {
        guard let root = try JSONSerialization.jsonObject(with:data) as? [String:Any], let type = root["type"] as? String else { return [] }
        if let id = root["event_id"] as? String {
            if seen.contains(id) { return [] }
            if seen.count >= 4096 { seen.removeAll(keepingCapacity:true) }
            seen.insert(id)
        }
        switch type {
        case "_webrtc.stage", "_webrtc.stats", "_webrtc.input_gap", "_webrtc.input":
            return [.diagnostic(type.replacingOccurrences(of:"_webrtc.",with:"transport.webrtc_"),root.filter { $0.key != "type" })]
        case "_aoq.publish_format", "_aoq.stats":
            return [.diagnostic(type == "_aoq.stats" ? "transport.aoq_stats" : "audio.aoq_publish_format",root.filter { $0.key != "type" })]
        case "input_audio_buffer.speech_started", "input_audio_buffer.speech_stopped":
            guard let id = root["item_id"] as? String else { return [] }
            sourceItems.insert(id)
            if let start = root["audio_start_ms"] as? Double { starts[id] = start }
            if let end = root["audio_end_ms"] as? Double { ends[id] = end }
            if let value=root["speaker_id"] as? NSNumber,
               CFGetTypeID(value) != CFBooleanGetTypeID(),value.doubleValue == Double(value.intValue),value.intValue >= 0 {
                speakers[id] = value.intValue
            }
            var fields:[String:Any] = ["provider_segment_id":id]
            fields["speaker_id_present"] = root["speaker_id"] != nil
            if let speaker=speakers[id] { fields["speaker_id"] = speaker }
            if let start = starts[id] { fields["audio_start_ms"] = start }
            if let end = ends[id] { fields["audio_end_ms"] = end }
            return [.diagnostic(type,fields)]
        case "conversation.item.created":
            guard let item = root["item"] as? [String:Any],let id = item["id"] as? String else { return [] }
            if (item["content"] as? [[String:Any]] ?? []).contains(where: { $0["type"] as? String == "input_audio" }) { sourceItems.insert(id); return [] }
            if let previous = root["previous_item_id"] as? String,sourceItems.contains(previous) {
                sourceForTarget[id] = previous
                var fields:[String:Any] = ["provider_segment_id":id,"source_provider_segment_id":previous]
                if let speaker=speakers[previous] { fields["speaker_id"] = speaker }
                return [.diagnostic("provider.segment_link",fields)]
            }
            return []
        case "session.updated": return [.ready]
        case "session.finished": return [.finished]
        case "error", "conversation.item.input_audio_transcription.failed":
            let error = root["error"] as? [String:Any] ?? [:]
            return [.error("\(error["code"] as? String ?? "Bailian"): \(error["message"] as? String ?? "服务端返回错误")")]
        case "conversation.item.input_audio_transcription.delta", "conversation.item.input_audio_transcription.completed":
            guard let id = root["item_id"] as? String else { throw CaptionError.message("百炼原文缺少 item_id") }
            let done = type.hasSuffix(".completed")
            guard let text = root[done ? "transcript" : "delta"] as? String else { return [] }
            return [.text(TextUpdate(track:"source",text:text,replace:done,finality:done ? .final : .interim,boundary:done,start:starts[id],end:ends[id],providerID:id,speakerID:speakers[id]))]
        case "response.text.delta", "response.audio_transcript.delta", "response.text.done", "response.audio_transcript.done":
            guard let id = root["item_id"] as? String, let response = root["response_id"] as? String else { throw CaptionError.message("百炼译文缺少消息 ID") }
            let done = type.hasSuffix(".done")
            let field = done ? (type == "response.text.done" ? "text" : "transcript") : "delta"
            guard let text = root[field] as? String else { return [] }
            let key = "\(id):\(root["content_index"] as? Int ?? 0)"
            responses[response,default:[:]][key] = done ? text : (responses[response]?[key] ?? "") + text
            // .done is also sent for interrupted responses; finality comes from response.done.status.
            let source = sourceForTarget[id]
            return [.text(TextUpdate(track:"translation",text:text,replace:done,finality:.interim,start:source.flatMap { starts[$0] },end:source.flatMap { ends[$0] },providerID:key,sourceProviderID:source,speakerID:source.flatMap { speakers[$0] }))]
        case "response.audio.delta":
            guard let encoded = root["delta"] as? String, let bytes = Data(base64Encoded:encoded), bytes.count % 2 == 0 else { throw CaptionError.message("百炼返回无效 PCM 音频") }
            return [.audio(bytes,sampleRate:root["_aoq_sample_rate"] as? Double ?? 24000)]
        case "response.done":
            guard let response = root["response"] as? [String:Any], let id = response["id"] as? String else { return [] }
            var texts = responses.removeValue(forKey:id) ?? [:]
            for item in response["output"] as? [[String:Any]] ?? [] {
                guard let itemID = item["id"] as? String else { continue }
                for (index,part) in (item["content"] as? [[String:Any]] ?? []).enumerated() {
                    if let text = part["text"] as? String ?? part["transcript"] as? String { texts["\(itemID):\(index)"] = text }
                }
            }
            let completed = response["status"] as? String == "completed"
            var events = texts.sorted { $0.key < $1.key }.map { key,text in
                let itemID=key.lastIndex(of:":").map { String(key[..<$0]) } ?? key
                let source=sourceForTarget[itemID]
                return ProviderEvent.text(TextUpdate(track:"translation",text:text,replace:true,finality:completed ? .final : .unconfirmed,boundary:true,
                    start:source.flatMap { starts[$0] },end:source.flatMap { ends[$0] },providerID:key,sourceProviderID:source,speakerID:source.flatMap { speakers[$0] }))
            }
            if let usage = response["usage"] as? [String:Any] { events.append(.usage(usage)) }
            if !completed { events.append(.error("百炼响应未完成：\(response["status"] as? String ?? "unknown")，末段已标记未确认")) }
            return events
        case "conversation.item.input_audio_transcription.text", "response.text.text", "response.audio_transcript.text":
            throw CaptionError.message("收到旧版 Qwen 3.5 协议事件，请检查模型配置")
        default: return []
        }
    }
}

