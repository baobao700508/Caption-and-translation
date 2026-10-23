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

public struct CaptionReflowInput:Sendable {
    public let source:[String]
    public let translation:[String]
    public let providerBoundaries:[[Int]]
    public init(source:String,translation:String,providerBoundaries:[[Int]] = []) {
        self.source=Self.atoms(source);self.translation=Self.atoms(translation)
        self.providerBoundaries=providerBoundaries
    }
    private static func atoms(_ text:String) -> [String] {
        var result:[String] = [],word="",opening="",doubleQuoteOpen=false
        func flush() { if !word.isEmpty { result.append(opening+word); opening="";word="" } }
        // Iterating Character (not regex scalar offsets) keeps combining marks and emoji intact.
        for character in text {
            let part=String(character)
            let opens=["(","[","{","（","【","《","〈","「","『","“","‘"].contains(part) || (part == "\"" && !doubleQuoteOpen)
            if part == "\"" { doubleQuoteOpen.toggle() }
            if opens { flush();opening += part;continue }
            let wordCharacter=part.unicodeScalars.allSatisfy {
                $0.value < 0x2E80 && (CharacterSet.alphanumerics.contains($0) || CharacterSet.nonBaseCharacters.contains($0))
            }
            if wordCharacter || (!word.isEmpty && ["'","’","-"].contains(part)) { word += part; continue }
            flush()
            if !opening.isEmpty {
                if part.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) { opening += part }
                else { result.append(opening+part);opening="" }
            } else if !result.isEmpty && part.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.punctuationCharacters.contains($0) }) {
                result[result.count-1] += part
            } else { result.append(part) }
        }
        flush()
        if !opening.isEmpty { result.append(opening) }
        return result
    }
    public func render(_ response:String, id:String) throws -> [CaptionParagraph] {
        // Accept code fences without imposing a server response_format or tool schema.
        guard response.utf8.count <= 65536, let start = response.firstIndex(of:"{"), let end = response.lastIndex(of:"}"), start <= end else {
            throw CaptionError.message("重排结果没有可读取的分组")
        }
        struct Plan: Decodable { let groups:[[Int]] }
        let plan = try JSONDecoder().decode(Plan.self,from:Data(response[start...end].utf8))
        guard !plan.groups.isEmpty, plan.groups.count <= 64 else { throw CaptionError.message("重排分组数量无效") }
        var s = 0, t = 0, rows:[CaptionParagraph] = []
        for (i,pair) in plan.groups.enumerated() {
            guard pair.count == 2 else { throw CaptionError.message("重排切点格式无效") }
            let se = pair[0], te = pair[1]
            guard (source.isEmpty ? se == 0 : se > s && se <= source.count),
                  (translation.isEmpty ? te == 0 : te > t && te <= translation.count) else {
                throw CaptionError.message("重排切点越界、重复或乱序")
            }
            rows.append(CaptionParagraph(id:"\(id):\(i)",source:source[s..<se].joined(),translation:translation[t..<te].joined(),isFinal:true))
            s = se; t = te
        }
        guard s == source.count, t == translation.count,
              Array(rows.map(\.source).joined().utf8) == Array(source.joined().utf8),
              Array(rows.map(\.translation).joined().utf8) == Array(translation.joined().utf8) else {
            throw CaptionError.message("重排未完整保留原文与译文")
        }
        return rows
    }
}

public enum CaptionReflowClient {
    public static func complete(_ input:CaptionReflowInput,configuration:CaptionReflowConfiguration,trace:CaptionReflowTrace.Sink?=nil) async throws -> String {
        try configuration.validate()
        return try await SaTCaptionReflow.complete(input,configuration:configuration.sat,trace:trace)
    }
}

/// Disabling SaT projects the original provider-linked segments without merging or splitting.
@MainActor public final class CaptionReflowCoordinator {
    public typealias Complete = @Sendable (CaptionReflowInput,CaptionReflowConfiguration) async throws -> String
    public var onChange:(([CaptionParagraph],String)->Void)?
    public var onApplied:(([String],[CaptionParagraph],Double)->Void)?
    public var onTrace:CaptionReflowTrace.Sink?
    public private(set) var rows:[CaptionParagraph]=[]
    public private(set) var status="未启用"
    public private(set) var pending=false
    public private(set) var attemptCount=0
    private var sat:SaTReflowCoordinator?
    private let debounce:TimeInterval
    private let complete:Complete?
    private var audits:[UUID:Task<Void,Never>]=[:]
    private var providerSignature:[CaptionParagraph]=[]
    private var providerContext=""
    public init(partialInterval:TimeInterval=0,debounce:TimeInterval=0.4,minimumInterval:TimeInterval=0,complete:Complete?=nil) {
        self.debounce=debounce;self.complete=complete
    }
    public func cancel() {
        if pending,let trace=onTrace { audit(trace,"caption.reflow.discarded",["reason":"disabled_configuration_changed_or_stop"]) }
        sat?.reset();sat=nil;pending=false
    }
    public func reset() {
        cancel();rows=[];status="未启用";attemptCount=0;providerSignature=[];providerContext=""
    }
    public func update(_ incoming:[CaptionParagraph],configuration:CaptionReflowConfiguration,context:String) {
        guard configuration.enabled else {
            cancel();rows=incoming;status="未启用 · 按服务器语段显示"
            onChange?(rows,status)
            if providerSignature != incoming || providerContext != context {
                providerSignature=incoming;providerContext=context
                if let trace=onTrace { audit(trace,"caption.presentation.changed",[
                    "context":context,"display_policy":"provider_groups","provider_group_ids":incoming.map(\.id),
                    "row_ids":incoming.map(\.id),"provider_group_count":incoming.count,"display_row_count":incoming.count,"byte_identical":true]) }
            }
            return
        }
        if sat == nil {
            let coordinator=SaTReflowCoordinator(debounce:debounce,complete:complete)
            coordinator.onChange={ [weak self,weak coordinator] rows,status,pending in
                guard let self,let coordinator else { return }
                self.rows=rows;self.status=rows.isEmpty ? "SaT 已开启，等待文字":status
                self.pending=pending;self.attemptCount=coordinator.attemptCount
                self.onChange?(rows,self.status)
            }
            coordinator.onApplied={ [weak self] ids,rows,seconds in self?.onApplied?(ids,rows,seconds) }
            sat=coordinator
        }
        sat?.onTrace=onTrace
        sat?.update(incoming,configuration:configuration,context:context)
    }
    public func finish(timeout:TimeInterval=20) async {
        await sat?.finish(timeout:timeout)
        for task in Array(audits.values) { await task.value }
    }
    private func audit(_ sink:@escaping CaptionReflowTrace.Sink,_ event:String,_ fields:[String:Any]) {
        guard let trace=try? CaptionReflowTrace(event,fields) else { return }
        let id=UUID()
        audits[id]=Task { [weak self] in
            do { try await sink(trace) }
            catch { self?.status="分段行为日志写入失败，保留字幕" }
            self?.audits.removeValue(forKey:id)
        }
    }
}
