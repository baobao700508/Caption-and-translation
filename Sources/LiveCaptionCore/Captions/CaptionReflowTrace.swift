import Foundation

/// Only JSON bodies and local decisions enter the trace; credentials and HTTP headers never do.
public struct CaptionReflowTrace: Sendable {
    public typealias Sink = @Sendable (CaptionReflowTrace) async throws -> Void
    public let event:String
    public let data:Data
    public init(_ event:String, _ fields:[String:Any]) throws {
        self.event=event
        data=try JSONSerialization.data(withJSONObject:fields,options:[.sortedKeys,.withoutEscapingSlashes])
    }
    public var fields:[String:Any] { (try? JSONSerialization.jsonObject(with:data)) as? [String:Any] ?? [:] }
}

