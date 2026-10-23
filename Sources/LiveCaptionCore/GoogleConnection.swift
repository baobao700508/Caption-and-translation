import Foundation

public actor GoogleConnection {
    private let configuration: Configuration
    private let onEvent: (ProviderEvent) async -> Void
    private let transport:any RealtimeTransport
    private var receiver: Task<Void, Never>?
    private var ready = false
    private var failed: String?
    private var closing = false
    private var resumptionHandle: String?
    private var offeredHandle: String?
    private let finishTimeout:TimeInterval
    private var finishing=false
    private var inputRevision=0
    private var finalRevision = -1
    private var pendingInterim=false
    private var finalAfterEnd=false
    private var turnCompleteAfterEnd=false
    private var lastContentAt=Date.distantPast
    public init(configuration: Configuration, transport:any RealtimeTransport = WebSocketTransport(), finishTimeout:TimeInterval=10, onEvent: @escaping (ProviderEvent) async -> Void) {
        self.configuration = configuration; self.transport = transport; self.onEvent = onEvent
        self.finishTimeout=finishTimeout
    }
    public func connect(handle: String? = nil) async throws {
        try configuration.validate()
        offeredHandle = handle
        let url = URL(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent")!
        var request = URLRequest(url: url)
        request.setValue(configuration.apiKey, forHTTPHeaderField: "x-goog-api-key")
        try await transport.open(request)
        receiver = Task { [weak self] in await self?.receiveLoop() }
        try await send(configuration.setup(resumptionHandle: handle))
        for _ in 0..<200 {
            if let failed { throw CaptionError.message(failed) }
            if ready { return }
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        await close(); throw CaptionError.message("Google 会话就绪超时；检查 API key、模型权限和网络")
    }
    private func receiveLoop() async {
        do {
            while !Task.isCancelled && !closing {
                let data = try await transport.receive()
                let root=try JSONSerialization.jsonObject(with:data) as? [String:Any]
                if let content=root?["serverContent"] as? [String:Any] {
                    lastContentAt=Date()
                    if content["turnComplete"] as? Bool == true,content["interactionStatus"] as? String != "IN_PROGRESS",finishing { turnCompleteAfterEnd=true }
                }
                for event in try GoogleProtocol.events(from: data, pipeline: configuration.pipeline) {
                    switch event {
                    case .ready: ready = true
                    case .error(let text): failed = redact(text)
                    case .resumption(let h): resumptionHandle = h
                    case .text(let update):
                        if configuration.pipeline == .transcribe,update.track == "source" {
                            if update.finality == .final {
                                finalRevision=inputRevision;pendingInterim=false
                                if finishing { finalAfterEnd=true }
                            } else if update.finality == .interim { pendingInterim=true }
                        }
                    default: break
                    }
                    if case .error(let text) = event { await onEvent(.error(redact(text))) }
                    else { await onEvent(event) }
                }
            }
        } catch {
            if !closing && !Task.isCancelled {
                let detail = error.localizedDescription
                let message = redact(detail)
                failed = message; await onEvent(.error(message))
            }
        }
    }
    private func redact(_ text: String) -> String {
        var text = text.replacingOccurrences(of: configuration.apiKey, with: "[redacted]")
        if let resumptionHandle { text = text.replacingOccurrences(of: resumptionHandle, with: "[redacted]") }
        if let offeredHandle { text = text.replacingOccurrences(of: offeredHandle, with: "[redacted]") }
        return text
    }
    private func send(_ object: [String: Any]) async throws {
        try await transport.send(JSONSerialization.data(withJSONObject:object))
    }
    public func sendAudio(_ data: Data) async throws {
        guard ready && !closing && !finishing && failed == nil else { throw CaptionError.message("服务尚未就绪或正在结束") }
        inputRevision += 1
        try await send(GoogleProtocol.audioMessage(data))
    }
    public func endInput() async { try? await send(["realtimeInput": ["audioStreamEnd": true]]) }
    public func finish() async -> Bool {
        guard ready && !closing && failed == nil else { return false }
        let started=Date()
        if !finishing {
            finishing=true
            await onEvent(.diagnostic("provider.google_input_end",["input_chunks":inputRevision,
                "input_chunks_at_last_final":finalRevision,"pending_interim":pendingInterim]))
            do { try await send(["realtimeInput":["audioStreamEnd":true]]) }
            catch { failed=redact(error.localizedDescription);return false }
        }
        let deadline=Date().addingTimeInterval(finishTimeout)
        while Date()<deadline && !closing && failed == nil && !Task.isCancelled {
            let finalized=configuration.pipeline == .transcribe
                ? (!pendingInterim && finalRevision == inputRevision && (finalAfterEnd || Date().timeIntervalSince(lastContentAt)>=0.2))
                : turnCompleteAfterEnd
            if inputRevision == 0 || (finalized && Date().timeIntervalSince(lastContentAt)>=0.2) {
                await onEvent(.diagnostic("provider.google_input_finalized",[
                    "basis":inputRevision == 0 ? "no_audio":(configuration.pipeline == .transcribe ? "final_input_transcription":"turn_complete"),
                    "confirmation_scope":configuration.pipeline == .transcribe ? "received_transcripts":"provider_turn",
                    "input_chunks":inputRevision,"input_chunks_at_last_final":finalRevision,
                    "after_stream_end":finalAfterEnd || turnCompleteAfterEnd,
                    "drain_seconds":Date().timeIntervalSince(started)]))
                return true
            }
            try? await Task.sleep(nanoseconds:20_000_000)
        }
        // Final transcripts cover speech segments, not every subsequent microphone
        // packet. If speech was finalized before stopping, trailing quiet packets
        // need not produce another inputTranscription or an end acknowledgement.
        // Keep the entire drain window to receive any later hypothesis/final;
        // an unresolved interim, transport failure or cancellation still fails.
        if configuration.pipeline == .transcribe && !closing && failed == nil && !Task.isCancelled,
           finalRevision >= 0 && !pendingInterim {
            await onEvent(.diagnostic("provider.google_input_finalized",[
                "basis":"received_transcripts_final_after_drain","confirmation_scope":"received_transcripts",
                "input_chunks":inputRevision,"input_chunks_at_last_final":finalRevision,
                "after_stream_end":finalAfterEnd,"stream_end_acknowledged":false,
                "drain_seconds":Date().timeIntervalSince(started)]))
            return true
        }
        await onEvent(.diagnostic("provider.google_input_unconfirmed",["input_chunks":inputRevision,
            "input_chunks_at_last_final":finalRevision,"pending_interim":pendingInterim,
            "final_after_end":finalAfterEnd,"drain_seconds":Date().timeIntervalSince(started)]))
        return false
    }
    public func close() async {
        closing = true; ready = false; receiver?.cancel(); receiver = nil
        await transport.close()
    }
}
