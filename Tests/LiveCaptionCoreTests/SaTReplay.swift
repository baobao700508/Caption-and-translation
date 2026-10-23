import Foundation
import LiveCaptionCore

/// Accelerated text-event replay, not a new speech-provider or audio-latency test.
@MainActor enum SaTReplayVerifier {
    struct Event:Decodable {
        let track:String;let text:String;let replace:Bool;let finality:String
        let providerID:String?;let sourceProviderID:String?
    }
    struct Fixture:Decodable { let id:String;let route:String;let provenance:String;let events:[Event] }
    static func run(fixtureURL:URL,root:URL,python:String) async -> Int32 {
        do {
            let fixtures=try JSONDecoder().decode([Fixture].self,from:Data(contentsOf:fixtureURL))
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            var results:[[String:Any]]=[]
            for fixture in fixtures {
                var config=Configuration();config.captionReflow.enabled=true
                config.captionReflow.sat.pythonExecutable=python
                config.pipeline=["google","whisperKit"].contains(fixture.route) ? .transcribe:.translate
                config.transcribeProvider=fixture.route == "whisperKit" ? .whisperKit:.google
                config.translationMode=fixture.route == "speech" ? .speech:.subtitles
                let log=try SessionLog(configuration:config,rootOverride:root.appendingPathComponent(fixture.id))
                try await log.begin();try await log.beginEpoch(1,configuration:config)
                let coordinator=CaptionReflowCoordinator(debounce:0.05,minimumInterval:0)
                coordinator.onTrace = { try await log.reflowTrace($0) }
                var transcript=Transcript(),byteIdentical=true,unique=true,samples=0,maxImmediate=0.0
                coordinator.onChange = { rows, _ in
                    samples += 1
                    byteIdentical = byteIdentical && rows.map(\.source).joined().utf8.elementsEqual(transcript.captionParagraphs(epoch:1).map(\.source).joined().utf8)
                        && rows.map(\.translation).joined().utf8.elementsEqual(transcript.captionParagraphs(epoch:1).map(\.translation).joined().utf8)
                    unique = unique && Set(rows.map(\.id)).count == rows.count
                }
                let started=Date()
                for event in fixture.events {
                    let update=TextUpdate(track:event.track,text:event.text,replace:event.replace,
                        finality:TextFinality(rawValue:event.finality) ?? .unspecified,boundary:event.finality == "final",
                        providerID:event.providerID,sourceProviderID:event.sourceProviderID)
                    _=try await log.text(update,epoch:1)
                    _=transcript.apply(update,epoch:1,pipeline:config.pipeline)
                    let immediate=Date()
                    coordinator.update(transcript.captionParagraphs(epoch:1),configuration:config.captionReflow,context:"\(fixture.id):1:\(config.pipeline.rawValue)")
                    maxImmediate=max(maxImmediate,Date().timeIntervalSince(immediate))
                    try await Task.sleep(nanoseconds:2_000_000)
                }
                await coordinator.finish(timeout:120)
                let rows=coordinator.rows
                try await log.captionLayout(rows,providerGroupIDs:transcript.captionParagraphs(epoch:1).map(\.id),epoch:1,
                    model:config.captionReflow.activeModel,elapsed:Date().timeIntervalSince(started))
                try await log.finish(tailIncomplete:false)
                let valid=byteIdentical && unique && coordinator.status.hasPrefix("已整理")
                results.append(["id":fixture.id,"route":fixture.route,"provenance":fixture.provenance,"success":valid,
                    "every_projection_byte_identical":byteIdentical,"every_projection_unique_ids":unique,"projection_count":samples,
                    "event_count":fixture.events.count,"provider_groups":transcript.captionParagraphs(epoch:1).count,
                    "display_paragraphs":rows.count,"max_immediate_projection_ms":maxImmediate*1000,
                    "status":coordinator.status,"elapsed_seconds":Date().timeIntervalSince(started),"log_path":log.directory.path,
                    "rows":rows.map { ["source":$0.source,"translation":$0.translation] }])
                coordinator.reset()
            }
            let report:[String:Any]=["scope":"Actual SaT ONNX + production coordinator + recorded text-event replay. Accelerated replay; no new cloud calls, microphone capture, audio playback or speech latency measurement.","results":results]
            try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("results.json"))
            return results.allSatisfy { $0["success"] as? Bool == true } ? 0:1
        } catch { print("SaT 回放未完成：\(error.localizedDescription)");return 1 }
    }
}
