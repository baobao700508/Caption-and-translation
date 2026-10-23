import AppKit
import SwiftUI
import Vision
import LiveCaptionCore

/// Real configured text-model calls through the same client, coordinator and view as production.
@MainActor enum CaptionReflowSmoke {
    static func run(output:String,configurationPath:String,fixturePath:String,session:AppSession) async {
        session.verificationInProgress=true
        let root=URL(fileURLWithPath:output).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        var checks:[String:Bool]=[:],samples:[[String:Any]]=[],failure:String?
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:900,height:500),styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false
        let view=NSHostingView(rootView:CaptionView(session:session)); window.contentView=view
        window.orderFrontRegardless()
        func capture(_ name:String) async -> String {
            try? await Task.sleep(nanoseconds:180_000_000)
            view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
            guard let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) else { return "" }
            view.cacheDisplay(in:view.bounds,to:bitmap)
            if let data=bitmap.representation(using:.png,properties:[:]) { try? data.write(to:root.appendingPathComponent(name+".png")) }
            let request=VNRecognizeTextRequest(); request.recognitionLanguages=["zh-Hans","en-US"]; request.recognitionLevel = .accurate
            if let image=bitmap.cgImage { try? VNImageRequestHandler(cgImage:image).perform([request]) }
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator:"\n")
        }
        do {
            let loaded=try Configuration.load(from:URL(fileURLWithPath:configurationPath))
            session.config=Configuration(); session.config.captionReflow=loaded.captionReflow
            session.config.pipeline = .translate; session.config.subtitleLayout = .bilingual
            session.sessionStartedAt=Date(); session.fontSize=23; session.followsLatestCaption=true
            try loaded.captionReflow.validate()
            let data=try Data(contentsOf:URL(fileURLWithPath:fixturePath))
            guard let fixtures=try JSONSerialization.jsonObject(with:data) as? [[String:Any]],!fixtures.isEmpty else { throw CaptionError.message("缺少测试文字") }
            let log=try SessionLog(configuration:session.config,rootOverride:root.appendingPathComponent("logs"))
            try await log.begin(); try await log.beginEpoch(1,configuration:session.config)
            session.useLayoutLogger(log)
            var transcript=Transcript()
            for (index,fixture) in fixtures.enumerated() {
                let source=fixture["source"] as? String ?? "", translation=fixture["translation"] as? String ?? "",n=index+1
                _=try await log.text(TextUpdate(track:"source",text:source,replace:true,finality:.final,boundary:true,providerID:"s\(n)"),epoch:1)
                transcript=try await log.text(TextUpdate(track:"translation",text:translation,replace:true,finality:.final,boundary:true,providerID:"t\(n)",sourceProviderID:"s\(n)"),epoch:1)
                let started=Date()
                session.displayTranscript(transcript,epoch:1,pipeline:.translate)
                let immediate=Date().timeIntervalSince(started)
                let rawShown=session.captionParagraphs.map(\.source).joined().contains(source) && session.captionParagraphs.map(\.translation).joined().contains(translation)
                checks["sample_\(n)_shown_synchronously"] = rawShown && immediate<0.1
                try await log.flush()
                let beforeLog=try String(contentsOf:log.directory.appendingPathComponent("transcript.md"))
                checks["sample_\(n)_logged_without_waiting"] = beforeLog.contains(source) && beforeLog.contains(translation)
                let beforeRender=await capture("sample-\(n)-before")
                while session.captionReflow.pending && Date().timeIntervalSince(started)<35 { try await Task.sleep(nanoseconds:25_000_000) }
                let elapsed=Date().timeIntervalSince(started)
                let raw=transcript.captionParagraphs(epoch:1),rows=session.captionParagraphs
                checks["sample_\(n)_reflow_applied"] = !session.captionReflow.pending && session.reflowStatus.contains("SaT")
                checks["sample_\(n)_lossless_source"] = Array(rows.map(\.source).joined().utf8) == Array(raw.map(\.source).joined().utf8)
                checks["sample_\(n)_lossless_translation"] = Array(rows.map(\.translation).joined().utf8) == Array(raw.map(\.translation).joined().utf8)
                let afterRender=await capture("sample-\(n)-after")
                checks["sample_\(n)_no_hidden_expand_control"] = !afterRender.contains("展开本段")
                try await log.captionLayout(rows,providerGroupIDs:raw.map(\.id),epoch:1,model:loaded.captionReflow.activeModel,elapsed:elapsed)
                samples.append(["sample":n,"first_projection_ms":immediate*1000,"reflow_wait_seconds":elapsed,"attempts":session.captionReflow.attemptCount,"status":session.reflowStatus,
                    "input_source":source,"input_translation":translation,"rows":rows.map { ["source":$0.source,"translation":$0.translation] },
                    "before_ocr":beforeRender,"after_ocr":afterRender])
            }
            // Block counts are observations, not semantic correctness assertions: C is allowed.
            let observedFinalBlocks=session.captionParagraphs.count
            session.config.subtitleLayout = .source
            let sourceOnly=await capture("source-only")
            session.config.subtitleLayout = .translation
            let translationOnly=await capture("translation-only")
            checks["source_and_translation_views_differ"] = sourceOnly != translationOnly
            session.config.subtitleLayout = .bilingual; session.config.translationMode = .speech
            _=await capture("speech-mode")
            checks["speech_shares_same_reflow_view"] = session.captionParagraphs == session.captionReflow.rows
            // An independent Transcribe epoch runs through the same generic one-track path.
            session.config.pipeline = .transcribe
            var mono=Transcript()
            let monoText="FirstCheckpoint. The teacher explains supply and demand. Lower prices can increase demand. LastCheckpoint."
            _=mono.apply(TextUpdate(track:"source",text:monoText,replace:true,finality:.final,boundary:true,providerID:"mono"),epoch:2,pipeline:.transcribe)
            session.displayTranscript(mono,epoch:2,pipeline:.transcribe)
            let monoStart=Date()
            while session.captionReflow.pending && Date().timeIntervalSince(monoStart)<35 { try await Task.sleep(nanoseconds:25_000_000) }
            checks["transcribe_model_reflow"] = session.reflowStatus.contains("SaT")
            checks["transcribe_no_generated_translation"] = session.captionParagraphs.allSatisfy { $0.translation.isEmpty } && session.captionParagraphs.map(\.source).joined() == monoText
            _=await capture("transcribe")
            await session.captionReflow.finish();try await log.finish(tailIncomplete:false)
            samples.append(["observed_final_bilingual_blocks":observedFinalBlocks,"semantic_quality":"Inspect the actual bilingual rows; block count alone does not prove alignment quality."])
            var changed=loaded.captionReflow; changed.enabled=false; changed.sat.minimumCharacters=160
            let savedURL=FileManager.default.temporaryDirectory.appendingPathComponent("LiveCaption-reflow-save-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at:savedURL) }
            try Data(#"{"pipeline":"transcribe","keepThisField":"unchanged"}"#.utf8).write(to:savedURL)
            try await session.saveReflowConfiguration(changed,fileURL:savedURL)
            let saved=try JSONSerialization.jsonObject(with:Data(contentsOf:savedURL)) as! [String:Any]
            checks["sat_parameter_saved_without_changing_other_config"] = ((saved["captionReflow"] as? [String:Any])?["sat"] as? [String:Any])?["minimumCharacters"] as? Int == changed.sat.minimumCharacters && saved["keepThisField"] as? String == "unchanged" && saved["pipeline"] as? String == "transcribe"
            session.config.captionReflow=loaded.captionReflow
            let preferences=NSHostingView(rootView:PreferencesView(session:session))
            window.contentView=preferences
            window.setContentSize(NSSize(width:900,height:850)); session.settingsSection = .appearance
            try await Task.sleep(nanoseconds:350_000_000)
            func scrollToBottom(_ parent:NSView) {
                if let scroll=parent as? NSScrollView,let document=scroll.documentView {
                    scroll.contentView.scroll(to:NSPoint(x:0,y:max(0,document.bounds.height-scroll.contentView.bounds.height)))
                    scroll.reflectScrolledClipView(scroll.contentView)
                } else { parent.subviews.forEach(scrollToBottom) }
            }
            scrollToBottom(preferences)
            try await Task.sleep(nanoseconds:200_000_000)
            if let bitmap=preferences.bitmapImageRepForCachingDisplay(in:preferences.bounds) {
                preferences.cacheDisplay(in:preferences.bounds,to:bitmap)
                if let png=bitmap.representation(using:.png,properties:[:]) { try png.write(to:root.appendingPathComponent("model-settings.png")) }
                let request=VNRecognizeTextRequest(); request.recognitionLanguages=["zh-Hans","en-US"]
                if let image=bitmap.cgImage { try VNImageRequestHandler(cgImage:image).perform([request]) }
                let text=(request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator:"\n")
                checks["model_settings_visible"] = text.contains("Python") && !text.contains("保存重排配置") && !text.contains("JEV")
            }
        } catch { failure="文字重排验证失败：\(session.config.redacted(error.localizedDescription))" }
        session.captionReflow.cancel()
        let result:[String:Any] = ["success":failure == nil && checks.values.allSatisfy{$0},"checks":checks,"samples":samples,
            "engine":session.config.captionReflow.engine.rawValue,"model":session.config.captionReflow.activeModel,"failure":failure as Any? ?? NSNull(),
            "scope":"真实配置的分段 API、生产字幕投影和原生渲染、运行中日志；未采集或上传音频，不代表语音识别延迟"]
        if let data=try? JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]) { try? data.write(to:URL(fileURLWithPath:output)) }
        window.close()
    }
}
