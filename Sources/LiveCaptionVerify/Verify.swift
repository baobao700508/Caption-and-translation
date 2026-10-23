import Foundation
import AVFoundation
import AppKit
import LiveCaptionCore
import LiveCaptionTransportExperiments

actor Evidence {
    let origin = Date()
    var firstEvents: [String:Double] = [:]
    var source = ""
    var translation = ""
    var audioBytes = 0
    var failed: String?
    var inputClock: [String:Any]?
    var ready=false
    var prematureRTP=0
    func record(_ event: ProviderEvent, log: SessionLog) async {
        do {
            switch event {
            case .text(let update):
                if !update.text.isEmpty && firstEvents[update.track] == nil { firstEvents[update.track] = Date().timeIntervalSince(origin) }
                let result = try await log.text(update, epoch: 1)
                source = result.segments.filter { $0.track == "source" }.map(\.text).joined(separator:"\n")
                translation = result.segments.filter { $0.track == "translation" }.map(\.text).joined(separator:"\n")
            case .audio(let data, let rate):
                if firstEvents["audio"] == nil { firstEvents["audio"] = Date().timeIntervalSince(origin) }
                audioBytes += data.count
                try log.audioArchive.translated(data,rate:Int(rate))
            case .error(let text): failed = text; try await log.record("provider.error",fields:["message":text])
            case .usage(let data): try await log.record("usage", fields: ["usage": data])
            case .diagnostic(let type,let data):
                if type == "transport.webrtc_input" { inputClock=data }
                if type == "transport.webrtc_stats",!ready,data["kind"] as? String == "outbound-rtp" { prematureRTP=max(prematureRTP,data["packetsSent"] as? Int ?? 0) }
                try await log.record(type,fields:data)
            case .ready: ready=true
            default: break
            }
        } catch { failed = "验证日志写入失败" }
    }
    func result() -> (String,String,Int,String?) { (source,translation,audioBytes,failed) }
    func timing() -> [String:Double] { firstEvents }
    func mediaEvidence() -> [String:Any] {
        guard let inputClock else { return [:] }
        return inputClock.merging(["premature_rtp_packets":prematureRTP]) { old,_ in old }
    }
}

