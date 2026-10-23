import Foundation

/// Old engine fields are ignored when decoding; SaT is the only supported route.
public enum CaptionReflowEngine:String,Codable,CaseIterable,Sendable { case sat }
public struct CaptionReflowConfiguration:Codable,Equatable,Sendable {
    public var enabled=false
    public var engine:CaptionReflowEngine { .sat }
    public var sat=SaTReflowConfiguration()
    public var activeModel:String { sat.model }
    public init() {}
    enum CodingKeys:String,CodingKey { case enabled,sat,engine }
    public init(from decoder:Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        enabled=try c.decodeIfPresent(Bool.self,forKey:.enabled) ?? false
        sat=try c.decodeIfPresent(SaTReflowConfiguration.self,forKey:.sat) ?? SaTReflowConfiguration()
    }
    public func encode(to encoder:Encoder) throws {
        var c=encoder.container(keyedBy:CodingKeys.self)
        try c.encode(enabled,forKey:.enabled);try c.encode(sat,forKey:.sat);try c.encode(engine,forKey:.engine)
    }
    public func validate() throws { try sat.validate() }
}
