import Foundation
import LiveCaptionCore

@MainActor enum CaptionReflowControlSmoke {
    static func run(session:AppSession) async -> [String:Bool] {
        var checks:[String:Bool]=[:]
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("reflow-control-\(UUID())")
        defer { try? FileManager.default.removeItem(at:root) }
        do {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            let url=root.appendingPathComponent("config.json")
            try Data(#"{"pipeline":"transcribe","untouched":"keep"}"#.utf8).write(to:url)
            session.config.captionReflow.enabled=true
            session.config.captionReflow.sat.pythonExecutable="" // Disabling must work even with invalid model parameters.
            let binding=CaptionReflowSettings.enabledBinding(session:session,fileURL:url)
            binding.wrappedValue=false
            checks["reflow_switch_off_without_save_stops_runtime_immediately"] = !session.config.captionReflow.enabled && !session.captionReflow.pending && session.reflowStatus.hasPrefix("未启用")
            await session.reflowSettingsSave?.value
            checks["reflow_switch_off_auto_saved"] = try Configuration.load(from:url).captionReflow.enabled == false
            checks["reflow_reopened_switch_reads_runtime"] = !CaptionReflowSettings.enabledBinding(session:session,fileURL:url).wrappedValue

            session.config.captionReflow.sat=SaTReflowConfiguration()
            binding.wrappedValue=true
            let earlierSave=session.reflowSettingsSave
            binding.wrappedValue=false
            let latestSave=session.reflowSettingsSave
            await earlierSave?.value;await latestSave?.value
            let afterRapid=try Configuration.load(from:url)
            checks["reflow_rapid_on_off_cannot_restore_old_state"] = !session.config.captionReflow.enabled && !afterRapid.captionReflow.enabled
            let stored=try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any]
            checks["reflow_auto_save_preserves_other_configuration"] = stored?["untouched"] as? String == "keep" && stored?["pipeline"] as? String == "transcribe"

            let threshold=CaptionReflowSettings.parameterBinding(session:session,\.paragraphThreshold,fileURL:url)
            threshold.wrappedValue=0.65
            let minimum=CaptionReflowSettings.parameterBinding(session:session,\.minimumCharacters,fileURL:url)
            minimum.wrappedValue=180
            await session.reflowSettingsSave?.value
            let parameters=try Configuration.load(from:url).captionReflow
            checks["sat_parameters_auto_saved_without_button"] = parameters.sat.paragraphThreshold == 0.65 && parameters.sat.minimumCharacters == 180 && !parameters.enabled
            // A delayed parameter save cannot re-enable the feature after the user turns it off.
            binding.wrappedValue=true
            minimum.wrappedValue=200
            binding.wrappedValue=false
            await session.reflowSettingsSave?.value
            let disabled=try Configuration.load(from:url).captionReflow
            checks["sat_parameter_save_then_off_stays_off"] = !disabled.enabled && disabled.sat.minimumCharacters == 200

            var transcript=Transcript()
            _=transcript.apply(TextUpdate(track:"source",text:"The lesson continues after disabling layout.",replace:true,finality:.final,boundary:true,providerID:"off-source"),epoch:1,pipeline:.transcribe)
            session.displayTranscript(transcript,epoch:1,pipeline:.transcribe)
            let attempts=session.captionReflow.attemptCount
            try await Task.sleep(nanoseconds:450_000_000)
            checks["reflow_off_keeps_new_text_without_new_jobs"] = !session.captionReflow.pending && session.captionReflow.attemptCount == attempts && session.captionParagraphs.map(\.source).joined().contains("lesson continues")

            // Disk failure must not roll runtime back to enabled.
            session.config.captionReflow.enabled=true
            session.setReflowEnabled(false,fileURL:root.appendingPathComponent("missing/config.json"))
            await session.reflowSettingsSave?.value
            checks["reflow_save_failure_stays_off_and_reports_failure"] = !session.config.captionReflow.enabled && !session.captionReflow.pending && session.errorMessage?.contains("自动保存失败") == true
            session.errorMessage=nil

            let writer=CaptionReflowSettingsWriter()
            var newest=CaptionReflowConfiguration();newest.enabled=false
            _=try await writer.save(newest,revision:2,url:url)
            var stale=newest;stale.enabled=true
            let rejected=try await writer.save(stale,revision:1,url:url)
            let afterStale=try Configuration.load(from:url)
            checks["reflow_writer_rejects_late_older_save"] = rejected == nil && !afterStale.captionReflow.enabled
        } catch { checks["reflow_control_smoke_completed"]=false }
        session.captionReflow.reset()
        return checks
    }
}
