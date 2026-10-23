import Foundation
import WebRTCBridge

private final class NativeRTCInbox: @unchecked Sendable {
    let archive:AudioArchive?
    let epoch:Int
    private let timelineProbe = ProcessInfo.processInfo.environment["LIVECAPTION_AUDIO_TIMELINE_PROBE"] == "1"
    let messages: AsyncThrowingStream<Data,Error>
    let offers: AsyncThrowingStream<Data,Error>
    let continuation: AsyncThrowingStream<Data,Error>.Continuation
    let offer: AsyncThrowingStream<Data,Error>.Continuation
    init(archive:AudioArchive?,epoch:Int) {
        self.archive=archive;self.epoch=epoch
        var c: AsyncThrowingStream<Data,Error>.Continuation!
        var o: AsyncThrowingStream<Data,Error>.Continuation!
        messages = AsyncThrowingStream(bufferingPolicy:.bufferingOldest(256)) { c=$0 }; continuation=c
        offers = AsyncThrowingStream(bufferingPolicy:.bufferingOldest(1)) { o=$0 }; offer=o
    }
    func receive(_ kind:Int32, _ bytes:UnsafeRawPointer?, _ length:Int, _ value:Int32) {
        if kind == 3 { fail(CaptionError.message(value == 6 ? "WebRTC 连通性中断超过两秒，重新连接" : "原生 WebRTC 连接失败（\(value)）")); return }
        guard let bytes else { return }
        let data=Data(bytes:bytes,count:length)
        let callbackAt=Date().timeIntervalSince1970,callbackUptime=ProcessInfo.processInfo.systemUptime
        if kind == 5 {
            do { try archive?.probeTimeline(data,rate:24000,track:"decoded-output",epoch:epoch,callbackAt:callbackAt,callbackUptime:callbackUptime) } catch { fail(AudioArchiveFailure(error)) }
            return
        }
        if kind == 4 {
            do {
                try archive?.webRTCInput(data,epoch:epoch)
                if timelineProbe { try archive?.probeTimeline(data,rate:16000,track:"input",epoch:epoch,callbackAt:callbackAt,callbackUptime:callbackUptime) }
            } catch { fail(AudioArchiveFailure(error)) }
            return
        }
        if kind == 1 { offer.yield(data); offer.finish(); return }
        let message:Data
        if kind == 2 {
            guard let encoded = try? JSONSerialization.data(withJSONObject:["type":"response.audio.delta","delta":data.base64EncodedString()]) else { return }
            message=encoded
        } else { message=data }
        if case .dropped = continuation.yield(message) { fail(CaptionError.message("原生 WebRTC 接收积压")) }
    }
    func fail(_ error:Error) { continuation.finish(throwing:error); offer.finish(throwing:error) }
}

