import Foundation

public protocol RealtimeTransport: Actor {
    func open(_ request: URLRequest) async throws
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close() async
}

