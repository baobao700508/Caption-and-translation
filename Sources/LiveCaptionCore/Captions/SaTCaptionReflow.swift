import Foundation

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
            let reason:String
            if groups.count>=63 { reason="maximum_groups_reached" }
            else if length<c.minimumCharacters || remaining<c.minimumCharacters { reason="keep_coherent_paragraph" }
            else if probability>=c.paragraphThreshold { reason="selected" }
            else { reason="below_paragraph_threshold" }
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
