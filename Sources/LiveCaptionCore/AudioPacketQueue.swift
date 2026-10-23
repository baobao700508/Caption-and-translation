import Foundation

public struct AudioTiming: Sendable {
    public let captureStartedAt: TimeInterval
    public let captureEndedAt: TimeInterval
    public let preparedAt: TimeInterval
    public init(captureStartedAt: TimeInterval, captureEndedAt: TimeInterval, preparedAt: TimeInterval) {
        self.captureStartedAt = captureStartedAt; self.captureEndedAt = captureEndedAt; self.preparedAt = preparedAt
    }
}
public struct CapturedAudio: Sendable {
    public let data: Data
    public let timing: AudioTiming
    public init(data: Data, timing: AudioTiming) { self.data = data; self.timing = timing }
}
public struct DiscardedAudio:Sendable {
    public let samples:Int
    public let startedAt:TimeInterval
    public let endedAt:TimeInterval
    public init(samples:Int,startedAt:TimeInterval,endedAt:TimeInterval) {
        self.samples=samples;self.startedAt=startedAt;self.endedAt=endedAt
    }
}

/// Wake immediately for fresh audio; coalesce already queued packets after a slow write.
/// This adds no batching timer and bounds both memory and stale-audio latency.
public final class AudioPacketQueue: @unchecked Sendable {
    public let signals: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let lock = NSLock()
    private var pending: [CapturedAudio] = []
    private var closed = false
    private let limit: Int
    private var overflow:DiscardedAudio?
    public init(limit: Int = 20) {
        self.limit = max(1,limit)
        var c: AsyncStream<Void>.Continuation!
        signals = AsyncStream(bufferingPolicy:.bufferingNewest(1)) { c = $0 }; continuation = c
    }
    /// Returns the number of discarded packets. Callers must report this as a gap.
    @discardableResult public func append(_ packet: CapturedAudio) -> Int {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return 1 }
        pending.append(packet)
        let dropped = max(0,pending.count-limit)
        if dropped > 0 {
            let removed=pending.prefix(dropped)
            overflow=DiscardedAudio(samples:(overflow?.samples ?? 0)+removed.reduce(0,{$0+$1.data.count/2}),startedAt:overflow?.startedAt ?? removed.first!.timing.captureStartedAt,endedAt:removed.last!.timing.captureEndedAt)
            pending.removeFirst(dropped)
        }
        continuation.yield(())
        return dropped
    }
    public func takeBatch(maxPackets: Int = Int.max) -> CapturedAudio? {
        lock.lock(); defer { lock.unlock() }
        guard !pending.isEmpty else { return nil }
        let count = min(pending.count,max(1,maxPackets))
        let group = pending.prefix(count)
        var data = Data(); for packet in group { data.append(packet.data) }
        let first = group.first!, last = group.last!
        let timing = AudioTiming(captureStartedAt:first.timing.captureStartedAt,captureEndedAt:last.timing.captureEndedAt,preparedAt:first.timing.preparedAt)
        pending.removeFirst(count)
        return CapturedAudio(data:data,timing:timing)
    }
    public func finish() { lock.lock(); closed = true; continuation.finish(); lock.unlock() }
    /// Counters/timestamps only: reporting an overflow must not create a second audio backlog.
    public func takeOverflow()->DiscardedAudio? {
        lock.lock();defer { lock.unlock() };let result=overflow;overflow=nil;return result
    }
    /// Drop whole frames that began before the cutover/freshness boundary. Never replay them.
    public func discard(before cutoff:TimeInterval) -> [CapturedAudio] {
        lock.lock();defer { lock.unlock() }
        let dropped=pending.filter { $0.timing.captureStartedAt < cutoff }
        pending.removeAll { $0.timing.captureStartedAt < cutoff }
        return dropped
    }
}
