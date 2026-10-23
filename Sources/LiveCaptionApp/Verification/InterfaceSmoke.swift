import Foundation
import AppKit
import SwiftUI
import Vision
import LiveCaptionCore

/// Exercises actual native window controllers without calling a model or starting audio capture.
@MainActor enum InterfaceSmoke {
    static func run(output:String,session:AppSession) async {
        session.verificationInProgress = true
        var config = Configuration(); config.pipeline = .translate
        config.bailianWorkspaceID = "interface-check"; config.bailianAPIKey = "interface-test-not-a-real-key"
        session.config = config; session.configurationReady = true
        let initialRun = session.running
        var results:[String:Bool] = [:]
        results.merge(await CaptionReflowControlSmoke.run(session:session)) { _,new in new }
        session.captionParagraphs=[]
        session.config=config
        session.showSubtitles()
        let fullFrame = session.overlay?.frame ?? .zero
        results["expanded_visible"] = session.presentation == .expanded && session.overlay?.isVisible == true
        session.passthrough = true
        results["expanded_passthrough"] = session.overlay?.isInteractive == false
        results["passthrough_retains_clickable_controls"] = session.overlay?.passthroughControlsVisible == true
        session.collapseSubtitles()
        results["mini_visible_and_interactive"] = session.presentation == .compact && session.overlay?.isVisible == true && session.overlay?.isInteractive == true
        results["mini_hides_auxiliary_controls"] = session.overlay?.passthroughControlsVisible == false
        results["mini_is_smaller"] = (session.overlay?.frame.height ?? 0) < fullFrame.height
        try? await Task.sleep(nanoseconds:300_000_000)
        session.menuBar?.show()
        try? await Task.sleep(nanoseconds:100_000_000)
        results["menu_bar_can_open"] = session.menuBar?.isShown == true
        session.showSettings(.appearance)
        results["settings_dismisses_menu_bar"] = session.menuBar?.isShown == false
        results["mini_opens_settings"] = session.preferencesWindow?.isVisible == true && session.settingsSection == .appearance
        session.overlay?.hide()
        results["hidden_state_explicit"] = session.presentation == .hidden && session.overlay?.isVisible == false
        session.showSettings(.records)
        results["hidden_can_open_settings"] = session.preferencesWindow?.isVisible == true && session.settingsSection == .records
        session.showSubtitles()
        results["expanded_can_be_restored"] = session.presentation == .expanded && session.overlay?.isVisible == true && session.overlay?.frame.height == fullFrame.height
        session.passthrough = false
        results["passthrough_can_be_recovered"] = session.overlay?.isInteractive == true
        await session.selectMode(.transcribe)
        results["transcribe_selects_independent_route"] = session.config.pipeline == .transcribe && session.recordingMode == .transcribe
        await session.selectMode(.interpretation)
        results["interpretation_selects_speech"] = session.config.pipeline == .translate && session.config.translationMode == .speech
        await session.selectMode(.subtitles)
        results["translation_selects_text_only"] = session.config.pipeline == .translate && session.config.translationMode == .subtitles
        session.busy = true; results["busy_disables_record_button"] = !session.canToggleRecording; session.busy = false
        session.config.bailianAPIKey = ""
        results["missing_credentials_explained"] = session.configurationProblem != nil && !session.canToggleRecording
        session.config.bailianAPIKey = "interface-test-not-a-real-key"
        session.config.systemAudioEnabled = false; session.config.microphoneEnabled = false
        results["missing_source_explained"] = session.configurationProblem != nil && !session.canToggleRecording
        results["navigation_never_starts_recording"] = session.running == initialRun && !session.running && session.currentDirectory == nil
        session.config.systemAudioEnabled = true
        session.sessionStartedAt = Date(); session.sourceText = "At best, it leaves you with a bunch of asymmetric relationships."
        session.translatedText = "充其量，这只会给你留下一堆不对称的关系。"
        let imageRoot = URL(fileURLWithPath:output).deletingLastPathComponent().appendingPathComponent("caption-renders")
        try? FileManager.default.createDirectory(at:imageRoot,withIntermediateDirectories:true)
        for mode in RecordingMode.allCases {
            session.config.pipeline = mode == .transcribe ? .transcribe : .translate
            session.config.translationMode = mode == .interpretation ? .speech : .subtitles
            session.config.subtitleLayout = .bilingual
            let window = NSWindow(contentRect:NSRect(x:0,y:0,width:820,height:300),styleMask:.borderless,backing:.buffered,defer:false)
            window.isReleasedWhenClosed = false
            let view = NSHostingView(rootView:CaptionView(session:session)); window.contentView = view
            view.frame = NSRect(x:0,y:0,width:820,height:300); view.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds:100_000_000)
            view.displayIfNeeded()
            if let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) {
                view.cacheDisplay(in:view.bounds,to:bitmap)
                if let png = bitmap.representation(using:.png,properties:[:]) { try? png.write(to:imageRoot.appendingPathComponent(mode.rawValue+".png")) }
                let request = VNRecognizeTextRequest(); request.recognitionLanguages = ["zh-Hans","en-US"]; request.recognitionLevel = .accurate
                if let cgImage = bitmap.cgImage { try? VNImageRequestHandler(cgImage:cgImage).perform([request]) }
                let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined().replacingOccurrences(of:" ",with:"")
                let sourceVisible = text.localizedCaseInsensitiveContains("asymmetric")
                let translationVisible = text.contains("充其量") || text.contains("不对称")
                results["caption_render_"+mode.rawValue] = sourceVisible && (mode == .transcribe ? !translationVisible : translationVisible)
            } else { results["caption_render_"+mode.rawValue] = false }
            window.close()
        }
        session.config.pipeline = .transcribe
        session.config.transcribeProvider = .whisperKit
        session.config.apiKey="";session.config.bailianAPIKey=""
        results["whisper_no_cloud_key_needed"] = session.configurationProblem == nil && session.canToggleRecording
        results["whisper_gpu_named_in_status"] = session.connectionSummary.contains("GPU")
        session.showSettings(.session)
        try? await Task.sleep(nanoseconds:200_000_000)
        if let window=NSApp.windows.first(where:{$0.title == "LiveCaption 设置"}),let view=window.contentView {
            view.layoutSubtreeIfNeeded();view.displayIfNeeded()
            if let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) {
                view.cacheDisplay(in:view.bounds,to:bitmap)
                try? bitmap.representation(using:.png,properties:[:])?.write(to:imageRoot.appendingPathComponent("whisper-settings.png"))
            }
        }
        session.config.transcribeProvider = .google
        results["google_still_requires_its_key"] = session.configurationProblem != nil && !session.canToggleRecording
        session.showSettings(.models)
        results["model_download_page_can_open"] = session.settingsSection == .models && session.preferencesWindow?.isVisible == true
        let newcomer=AppSession();newcomer.verificationInProgress=true;newcomer.configurationReady=false
        let onboardingRoot=imageRoot.appendingPathComponent("first-run")
        await newcomer.createInitialConfiguration(root:onboardingRoot)
        results["first_run_creates_local_configuration"] = newcomer.configurationReady && newcomer.config.provider == .whisperKit
        results["first_run_needs_no_cloud_credentials"] = newcomer.config.apiKey.isEmpty && newcomer.config.bailianAPIKey.isEmpty
        results["first_run_opens_downloads_without_recording"] = newcomer.settingsSection == .models && !newcomer.running
        let original=try? Data(contentsOf:onboardingRoot.appendingPathComponent("Configuration.json"))
        await newcomer.createInitialConfiguration(root:onboardingRoot)
        results["first_run_never_overwrites_existing_config"] = original == (try? Data(contentsOf:onboardingRoot.appendingPathComponent("Configuration.json")))
        do {
            let connectionFile=onboardingRoot.appendingPathComponent("connection.json")
            try Data(#"{"captionReflow":{"enabled":false,"engine":"sat"},"extensionField":"preserved","apiKey":"old-placeholder"}"#.utf8).write(to:connectionFile)
            var connection=Configuration();connection.pipeline = .translate;connection.bailianRegion = .beijing;connection.bailianWorkspaceID="test-workspace"
            connection.apiKey="test-key-not-real";connection.bailianAPIKey="test-bailian-key-not-real"
            _ = try await CaptionReflowSettingsWriter().saveConnection(connection,url:connectionFile)
            let document=try JSONSerialization.jsonObject(with:Data(contentsOf:connectionFile)) as? [String:Any]
            results["connection_save_preserves_other_settings"] = document?["extensionField"] as? String == "preserved" && (document?["captionReflow"] as? [String:Any])?["enabled"] as? Bool == false
            results["connection_save_updates_only_selected_credential"] = document?["apiKey"] as? String == "old-placeholder" && document?["bailianAPIKey"] as? String == "" && document?["bailianRegion"] as? String == "beijing"
        } catch { results["connection_save_preserves_other_settings"]=false;results["connection_save_updates_only_selected_credential"]=false }
        newcomer.preferencesWindow?.close()
        session.preferencesWindow?.close()
        let report:[String:Any] = ["scope":"实际AppKit窗口控制器与界面状态检查；不启动采集或调用云模型，不代替截图与点击验收","tested_at":SessionLog.timestamp(),"menu_bar_diagnostics":session.menuBar?.diagnostics as Any? ?? [:],"checks":results,"success":results.values.allSatisfy{$0}]
        let url = URL(fileURLWithPath:output)
        try? FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        if let data = try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) { try? data.write(to:url,options:.atomic) }
    }
}
