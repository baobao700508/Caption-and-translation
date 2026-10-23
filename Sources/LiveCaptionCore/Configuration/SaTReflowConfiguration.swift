import Foundation

public struct SaTReflowConfiguration: Codable, Equatable, Sendable {
    public var model = "sat-3l"
    public var pythonExecutable = "~/Library/Application Support/LiveCaption/SaT/runtime/bin/python3"
    public var paragraphThreshold = 0.2
    public var minimumCharacters = 120
    public var timeoutSeconds = 120.0
    public init() {}
    public static let models = ["sat-3l", "sat-3l-no-limited-lookahead", "sat-3l-sm", "sat-12l"]
    public func validate() throws {
        guard Self.models.contains(model), paragraphThreshold.isFinite, (0.01...0.99).contains(paragraphThreshold),
              (20...2000).contains(minimumCharacters), timeoutSeconds.isFinite, (5...600).contains(timeoutSeconds),
              pythonExecutable.hasPrefix("/") || pythonExecutable.hasPrefix("~/") else {
            throw CaptionError.message("请检查 SaT 模型、本地 Python 路径、段落阈值与最短段落长度")
        }
    }
}
