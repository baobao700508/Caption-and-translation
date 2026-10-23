import Foundation

public protocol ProviderConnection: Actor {
    func connect(handle: String?) async throws
    func sendAudio(_ data: Data) async throws
    func sendAudio(_ data: Data, timing: AudioTiming) async throws
    /// Returns true when the provider-specific output-finalization checks pass, not a sample-level receipt.
    /// Google transcription may finish already-final received transcripts after a bounded drain;
    /// its diagnostic records this narrower scope without claiming a stream-end acknowledgement.
    func finish() async -> Bool
    func close() async
}

extension ProviderConnection {
    public func sendAudio(_ data: Data, timing: AudioTiming) async throws { try await sendAudio(data) }
}

extension GoogleConnection: ProviderConnection {
}

public enum Connections {
    public static func make(configuration: Configuration, audioArchive: AudioArchive? = nil, epoch: Int = 0, transport: (any RealtimeTransport)? = nil, onEvent: @escaping (ProviderEvent) async -> Void) -> any ProviderConnection {
        let connection: any ProviderConnection
        switch configuration.provider {
        case .bailian:
            let selected: any RealtimeTransport = transport ?? configuration.bailianTransport.make(audioArchive:audioArchive,epoch:epoch)
            connection = BailianConnection(configuration: configuration, transport: selected, onEvent:onEvent)
        case .google:
            connection = GoogleConnection(configuration:configuration,transport:transport ?? WebSocketTransport(),onEvent:onEvent)
        case .whisperKit:
            connection = WhisperKitConnection(configuration:configuration,onEvent:onEvent)
        }
        guard let audioArchive else { return connection }
        return ArchivedConnection(connection: connection, archive: audioArchive, epoch: epoch)
    }

}

/// Keeps the WebSocket lifecycle testable without sending credentials or audio to a cloud service.
public protocol RealtimeTransport: Actor {
    func open(_ request: URLRequest) async throws
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close() async
}

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


public struct AudioArchiveFailure: LocalizedError {
    public let errorDescription: String?
    public init(_ error: Error) { errorDescription = "录音保存失败：" + error.localizedDescription }
}

/// Archive exactly the bytes accepted by the same connection, including during epoch replacement.
public actor ArchivedConnection: ProviderConnection {
    private let connection: any ProviderConnection
    private let archive: AudioArchive
    private let epoch: Int
    public init(connection: any ProviderConnection, archive: AudioArchive, epoch: Int) {
        self.connection = connection; self.archive = archive; self.epoch = epoch
    }
    public func connect(handle: String?) async throws { try await connection.connect(handle: handle) }
    public func sendAudio(_ data: Data) async throws { try await sendAndArchive(data, timing:nil) }
    public func sendAudio(_ data: Data, timing: AudioTiming) async throws { try await sendAndArchive(data, timing:timing) }
    private func sendAndArchive(_ data: Data, timing: AudioTiming?) async throws {
        let submitted = SessionLog.timestamp()
        if let timing { try await connection.sendAudio(data,timing:timing) }
        else { try await connection.sendAudio(data) }
        do { try archive.sent(data, epoch: epoch, submittedAt: submitted, timing: timing) }
        catch { throw AudioArchiveFailure(error) }
    }
    public func finish() async -> Bool { await connection.finish() }
    public func close() async { await connection.close() }
}
