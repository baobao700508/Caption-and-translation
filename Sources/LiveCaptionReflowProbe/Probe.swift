import Foundation
import LiveCaptionCore

/// Runs the exact production Decisions client on frozen, attributed bilingual transcripts.
/// Input: [{id, source, translation, split?, audio_path?, provenance?}], never credentials.
@main struct Probe {
    static func main() async {
        let args=CommandLine.arguments
        guard args.count == 4 else { print("用法：LiveCaptionReflowProbe 配置.json 样本.json 输出目录");exit(2) }
        let root=URL(fileURLWithPath:args[3])
        do {
            let config=try Configuration.load(from:URL(fileURLWithPath:args[1]))
            try config.captionReflow.validate()
            guard let fixtures=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:args[2]))) as? [[String:Any]] else { throw CaptionError.message("样本必须是 JSON 数组") }
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            var results:[[String:Any]]=[]
            for (index,fixture) in fixtures.enumerated() {
                let input=CaptionReflowInput(source:fixture["source"] as? String ?? "",translation:fixture["translation"] as? String ?? "")
                let id=fixture["id"] as? String ?? "sample-\(index)"
                let log=try SessionLog(configuration:config,rootOverride:root.appendingPathComponent("sample-\(index)"))
                try await log.begin();try await log.beginEpoch(1,configuration:config)
                let started=Date()
                var result:[String:Any]=["id":id,"fixture_index":index,"input_source":input.source.joined(),"input_translation":input.translation.joined(),
                    "engine":config.captionReflow.engine.rawValue,"model":config.captionReflow.activeModel,"log_path":log.directory.path]
                for key in ["split","audio_path","provenance","expected_groups","expected_unsplit_source_spans"] { result[key]=fixture[key] }
                do {
                    let response=try await CaptionReflowClient.complete(input,configuration:config.captionReflow,trace:{ try await log.reflowTrace($0) })
                    let rows=try input.render(response,id:id)
                    try await log.captionLayout(rows,providerGroupIDs:[id],epoch:1,model:config.captionReflow.activeModel,elapsed:Date().timeIntervalSince(started))
                    result["success"]=true;result["byte_identical"]=true
                    result["rows"]=rows.map { ["source":$0.source,"translation":$0.translation] }
                    print("\(id): \(rows.count) 块，\(String(format:"%.3f",Date().timeIntervalSince(started))) 秒")
                } catch {
                    result["success"]=false;result["failure"]=config.redacted(error.localizedDescription)
                    print("\(id): 未完成，证据保留")
                }
                result["elapsed_seconds"]=Date().timeIntervalSince(started)
                try await log.finish(tailIncomplete:false)
                results.append(result)
                try JSONSerialization.data(withJSONObject:results,options:[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]).write(to:root.appendingPathComponent("results.json"),options:.atomic)
            }
            exit(results.allSatisfy { $0["success"] as? Bool == true } ? 0:1)
        } catch { print("分段测试未完成；请检查配置和样本，不输出凭据或服务响应正文。");exit(1) }
    }
}
