import Foundation
import LiveCaptionCore
import Network

/// Native WebSocket framing over TLS/TCP with Nagle disabled for small realtime frames.
/// Completion still denotes a local write, never a provider consumption acknowledgement.
public actor NetworkWebSocketTransport: RealtimeTransport {
    private var connection: NWConnection?
    private let queue = DispatchQueue(label:"LiveCaption.websocket",qos:.userInitiated)
    private var opening: CheckedContinuation<Void,Error>?
    public init() {}
    public func open(_ request: URLRequest) async throws {
        guard let url = request.url, url.scheme == "wss" else { throw CaptionError.message("需要安全 WebSocket 地址") }
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true; tcp.enableKeepalive = true
        let parameters = NWParameters(tls:NWProtocolTLS.Options(),tcp:tcp)
        let ws = NWProtocolWebSocket.Options(); ws.autoReplyPing = true; ws.maximumMessageSize = 4*1024*1024
        ws.setAdditionalHeaders((request.allHTTPHeaderFields ?? [:]).map { (name:$0.key,value:$0.value) })
        parameters.defaultProtocolStack.applicationProtocols.insert(ws,at:0)
        let connection = NWConnection(to:.url(url),using:parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in Task { await self?.stateChanged(state) } }
        try await withCheckedThrowingContinuation { continuation in
            opening = continuation; connection.start(queue:queue)
            queue.asyncAfter(deadline:.now()+20) { [weak self] in Task { await self?.openTimeout() } }
        }
    }
    private func stateChanged(_ state: NWConnection.State) {
        switch state {
        case .ready: opening?.resume(); opening = nil
        case .failed(let error): opening?.resume(throwing:error); opening = nil
        case .cancelled: opening?.resume(throwing:CancellationError()); opening = nil
        default: break
        }
    }
    private func openTimeout() {
        guard let opening else { return }; self.opening = nil
        opening.resume(throwing:CaptionError.message("WebSocket 建连超时")); connection?.cancel()
    }
    public func send(_ data: Data) async throws {
        guard let connection else { throw CaptionError.message("连接尚未建立") }
        let metadata = NWProtocolWebSocket.Metadata(opcode:.text)
        let context = NWConnection.ContentContext(identifier:UUID().uuidString,metadata:[metadata])
        try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in
            connection.send(content:data,contentContext:context,isComplete:true,completion:.contentProcessed { error in
                if let error { continuation.resume(throwing:error) } else { continuation.resume() }
            })
        }
    }
    public func receive() async throws -> Data {
        guard let connection else { throw CaptionError.message("连接尚未建立") }
        while true {
            let result: (Data?, NWProtocolWebSocket.Opcode?) = try await withCheckedThrowingContinuation { continuation in
                connection.receiveMessage { data,context,_,error in
                    if let error { continuation.resume(throwing:error); return }
                    let metadata = context?.protocolMetadata(definition:NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                    continuation.resume(returning:(data,metadata?.opcode))
                }
            }
            switch result.1 {
            case .text, .binary: return result.0 ?? Data()
            case .close, nil: throw CaptionError.message("WebSocket 已关闭")
            default: continue
            }
        }
    }
    public func close() async { connection?.cancel(); connection = nil }
}