public actor BailianWebRTCTransport: RealtimeTransport {
    private var bridge:UnsafeMutableRawPointer?
    private var retained:UnsafeMutableRawPointer?
    private var inbox:NativeRTCInbox?
    private var iterator:AsyncThrowingStream<Data,Error>.Iterator?
    private let archive:AudioArchive?
    private let epoch:Int
    public init(audioArchive:AudioArchive? = nil,epoch:Int=0) { archive=audioArchive;self.epoch=epoch }
    public func open(_ request:URLRequest) async throws {
        guard let url=request.url,var parts=URLComponents(url:url,resolvingAgainstBaseURL:false) else { throw CaptionError.message("WebRTC 地址无效") }
        parts.scheme="https"; parts.path="/api/v1/webrtc/realtime"
        let inbox=NativeRTCInbox(archive:archive,epoch:epoch); self.inbox=inbox; iterator=inbox.messages.makeAsyncIterator()
        let context=Unmanaged.passRetained(inbox).toOpaque(); retained=context
        bridge=lc_rtc_create({ context,kind,bytes,length,value in
            guard let context else { return }
            Unmanaged<NativeRTCInbox>.fromOpaque(context).takeUnretainedValue().receive(kind,bytes,length,value)
        },context)
        guard let bridge else { await close(); throw CaptionError.message("WebRTC 引擎创建失败") }
        do {
            let sdp = try await withThrowingTaskGroup(of:Data.self) { group in
                group.addTask { for try await offer in inbox.offers { return offer }; throw CaptionError.message("WebRTC 未生成 SDP") }
                group.addTask { try await Task.sleep(nanoseconds:15_000_000_000); throw CaptionError.message("WebRTC ICE 超时") }
                defer { group.cancelAll() }; return try await group.next()!
            }
            var offer=URLRequest(url:parts.url!); offer.httpMethod="POST"; offer.httpBody=sdp; offer.timeoutInterval=20
            offer.setValue("application/sdp",forHTTPHeaderField:"Content-Type")
            offer.setValue(request.value(forHTTPHeaderField:"Authorization"),forHTTPHeaderField:"Authorization")
            let session=URLSession(configuration:.ephemeral); defer { session.invalidateAndCancel() }
            let (data,response)=try await session.data(for:offer)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CaptionError.message("WebRTC SDP 交换失败（HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)）") }
            guard self.bridge == bridge else { throw CancellationError() }
            data.withUnsafeBytes { lc_rtc_answer(bridge,$0.baseAddress,data.count) }
        } catch { await close(); throw error }
    }
    public func send(_ data:Data) async throws {
        guard let bridge else { throw CaptionError.message("WebRTC 未连接") }
        let root=try JSONSerialization.jsonObject(with:data) as? [String:Any]
        if root?["type"] as? String == "input_audio_buffer.append" {
            guard let encoded=root?["audio"] as? String,let pcm=Data(base64Encoded:encoded) else { throw CaptionError.message("WebRTC PCM 无效") }
            for offset in stride(from:0,to:pcm.count,by:3200) {
                let block=pcm.subdata(in:offset..<min(offset+3200,pcm.count)),deadline=Date().addingTimeInterval(1)
                while true {
                    guard self.bridge == bridge else { throw CancellationError() }
                    let code=block.withUnsafeBytes { lc_rtc_push(bridge,$0.baseAddress,block.count) }
                    if code == 0 { break }
                    guard code == 110,Date() < deadline else { throw CaptionError.message("WebRTC 输入积压（\(code)）") }
                    try await Task.sleep(nanoseconds:10_000_000)
                }
            }
        } else {
            if root?["type"] as? String == "session.finish" {
                lc_rtc_finish_input(bridge); let deadline=Date().addingTimeInterval(2)
                while lc_rtc_pending(bridge)>0 {
                    guard Date()<deadline else { throw CaptionError.message("WebRTC 尾部输入未完成") }
                    try await Task.sleep(nanoseconds:10_000_000)
                    guard self.bridge == bridge else { throw CancellationError() }
                }
                try await Task.sleep(nanoseconds:200_000_000)
                guard self.bridge == bridge else { throw CancellationError() }
                lc_rtc_report(bridge)
            }
            let code=data.withUnsafeBytes { lc_rtc_send(bridge,$0.baseAddress,data.count) }
            guard code == 0 else { throw CaptionError.message("WebRTC 控制事件发送失败（\(code)）") }
        }
    }
    public func receive() async throws -> Data {
        guard var iterator else { throw CaptionError.message("WebRTC 未连接") }
        guard let data=try await iterator.next() else { throw CaptionError.message("WebRTC 已关闭") }
        self.iterator=iterator; return data
    }
    public func close() async {
        if let bridge { self.bridge=nil; lc_rtc_close(bridge) }
        inbox?.continuation.finish(); inbox?.offer.finish(); inbox=nil; iterator=nil
        if let retained { Unmanaged<NativeRTCInbox>.fromOpaque(retained).release(); self.retained=nil }
    }
}
