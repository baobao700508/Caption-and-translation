import Foundation

/// Keeps the WebSocket lifecycle testable without sending credentials or audio to a cloud service.
public protocol RealtimeTransport: Actor {
    func open(_ request: URLRequest) async throws
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close() async
}
