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
