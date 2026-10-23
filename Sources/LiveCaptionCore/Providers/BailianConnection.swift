import Foundation
import CoreFoundation

public actor BailianConnection: ProviderConnection {
    private let configuration: Configuration
    private let onEvent: (ProviderEvent) async -> Void
    private let transport: any RealtimeTransport
    private let timeout: TimeInterval
    private var receiver: Task<Void,Never>?
    private var parser = BailianProtocol()
    private var ready = false
    private var closing = false
    private var finishing = false
    private var finished = false
    private var playoutDeadline: Date?
    private var failed: String?
    private var setupSent = false
    private var lastDeliveryReport:TimeInterval = 0
    public init(configuration: Configuration, transport: (any RealtimeTransport)? = nil, timeout: TimeInterval = 20, onEvent: @escaping (ProviderEvent) async -> Void) {
        self.configuration = configuration; self.transport = transport ?? configuration.bailianTransport.make(); self.timeout = timeout; self.onEvent = onEvent
    }
    public func connect(handle: String? = nil) async throws {
        try configuration.validate()
        guard configuration.provider == .bailian, configuration.pipeline == .translate else { throw CaptionError.message("LiveTranslate 仅用于翻译线路") }
        var request = URLRequest(url:configuration.bailianURL)
        request.setValue("Bearer \(configuration.bailianAPIKey)",forHTTPHeaderField:"Authorization")
        try await transport.open(request)
        receiver = Task { [weak self] in await self?.receiveLoop() }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let failed { throw CaptionError.message(failed) }
            if ready { return }
            try Task.checkCancellation(); try await Task.sleep(nanoseconds:20_000_000)
        }
        await close(); throw CaptionError.message("百炼会话就绪超时；检查地区、工作空间 ID、API Key 和模型权限")
    }
    private func send(_ object: [String:Any]) async throws {
        try await transport.send(JSONSerialization.data(withJSONObject:object))
    }
    private func receiveLoop() async {
        do {
            while !closing && !Task.isCancelled {
                let data = try await transport.receive()
                let root = try JSONSerialization.jsonObject(with:data) as? [String:Any]
                if let nativeTime=root?["_native_received_unix_seconds"] as? Double,
                   let nativeUptime=root?["_native_received_uptime_seconds"] as? Double {
                    let now=ProcessInfo.processInfo.systemUptime,delay=max(0,now-nativeUptime)
                    if now-lastDeliveryReport>=1 || delay>0.25 {
                        lastDeliveryReport=now
                        await onEvent(.diagnostic("transport.webrtc_delivery",["native_received_unix_seconds":nativeTime,
                            "native_queue_delay_seconds":delay,"provider_event_type":root?["type"] as? String ?? "unknown"]))
                    }
                }
                if finishing, playoutDeadline == nil, root?["type"] as? String == "_webrtc.stage",
                   root?["stage"] as? String == "playout.draining", root?["remote_finished"] as? Bool == true {
                    // Only the native bridge emits this after the terminal server event.
                    // A single bounded extension allows RTP to finish after the data channel.
                    playoutDeadline = Date().addingTimeInterval(32)
                }
                if root?["type"] as? String == "session.created" {
                    if !setupSent {
                        setupSent = true
                        try await send(BailianProtocol.setup(configuration:configuration))
                    }
                    continue
                }
                if root?["type"] as? String == "session.updated", let root {
                    let session=root["session"] as? [String:Any] ?? [:]
                    let audio=session["audio"] as? [String:Any] ?? [:]
                    let input=audio["input"] as? [String:Any] ?? [:]
                    let detection=input["turn_detection"] as? [String:Any] ?? [:]
                    if detection["type"] as? String != configuration.resolvedBailianTurnDetection.rawValue {
                        await onEvent(.diagnostic("provider.configuration_rejected",[
                            "requested_turn_detection":configuration.resolvedBailianTurnDetection.rawValue,
                            "server_turn_detection":detection.filter { ["type","threshold","silence_duration_ms"].contains($0.key) },
                            "reason":"server_detection_does_not_match_request","automatic_fallback_performed":false]))
                    }
                    let confirmed = try BailianProtocol.confirmedSession(root,configuration:configuration)
                    await onEvent(.diagnostic("provider.configuration",confirmed))
                }
                for event in try parser.events(from:data) {
                    if case .error(let message) = event {
                        let message = configuration.redacted(message); failed = message; await onEvent(.error(message))
                    } else {
                        await onEvent(event)
                        if case .ready = event { ready = true }
                        if case .finished = event {
                            guard finishing else { throw CaptionError.message("百炼会话意外结束，需重连") }
                            finished = true; return
                        }
                    }
                }
            }
        } catch {
            if !closing && !Task.isCancelled {
                let message = configuration.redacted(error.localizedDescription)
                failed = message; await onEvent(.error(message))
            }
        }
    }
    public func sendAudio(_ data: Data) async throws {
        guard ready && !closing && !finishing && failed == nil else { throw CaptionError.message("百炼服务尚未就绪或正在结束") }
        guard data.count % 2 == 0 else { throw CaptionError.message("输入必须为 16 kHz 单声道 PCM16") }
        try await send(BailianProtocol.audioMessage(data))
    }
    public func finish() async -> Bool {
        guard ready && !closing else { return false }
        if !finishing {
            finishing = true
            do { try await send(["type":"session.finish"]) }
            catch { failed = configuration.redacted(error.localizedDescription); return false }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < max(deadline,playoutDeadline ?? deadline) && !closing && !Task.isCancelled {
            if finished { return failed == nil }
            if failed != nil { return false }
            try? await Task.sleep(nanoseconds:20_000_000)
        }
        return false
    }
    public func close() async {
        closing = true; ready = false; receiver?.cancel(); receiver = nil
        await transport.close()
    }
}
