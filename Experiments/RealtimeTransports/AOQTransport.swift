import Foundation
import LiveCaptionCore
import AoqBridge

private final class AOQInbox: @unchecked Sendable {
    let archive:AudioArchive?
    let stream:AsyncThrowingStream<Data,Error>
    let continuation:AsyncThrowingStream<Data,Error>.Continuation
    private let lock = NSLock()
    private var connected = false
    init(archive:AudioArchive?) {
        self.archive = archive
        var c:AsyncThrowingStream<Data,Error>.Continuation!
        stream = AsyncThrowingStream(bufferingPolicy:.bufferingOldest(256)) { c = $0 }; continuation = c
    }
    func receive(kind:Int32,bytes:UnsafeRawPointer?,length:Int,value:Int32) {
        lock.lock(); defer { lock.unlock() }
        var message:Data?
        switch kind {
        case 4,5:
            if let bytes {
                do { try archive?.publishedPCM(Data(bytes:bytes,count:length),rate:Int(value),generatedMute:kind == 5) }
                catch { continuation.finish(throwing:AudioArchiveFailure(error)) }
            }
        case 0:
            if let bytes {
                let data = Data(bytes:bytes,count:length)
                // The SDK's connected callback is the AOQ setup trigger; ignore a duplicate gateway greeting.
                if let root = try? JSONSerialization.jsonObject(with:data) as? [String:Any],root["type"] as? String == "session.created" { return }
                message = data
            }
        case 1:
            if value == 2 && !connected { connected = true; message = Data(#"{"type":"session.created"}"#.utf8) }
            if value == 3 || (value == 0 && connected) { continuation.finish(throwing:CaptionError.message("AOQ 连接中断（\(value)）")) }
        case 2:
            if let bytes {
                let data = Data(bytes:bytes,count:length)
                message = try? JSONSerialization.data(withJSONObject:["type":"response.audio.delta","delta":data.base64EncodedString(),"_aoq_sample_rate":Int(value)])
            }
        case 3: continuation.finish(throwing:CaptionError.message("AOQ SDK 错误（\(value)）"))
        default: break
        }
        if let message,case .dropped = continuation.yield(message) { continuation.finish(throwing:CaptionError.message("AOQ 接收积压，连接已停止以免静默丢失结果")) }
    }
}

/// AOQ uses native Opus media plus a reliable model-event data channel.
/// Existing JSON/PCM provider contracts and the local PCM archive stay shared with WebSocket.
public actor AOQTransport: RealtimeTransport {
    private let archive:AudioArchive?
    private var bridge:UnsafeMutableRawPointer?
    private var retainedInbox:UnsafeMutableRawPointer?
    private var inbox:AOQInbox?
    private var iterator:AsyncThrowingStream<Data,Error>.Iterator?
    private var workDirectory:URL?
    private var samples = 0
    public init(audioArchive:AudioArchive? = nil) { archive = audioArchive }
    public func open(_ request:URLRequest) async throws {
        guard let url = request.url,var components = URLComponents(url:url,resolvingAgainstBaseURL:false) else { throw CaptionError.message("AOQ 地址无效") }
        components.scheme = "https"; components.path = "/api/v1/webrtc/realtime"
        var tokenRequest = URLRequest(url:components.url!); tokenRequest.httpMethod = "POST"; tokenRequest.httpBody = Data("{}".utf8); tokenRequest.timeoutInterval = 20
        tokenRequest.setValue(request.value(forHTTPHeaderField:"Authorization"),forHTTPHeaderField:"Authorization")
        tokenRequest.setValue("application/json",forHTTPHeaderField:"Content-Type"); tokenRequest.setValue("moq",forHTTPHeaderField:"x-dashscope-rtc-transport")
        let session = URLSession(configuration:.ephemeral); defer { session.invalidateAndCancel() }
        let (data,response) = try await session.data(for:tokenRequest)
        guard let response = response as? HTTPURLResponse,response.statusCode == 200 else { throw CaptionError.message("AOQ 临时凭证申请失败（HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)）") }
        guard let root = try JSONSerialization.jsonObject(with:data) as? [String:Any],
              let token = root["aoqTokenForClient"] as? String,!token.isEmpty,
              root["sid"] is String, root["clientRelayCertFingerprint"] is String,
              let endpoints = root["clientRelayEndpoints"] as? [[String:Any]],!endpoints.isEmpty,
              endpoints.allSatisfy({ $0["endpoint"] is String && $0["port"] is Int }) else { throw CaptionError.message("AOQ 临时凭证响应缺少必要字段") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("livecaption-aoq-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]); workDirectory = directory
        let inbox = AOQInbox(archive:archive); self.inbox = inbox; iterator = inbox.stream.makeAsyncIterator()
        let context = Unmanaged.passRetained(inbox).toOpaque(); retainedInbox = context
        bridge = lc_aoq_create(directory.path,{ context,kind,bytes,length,value in
            guard let context else { return }; Unmanaged<AOQInbox>.fromOpaque(context).takeUnretainedValue().receive(kind:kind,bytes:bytes,length:length,value:value)
        },context)
        guard let bridge else { await close(); throw CaptionError.message("AOQ 引擎创建失败") }
        let code = data.withUnsafeBytes { lc_aoq_connect(bridge,$0.baseAddress,data.count) }
        if code != 0 { await close(); throw CaptionError.message("AOQ 引擎建连失败（\(code)）") }
    }
    public func send(_ data:Data) async throws {
        guard let bridge else { throw CaptionError.message("AOQ 尚未建立连接") }
        let root = try JSONSerialization.jsonObject(with:data) as? [String:Any]
        if root?["type"] as? String == "input_audio_buffer.append" {
            guard let encoded = root?["audio"] as? String,let pcm = Data(base64Encoded:encoded),pcm.count%2 == 0 else { throw CaptionError.message("AOQ 输入 PCM 无效") }
            // Small external-input frames; the SDK encodes Opus. Retrying 110 never advances the source cursor.
            for offset in stride(from:0,to:pcm.count,by:1280) {
                let chunk = pcm.subdata(in:offset..<min(offset+1280,pcm.count)); let deadline = Date().addingTimeInterval(1)
                while true {
                    let code = chunk.withUnsafeBytes { lc_aoq_push(bridge,$0.baseAddress,chunk.count,Int64(samples/16)) }
                    if code == 0 { samples += chunk.count/2; break }
                    guard code == 110,Date() < deadline else { throw CaptionError.message("AOQ 音频发送失败（\(code)）") }
                    try await Task.sleep(nanoseconds:20_000_000)
                    guard self.bridge != nil else { throw CancellationError() }
                }
            }
        } else {
            let code = data.withUnsafeBytes { lc_aoq_send(bridge,$0.baseAddress,data.count) }
            guard code == 0 else { throw CaptionError.message("AOQ 事件发送失败（\(code)）") }
        }
    }
    public func receive() async throws -> Data {
        guard var iterator else { throw CaptionError.message("AOQ 尚未建立连接") }
        guard let data = try await iterator.next() else { throw CaptionError.message("AOQ 已关闭") }
        self.iterator = iterator
        if let root = try? JSONSerialization.jsonObject(with:data) as? [String:Any],root["type"] as? String == "session.updated",let bridge {
            // BailianConnection validates the echoed contract before starting the producer.
            let code = lc_aoq_enable(bridge); guard code == 0 else { throw CaptionError.message("AOQ 启用上行失败（\(code)）") }
        }
        return data
    }
    public func close() async {
        if let bridge { self.bridge = nil; lc_aoq_close(bridge) }
        inbox?.continuation.finish(); iterator = nil; inbox = nil
        if let retainedInbox { Unmanaged<AOQInbox>.fromOpaque(retainedInbox).release(); self.retainedInbox = nil }
        if let workDirectory { try? FileManager.default.removeItem(at:workDirectory); self.workDirectory = nil }
    }
}
