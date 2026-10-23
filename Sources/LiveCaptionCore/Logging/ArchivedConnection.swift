import Foundation

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
