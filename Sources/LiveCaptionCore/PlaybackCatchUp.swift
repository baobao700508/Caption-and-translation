import Foundation

public struct PlaybackCatchUpConfiguration: Codable, Sendable {
    public var enabled = true
    public var enterSeconds = 1.5
    public var exitSeconds = 0.75
    public var maximumRate = 1.5
    public var recoveryWindowSeconds = 20.0
    public var maximumBufferedSeconds = 120.0
    public init() {}
    public func validate() throws {
        guard [enterSeconds,exitSeconds,maximumRate,recoveryWindowSeconds,maximumBufferedSeconds].allSatisfy({ $0.isFinite }),
              exitSeconds >= 0, enterSeconds > exitSeconds, maximumRate >= 1, maximumRate <= 2,
              recoveryWindowSeconds >= 1, maximumBufferedSeconds >= max(10,enterSeconds) && maximumBufferedSeconds <= 600 else {
            throw CaptionError.message("译音追赶参数无效：进入水位须高于退出水位，最高语速为 1–2 倍，缓冲上限为 10–600 秒。")
        }
    }
}

/// Controls only already-received playback PCM. It never changes provider requests or arrival measurements.
public struct PlaybackCatchUpController: Sendable {
    public let configuration: PlaybackCatchUpConfiguration
    public private(set) var rate = 1.0
    public private(set) var catchingUp = false
    public private(set) var targetRate = 1.0
    public init(configuration: PlaybackCatchUpConfiguration = .init()) { self.configuration = configuration }
    public mutating func reset() { rate = 1; targetRate = 1; catchingUp = false }
    @discardableResult public mutating func update(queuedSeconds:Double,elapsedSeconds:Double) -> Double {
        guard configuration.enabled, queuedSeconds.isFinite, queuedSeconds > 0 else { reset(); return rate }
        if queuedSeconds > configuration.enterSeconds { catchingUp = true }
        else if queuedSeconds <= configuration.exitSeconds { catchingUp = false }
        targetRate = catchingUp ? min(configuration.maximumRate,1+max(0,queuedSeconds-configuration.exitSeconds)/configuration.recoveryWindowSeconds) : 1
        let elapsed = elapsedSeconds.isFinite ? min(1,max(0,elapsedSeconds)) : 0
        let step = (targetRate > rate ? 0.12 : 0.20)*elapsed
        rate += min(step,max(-step,targetRate-rate))
        return rate
    }
}