@main struct Verify {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let delegate = VerificationDelegate()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
    static func run() async {
        do {
            let args = CommandLine.arguments
            guard args.count >= 4 else { print("用法：LiveCaptionVerify <16kHz-mono.wav> <transcribe|translate|all> <测试配置.json> [subtitles|speech]"); exit(2) }
            var config = try Configuration.load(from: URL(fileURLWithPath:args[3]))
            if args.count > 4, let mode = OutputMode(rawValue:args[4]) { config.translationMode = mode }
            let pcm = try readPCM(URL(fileURLWithPath:args[1]))
            let selected = args[2]
            guard selected == "all" || Pipeline(rawValue:selected) != nil else { throw CaptionError.message("未知线路参数") }
            let pipelines = Pipeline.allCases.filter { selected == "all" || $0.rawValue == selected }
            guard !pipelines.isEmpty else { throw CaptionError.message("未选择验证线路") }
            let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("TestResults/live-\(Int(Date().timeIntervalSince1970))")
            print("验证线路数：\(pipelines.count)，线路：\(selected)")
            var results: [[String: Any]] = []
            for pipeline in pipelines {
                config.pipeline = pipeline
                try config.validate()
                let log = try SessionLog(configuration: config, rootOverride: root.appendingPathComponent(pipeline.rawValue))
                try await log.begin(); try await log.beginEpoch(1, configuration: config)
                let evidence = Evidence()
                let transport:(any RealtimeTransport)?
                switch ProcessInfo.processInfo.environment["LIVECAPTION_TRANSPORT"] {
                case "aoq": transport = AOQTransport(audioArchive:log.audioArchive)
                case "network": transport = NetworkWebSocketTransport()
                case "webkit-webrtc": transport = WebKitWebRTCTransport()
                case "webrtc", "native-webrtc": transport = BailianWebRTCTransport(audioArchive:log.audioArchive)
                case "websocket": transport = WebSocketTransport()
                default: transport = nil
                }
                let connection = Connections.make(configuration: config, audioArchive: log.audioArchive, epoch: 1, transport:transport) { event in await evidence.record(event, log: log) }
                do {
                    try await connection.connect(handle:nil); try await log.setState("verification_running")
                    let origin = Date().timeIntervalSince1970
                    var writes: [[String:Any]] = []
                    let packetBytes = max(320,min(32000,(Int(ProcessInfo.processInfo.environment["LIVECAPTION_PACKET_MS"] ?? "100") ?? 100)*32))
                    let queue = AudioPacketQueue()
                    let producer = Task.detached { () throws -> Int in
                        var dropped = 0
                        defer { queue.finish() }
                        for offset in stride(from:0,to:pcm.count,by:packetBytes) {
                            let end = min(offset+packetBytes,pcm.count)
                            // A captured block becomes available at its end, as in AudioFrontend.
                            let start = origin+Double(offset)/32000,endTime = origin+Double(end)/32000
                            let delay = endTime-Date().timeIntervalSince1970
                            if delay > 0 { try await Task.sleep(nanoseconds:UInt64(delay*1e9)) }
                            try Task.checkCancellation()
                            dropped += queue.append(CapturedAudio(data:pcm.subdata(in:offset..<end),timing:AudioTiming(captureStartedAt:start,captureEndedAt:endTime,preparedAt:Date().timeIntervalSince1970)))
                        }
                        return dropped
                    }
                    var sentSamples = 0
                    do {
                        for await _ in queue.signals {
                            while let packet = queue.takeBatch() {
                                let submitted = Date().timeIntervalSince1970
                                try await connection.sendAudio(packet.data,timing:packet.timing)
                                writes.append(["sample_offset":sentSamples,"sample_count":packet.data.count/2,"schedule_lag":submitted-packet.timing.preparedAt,"write_seconds":Date().timeIntervalSince1970-submitted])
                                sentSamples += packet.data.count/2
                            }
                        }
                    } catch { producer.cancel(); _ = try? await producer.value; throw error }
                    let droppedPackets = try await producer.value
                    if droppedPackets > 0 { try await log.record("gap",fields:["message":"文件回放发送队列丢弃 \(droppedPackets) 包","dropped_packets":droppedPackets]) }
                    let finished = await connection.finish()
                    await connection.close(); try await log.finish(tailIncomplete: !finished)
                    let (source,translation,audio,error) = await evidence.result()
                    let protocolPass = !source.isEmpty && (pipeline == .transcribe || (!translation.isEmpty && (config.translationMode == .speech ? audio > 0 : (config.provider != .bailian || audio == 0)))) && error == nil && finished
                    let maxLag = writes.compactMap { $0["schedule_lag"] as? Double }.max() ?? 0
                    let maxWrite = writes.compactMap { $0["write_seconds"] as? Double }.max() ?? 0
                    let media=await evidence.mediaEvidence()
                    let mediaPass=media.isEmpty || ((media["consumed_samples"] as? Int == pcm.count/2) && (media["underflow_samples"] as? Int == 0) && (media["pending_samples"] as? Int == 0) && (media["premature_rtp_packets"] as? Int == 0))
                    let transportPass = maxLag < 2 && maxWrite < 2 && droppedPackets == 0 && sentSamples*2 == pcm.count && mediaPass
                    let success = protocolPass && transportPass
                    let first = await evidence.timing()
                    results.append(["pipeline": pipeline.rawValue,"success":success,"protocol_pass":protocolPass,"realtime_transport_pass":transportPass,"native_media":media,"dropped_packets":droppedPackets,"sent_samples":sentSamples,"max_schedule_lag_seconds":maxLag,"max_write_seconds":maxWrite,"source":source,"translation":translation,"received_audio_bytes":audio,"provider":config.provider.rawValue,"mode":config.translationMode.rawValue,"finish_acknowledged":finished,"error":error as Any? ?? NSNull(),"log_path":log.directory.path,"writes":writes,"input_seconds":Double(pcm.count)/32000,"first_events_seconds_since_connect_start":first,"input_started_seconds_since_connect_start":origin-evidence.origin.timeIntervalSince1970])
                    print("\(success ? "PASS" : "FAIL") \(config.providerName) \(pipeline.rawValue)：原文 \(source.count) 字符，译文 \(translation.count) 字符，音频 \(audio) bytes")
                } catch {
                    await connection.close(); try? await log.finish(tailIncomplete: true)
                    let (_,_,_,providerError) = await evidence.result()
                    results.append(["pipeline":pipeline.rawValue,"mode":config.translationMode.rawValue,"provider":config.provider.rawValue,"success":false,"error":config.redacted(providerError ?? error.localizedDescription),"log_path":log.directory.path])
                    print("FAIL \(config.providerName) \(pipeline.rawValue)：连接或调用失败，详见验证结果")
                }
            }
            try FileManager.default.createDirectory(at: root,withIntermediateDirectories:true)
            try JSONSerialization.data(withJSONObject:["tested_at":SessionLog.timestamp(),"quality_evaluated":false,"scope":"真实云端连接、有限文件经应用同款队列发送、接收与日志；通过只表示协议及本地发送时效，不代表词级延迟、翻译准确率、系统采集、UI或扬声器AEC验收","results":results],options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("result.json"),options:.atomic)
            print("验证报告：\(root.path)/result.json")
            exit(!results.isEmpty && results.allSatisfy { $0["success"] as? Bool == true } ? 0 : 1)
        } catch { print("验证未执行：\(error.localizedDescription)"); exit(2) }
    }
    /// Preserve every WAV sample; no AVAudioConverter priming/trailing-frame trimming in transport tests.
    static func readPCM(_ url:URL) throws -> Data {
        let bytes = [UInt8](try Data(contentsOf:url))
        func word(_ i:Int) -> Int { Int(bytes[i]) | Int(bytes[i+1])<<8 }
        func dword(_ i:Int) -> Int { word(i) | word(i+2)<<16 }
        guard bytes.count >= 44,String(bytes:bytes[0..<4],encoding:.ascii) == "RIFF",String(bytes:bytes[8..<12],encoding:.ascii) == "WAVE" else { throw CaptionError.message("验证文件须为PCM WAV") }
        var offset = 12, valid = false, pcm:Data?
        while offset+8 <= bytes.count {
            let size = dword(offset+4), start = offset+8
            guard size <= bytes.count-start else { throw CaptionError.message("WAV 数据不完整") }
            let name = String(bytes:bytes[offset..<offset+4],encoding:.ascii)
            if name == "fmt ",size >= 16 { valid = word(start) == 1 && word(start+2) == 1 && dword(start+4) == 16000 && word(start+14) == 16 }
            if name == "data" { pcm = Data(bytes[start..<start+size]) }
            offset = start+size+(size%2)
        }
        guard valid, let pcm,pcm.count%2 == 0 else { throw CaptionError.message("验证文件须为16kHz单声道PCM16 WAV") }
        return pcm
    }
}

@MainActor private final class VerificationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await Verify.run() }
    }
}
