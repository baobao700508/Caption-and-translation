import Foundation

public actor WebSocketTransport: RealtimeTransport {
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    public init() {}
    public func open(_ request: URLRequest) async throws {
        let options = URLSessionConfiguration.ephemeral
        options.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: options)
        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 4 * 1024 * 1024
        self.session = session; self.socket = socket; socket.resume()
    }
    public func send(_ data: Data) async throws {
        guard let socket else { throw CaptionError.message("连接尚未建立") }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in
                let write = WebSocketWrite(continuation)
                socket.send(.string(String(decoding:data,as:UTF8.self))) { error in
                    _ = write.complete(error.map { .failure($0) } ?? .success(()))
                }
                DispatchQueue.global(qos:.userInitiated).asyncAfter(deadline:.now()+5) {
                    if write.complete(.failure(CaptionError.message("音频连接写入超过 5 秒，已断开积压连接"))) {
                        socket.cancel(with:.goingAway,reason:nil)
                    }
                }
            }
        } onCancel: { socket.cancel(with:.goingAway,reason:nil) }
    }
    public func receive() async throws -> Data {
        guard let socket else { throw CaptionError.message("连接尚未建立") }
        do {
            switch try await socket.receive() {
            case .data(let data): return data
            case .string(let text): return Data(text.utf8)
            @unknown default: throw CaptionError.message("无法识别 WebSocket 消息")
            }
        } catch {
            var detail = error.localizedDescription
            if let response = socket.response as? HTTPURLResponse { detail += " (HTTP \(response.statusCode))" }
            if socket.closeCode != .invalid { detail += " (WebSocket \(socket.closeCode.rawValue))" }
            if let data = socket.closeReason, let reason = String(data:data,encoding:.utf8) { detail += ": "+reason }
            throw CaptionError.message(detail)
        }
    }
    public func close() async {
        socket?.cancel(with:.normalClosure,reason:nil); socket = nil
        session?.invalidateAndCancel(); session = nil
    }
}

private final class WebSocketWrite: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation:CheckedContinuation<Void,Error>?
    init(_ continuation:CheckedContinuation<Void,Error>) { self.continuation = continuation }
    @discardableResult func complete(_ result:Result<Void,Error>) -> Bool {
        lock.lock(); let continuation = self.continuation; self.continuation = nil; lock.unlock()
        guard let continuation else { return false }; continuation.resume(with:result); return true
    }
}
