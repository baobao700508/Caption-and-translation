import Foundation

/// Old engine fields are ignored when decoding; SaT is the only supported route.
public enum CaptionReflowClient {
    public static func complete(_ input:CaptionReflowInput,configuration:CaptionReflowConfiguration,trace:CaptionReflowTrace.Sink?=nil) async throws -> String {
        try configuration.validate()
        return try await SaTCaptionReflow.complete(input,configuration:configuration.sat,trace:trace)
    }
}

/// Disabling SaT projects the original provider-linked segments without merging or splitting.
