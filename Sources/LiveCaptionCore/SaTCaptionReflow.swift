import Foundation

public struct SaTReflowConfiguration: Codable, Equatable, Sendable {
    public var model = "sat-3l"
    public var pythonExecutable = "~/Library/Application Support/LiveCaption/SaT/runtime/bin/python3"
    public var paragraphThreshold = 0.5
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

public enum SaTCaptionReflow {
    public typealias Infer = @Sendable (Data, SaTReflowConfiguration) async throws -> Data
    public static func complete(_ input:CaptionReflowInput, configuration c:SaTReflowConfiguration,
                                trace:CaptionReflowTrace.Sink?=nil,
                                infer:@escaping Infer = { try await SaTLocalRuntime.shared.infer($0,configuration:$1) }) async throws -> String {
        try c.validate()
        func emit(_ event:String,_ fields:[String:Any]) async throws {
            try await trace?(CaptionReflowTrace(event,fields.merging(["engine":"sat","configured_model":c.model,
                "paragraph_threshold":c.paragraphThreshold,"minimum_characters":c.minimumCharacters,
                "alignment_policy":"explicit_provider_links_only","input_policy":"final_only"]) { old,_ in old }))
        }
        let request=try JSONSerialization.data(withJSONObject:["version":1,"model":c.model,
            "source":input.source,"translation":input.translation],options:[.sortedKeys])
        try await emit("caption.sat.request",["source":input.source.joined(),"translation":input.translation.joined(),
            "provider_boundaries":input.providerBoundaries,"local_only":true])
        if input.source.joined().count>24000 || input.translation.joined().count>24000 {
            try await emit("caption.sat.retained",["reason":"single_provider_group_exceeds_local_window",
                "action":"keep_group_intact_and_continue_with_following_groups"])
            return "{\"groups\":[[\(input.source.count),\(input.translation.count)]]}"
        }
        let started=Date()
        let data=try await infer(request,c)
        try Task.checkCancellation()
        struct Score:Decodable { let end:Int; let probability:Double }
        struct Response:Decodable {
            let version:Int; let model:String?; let source:[Score]?; let translation:[Score]?
            let error_type:String?; let cold_start:Bool?; let load_seconds:Double?; let inference_seconds:Double?
            let execution_provider:String?
        }
        guard data.count <= 2_097_152 else { throw CaptionError.message("SaT 响应超过安全上限") }
        let response=try JSONDecoder().decode(Response.self,from:data)
        guard response.error_type == nil,response.version == 1,response.model == c.model,
              let source=response.source,let translation=response.translation else {
            throw CaptionError.message("SaT 本地推理失败，请先运行 setup-sat.sh 准备环境")
        }
        func scores(_ items:[Score],count:Int) throws -> [Int:Double] {
            var result:[Int:Double]=[:]
            for item in items {
                guard (1...max(1,count)).contains(item.end),count>0,result[item.end] == nil,
                      item.probability.isFinite,(0...1).contains(item.probability) else {
                    throw CaptionError.message("SaT 返回了无效的段落概率")
                }
                result[item.end]=item.probability
            }
            return result
        }
        let ss=try scores(source,count:input.source.count),ts=try scores(translation,count:input.translation.count)
        let mono=input.source.isEmpty || input.translation.isEmpty
        let candidates:[[Int]]
        if mono { candidates = (input.source.isEmpty ? translation:source).map { input.source.isEmpty ? [0,$0.end]:[$0.end,0] } }
        else { candidates=input.providerBoundaries }
        var groups:[[Int]]=[],decisions:[[String:Any]]=[],s=0,t=0
        func cumulative(_ atoms:[String])->[Int] {
            var values=[0];for atom in atoms { values.append(values.last!+atom.count) };return values
        }
        let sourceSizes=cumulative(input.source),translationSizes=cumulative(input.translation)
        for point in candidates {
            guard point.count == 2 else { throw CaptionError.message("SaT 原译关联边界格式无效") }
            let se=point[0],te=point[1]
            guard se>=s,te>=t,se<=input.source.count,te<=input.translation.count,
                  (input.source.isEmpty ? se == 0:se>s), (input.translation.isEmpty ? te == 0:te>t),
                  se<input.source.count || te<input.translation.count else { continue }
            let sp=ss[se] ?? 0,tp=ts[te] ?? 0,probability=max(sp,tp)
            let length=sourceSizes[se]-sourceSizes[s]+translationSizes[te]-translationSizes[t]
            let remaining=sourceSizes.last!-sourceSizes[se]+translationSizes.last!-translationSizes[te]
            let reason=groups.count>=63 ? "maximum_groups_reached":(probability<c.paragraphThreshold ? "below_paragraph_threshold":
                (length<c.minimumCharacters || remaining<c.minimumCharacters ? "keep_coherent_paragraph":"selected"))
            decisions.append(["source_end":se,"translation_end":te,"source_probability":sp,"translation_probability":tp,
                              "characters":length,"remaining_characters":remaining,"decision":reason])
            if reason == "selected" && groups.count<63 { groups.append(point);s=se;t=te }
        }
        groups.append([input.source.count,input.translation.count])
        try await emit("caption.sat.selection",["decisions":decisions,"groups":groups,
            "source_probabilities":source.map { ["end":$0.end,"probability":$0.probability] as [String:Any] },
            "translation_probabilities":translation.map { ["end":$0.end,"probability":$0.probability] as [String:Any] },
            "cold_start":response.cold_start ?? false,"load_seconds":response.load_seconds ?? 0,
            "inference_seconds":response.inference_seconds ?? 0,"elapsed_seconds":Date().timeIntervalSince(started),
            "execution_provider":response.execution_provider ?? "unknown",
            "retained_reason":groups.count == 1 ? (mono ? "no_supported_paragraph_boundary":"no_supported_boundary_between_linked_groups"):"paragraph_boundaries_selected"])
        return String(decoding:try JSONSerialization.data(withJSONObject:["groups":groups]),as:UTF8.self)
    }
}

/// One persistent local worker, serialized on its own queue. No pipe I/O runs on the main actor.
/// Cancellation/timeout kills that worker so a stale response cannot enter the next request.
public final class SaTLocalRuntime: @unchecked Sendable {
    public static let shared = SaTLocalRuntime()
    private let queue=DispatchQueue(label:"local.livecaption.sat",qos:.utility)
    private let lock=NSLock()
    private var process:Process?
    private var input:FileHandle?
    private var output:FileHandle?
    private var python=""
    private var active:UUID?
    private var cancelled=Set<UUID>()
    private init() {}
    public func infer(_ request:Data,configuration c:SaTReflowConfiguration) async throws -> Data {
        let id=UUID()
        return try await withTaskCancellationHandler(operation:{
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do { continuation.resume(returning:try self.exchange(request,configuration:c,id:id)) }
                    catch { continuation.resume(throwing:error) }
                }
            }
        },onCancel:{ self.cancel(id) })
    }
    private func cancel(_ id:UUID) {
        lock.lock();cancelled.insert(id);let worker=active == id ? process:nil;lock.unlock()
        if let worker,worker.isRunning { worker.terminate() }
    }
    private func exchange(_ request:Data,configuration c:SaTReflowConfiguration,id:UUID) throws -> Data {
        lock.lock();let wasCancelled=cancelled.contains(id);active=id;lock.unlock()
        defer { lock.lock();active=nil;cancelled.remove(id);lock.unlock() }
        if wasCancelled { throw CancellationError() }
        let executable=(c.pythonExecutable as NSString).expandingTildeInPath
        guard FileManager.default.isExecutableFile(atPath:executable) else {
            throw CaptionError.message("SaT 本地环境未准备，请先运行 scripts/setup-sat.sh")
        }
        if process?.isRunning != true || python != executable {
            if let process,process.isRunning { process.terminate() }
            let worker=Process(),stdin=Pipe(),stdout=Pipe()
            let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let script=Bundle.main.url(forResource:"sat-worker",withExtension:"py") ?? root.appendingPathComponent("scripts/sat-worker.py")
            guard FileManager.default.fileExists(atPath:script.path) else { throw CaptionError.message("缺少 SaT 本地推理脚本") }
            worker.executableURL=URL(fileURLWithPath:executable);worker.arguments=["-u",script.path]
            worker.standardInput=stdin;worker.standardOutput=stdout;worker.standardError=FileHandle.nullDevice
            try worker.run()
            lock.lock();process=worker;let stopped=cancelled.contains(id);lock.unlock()
            if stopped { worker.terminate();throw CancellationError() }
            input=stdin.fileHandleForWriting;output=stdout.fileHandleForReading;python=executable
        }
        guard let worker=process,let input,let output else { throw CaptionError.message("SaT 本地进程未启动") }
        let deadline=DispatchWorkItem { if worker.isRunning { worker.terminate() } }
        DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now()+c.timeoutSeconds,execute:deadline)
        defer { deadline.cancel() }
        do {
            try input.write(contentsOf:request+Data([10]))
            var result=Data()
            while !result.contains(10),result.count<=2_097_152 {
                let chunk=output.availableData
                guard !chunk.isEmpty else { throw CaptionError.message("SaT 进程退出或推理超时，完整字幕已保留") }
                result.append(chunk)
            }
            guard result.count<=2_097_152,let end=result.firstIndex(of:10),end == result.count-1 else {
                throw CaptionError.message("SaT 本地响应格式无效")
            }
            lock.lock();let stopped=cancelled.contains(id);lock.unlock()
            if stopped { throw CancellationError() }
            return result.prefix(upTo:end)
        } catch {
            if worker.isRunning { worker.terminate() }
            self.input=nil;self.output=nil
            throw error
        }
    }
}
