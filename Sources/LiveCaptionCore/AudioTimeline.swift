import Foundation

/// 48kHz mono capture timeline. Host time identifies the first sample, not delivery time.
public struct AudioTimeline {
    private var blocks: [(Double, [Float])] = []
    private var latestEnd: Double?
    private var lastReceivedAt: Double?
    public init() {}
    public mutating func append(_ samples: [Float], at time: Double, receivedAt: Double) {
        guard !samples.isEmpty else { return }
        blocks.append((time, samples)); if blocks.count > 128 { blocks.removeFirst(blocks.count-128) }
        latestEnd = max(latestEnd ?? time,time+Double(samples.count)/48000)
        lastReceivedAt = receivedAt
    }
    public func canRead(at start: Double, frames: Int, now: Double) -> Bool {
        let end = start + Double(frames)/48000
        if let latestEnd, end <= latestEnd + 1.0/48000 { return true }
        // Normal callbacks can deliver 100ms at once. Absence of a future block is not a gap.
        // Only a genuinely stalled source times out, allowing the other lane to keep moving.
        return now - (lastReceivedAt ?? start) >= 0.25
    }
    public mutating func read(at start: Double, frames: Int) -> ([Float], Int) {
        let end = start+Double(frames)/48000
        blocks.removeAll { $0.0+Double($0.1.count)/48000 <= start }
        var result = [Float](repeating: 0, count: frames); var covered = 0
        for (time, samples) in blocks {
            if time >= end { break }
            let offset = Int(((time-start)*48000).rounded())
            let first = max(0,offset), last = min(frames,offset+samples.count)
            if last > first { for i in first..<last { result[i] = samples[i-offset] }; covered += last-first }
        }
        return (result,min(frames,covered))
    }
}
