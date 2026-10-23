import Foundation

public enum CaptionReflowClient {
    public static func complete(_ input:CaptionReflowInput,configuration:CaptionReflowConfiguration,trace:CaptionReflowTrace.Sink?=nil) async throws -> String {
        try configuration.validate()
        return try await SaTCaptionReflow.complete(input,configuration:configuration.sat,trace:trace)
    }
}
