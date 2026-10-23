import AppKit
import SwiftUI
import Vision
import LiveCaptionCore

/// Text-event replay exercises the production caption projection and native view without audio or cloud calls.
@MainActor enum CaptionLayoutSmoke {
    static func fixture() -> Transcript {
        var transcript = Transcript()
        for n in 1...12 {
            append(&transcript,n:n)
        }
        return transcript
    }
    static func append(_ transcript:inout Transcript,n:Int) {
        let source = n >= 12 ? "FinalCheckpoint. The lecture ends at four thirty." : "Paragraph \(n). We need to understand the example before moving on. The speaker explains how this idea applies to everyday decisions."
        let translation = n >= 12 ? "末段标识。讲座在四点三十分结束。" : "第\(n)段。我们需要先理解这个例子，然后再继续。讲者解释了这个概念如何应用于日常决策。"
        _ = transcript.apply(TextUpdate(track:"source",text:source,replace:true,finality:.final,boundary:true,start:Double((n-1)*20_000),end:Double(n*20_000),providerID:"source-\(n)"),epoch:1,pipeline:.translate)
        _ = transcript.apply(TextUpdate(track:"translation",text:translation,replace:true,finality:.final,boundary:true,providerID:"target-\(n)",sourceProviderID:"source-\(n)"),epoch:1,pipeline:.translate)
    }
    static func run(output:String,session:AppSession) async {
        let arguments=CommandLine.arguments
        if let i=arguments.firstIndex(of:"--caption-hang-snapshot"),arguments.count>i+1 {
            await replayHang(output:output,snapshot:arguments[i+1],uniqueIDs:arguments.contains("--unique-replay-ids"),session:session)
            return
        }
        session.verificationInProgress = true
        session.config = Configuration(); session.config.pipeline = .translate; session.config.subtitleLayout = .bilingual
        session.sessionStartedAt = Date().addingTimeInterval(-240)
        session.fontSize=25
        var transcript=fixture()
        session.displayTranscript(transcript,epoch:1,pipeline:.translate)
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:900,height:440),styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        let view = NSHostingView(rootView:CaptionView(session:session)); window.contentView = view
        view.frame = NSRect(x:0,y:0,width:900,height:440)
        window.orderFrontRegardless()
        let root = URL(fileURLWithPath:output).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        var checks:[String:Bool] = [:], renders:[String:String] = [:]
        func capture(_ name:String) async -> String {
            try? await Task.sleep(nanoseconds:350_000_000)
            view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
            var text=""
            if let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) {
                view.cacheDisplay(in:view.bounds,to:bitmap)
                if let png=bitmap.representation(using:.png,properties:[:]) { try? png.write(to:root.appendingPathComponent(name+".png")) }
                let request=VNRecognizeTextRequest(); request.recognitionLanguages=["zh-Hans","en-US"]; request.recognitionLevel = .accurate
                if let cgImage=bitmap.cgImage { try? VNImageRequestHandler(cgImage:cgImage).perform([request]) }
                text=(request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator:"\n")
            }
            renders[name]=text; return text
        }
        let text=await capture("caption")
        checks["latest_english_visible_after_four_minutes"] = text.localizedCaseInsensitiveContains("FinalCheckpoint")
        checks["latest_chinese_visible_in_same_viewport"] = text.contains("四点三十")
        checks["twelve_paired_paragraphs"] = session.captionParagraphs.count == 12 && session.captionParagraphs.allSatisfy { !$0.source.isEmpty && !$0.translation.isEmpty }
        session.config.subtitleLayout = .source
        let sourceOnly=await capture("source-only")
        checks["source_only"] = sourceOnly.contains("FinalCheckpoint") && !sourceOnly.contains("四点三十")
        session.config.subtitleLayout = .translation
        let translationOnly=await capture("translation-only")
        checks["translation_only"] = !translationOnly.contains("FinalCheckpoint") && translationOnly.contains("四点三十")
        session.config.pipeline = .transcribe
        let transcribe=await capture("transcribe")
        checks["transcribe_only"] = transcribe.contains("FinalCheckpoint") && !transcribe.contains("四点三十")
        session.config.pipeline = .translate; session.config.subtitleLayout = .bilingual
        session.config.translationMode = .speech
        let speech=await capture("speech")
        checks["speech_uses_same_paired_view"] = speech.contains("FinalCheckpoint") && speech.contains("四点三十")
        session.config.translationMode = .subtitles
        func findScroll(_ parent:NSView)->NSScrollView? {
            if let scroll=parent as? NSScrollView { return scroll }
            for child in parent.subviews { if let scroll=findScroll(child) { return scroll } }
            return nil
        }
        if let scroll=findScroll(view) {
            NotificationCenter.default.post(name:NSScrollView.willStartLiveScrollNotification,object:scroll)
            scroll.contentView.scroll(to:.zero); scroll.reflectScrolledClipView(scroll.contentView)
            NotificationCenter.default.post(name:NSScrollView.didLiveScrollNotification,object:scroll)
            NotificationCenter.default.post(name:NSScrollView.didEndLiveScrollNotification,object:scroll)
            checks["manual_scroll_pauses_following"] = !session.followsLatestCaption
            let oldY=scroll.contentView.bounds.minY
            append(&transcript,n:13); session.displayTranscript(transcript,epoch:1,pipeline:.translate)
            let paused=await capture("history-with-new-text")
            checks["new_text_does_not_pull_history_to_bottom"] = !session.followsLatestCaption && abs(scroll.contentView.bounds.minY-oldY)<30
            checks["return_to_latest_control_visible"] = paused.contains("回到最新")
            session.followsLatestCaption=true
            let latest=await capture("returned-to-latest")
            checks["resume_follows_latest_pair"] = latest.contains("FinalCheckpoint") && latest.contains("四点三十")
        } else { checks["native_scroll_observer_attached"] = false }
        // Before background reflow finishes, a long service segment stays fully scrollable, never folded.
        let longSource=String(repeating:"This is a long uninterrupted explanation about the classroom example. ",count:18)+"ClosingCheckpoint. The lecture ends at four thirty."
        let longTranslation=String(repeating:"这是一段没有停顿的长说明，需要同时保留原文和译文。",count:18)+"结尾中文。讲座在四点三十分结束。"
        _=transcript.apply(TextUpdate(track:"source",text:longSource,replace:true,providerID:"long"),epoch:1,pipeline:.translate)
        _=transcript.apply(TextUpdate(track:"translation",text:longTranslation,replace:true,providerID:"long-target",sourceProviderID:"long"),epoch:1,pipeline:.translate)
        session.displayTranscript(transcript,epoch:1,pipeline:.translate)
        let long=await capture("long-paragraph")
        checks["long_paragraph_has_no_expand_or_ellipsis"] = !long.contains("展开本段") && !long.contains("…")
        checks["long_paragraph_full_text_preserved"] = session.captionParagraphs.last?.source == longSource && session.captionParagraphs.last?.translation == longTranslation
        window.setContentSize(NSSize(width:560,height:140))
        let compact=await capture("small-window")
        checks["small_window_keeps_full_scrollable_text"] = !compact.contains("展开本段") && session.captionParagraphs.last?.source == longSource && session.captionParagraphs.last?.translation == longTranslation
        let args=CommandLine.arguments
        if let i=args.firstIndex(of:"--caption-event-log"),args.count>i+1 {
            do {
                var recorded=Transcript(),lastEpoch=1
                let lines=try String(contentsOfFile:args[i+1],encoding:.utf8).split(separator:"\n")
                for line in lines {
                    guard let event=try JSONSerialization.jsonObject(with:Data(line.utf8)) as? [String:Any],
                          let type=event["event_type"] as? String,["text.append","text.replace"].contains(type),
                          let text=event["text"] as? String,let track=event["track"] as? String else { continue }
                    lastEpoch=event["connection_epoch"] as? Int ?? 1
                    _=recorded.apply(TextUpdate(track:track,text:text,replace:type == "text.replace",boundary:event["boundary_origin"] as? String == "provider",
                        providerID:event["provider_segment_id"] as? String,sourceProviderID:event["source_provider_segment_id"] as? String),epoch:lastEpoch,pipeline:.translate)
                }
                session.displayTranscript(recorded,epoch:lastEpoch,pipeline:.translate)
                window.setContentSize(NSSize(width:900,height:440))
                _=await capture("recorded-session")
                let rows=session.captionParagraphs
                checks["recorded_session_pairs_all_translated_paragraphs"] = rows.count>=5 && rows.allSatisfy { !$0.source.isEmpty && !$0.translation.isEmpty && !$0.unlinkedTranslation }
            } catch { checks["recorded_session_replay"] = false }
        }
        let result:[String:Any] = ["success":checks.values.allSatisfy{$0},"checks":checks,"rendered_text":renders,"fixture_audio_timeline_seconds":260,"scope":"本地文字事件回放与真实原生字幕渲染，滚动使用AppKit通知和原生位置检查，不调用云端或音频设备"]
        if let data=try? JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]) { try? data.write(to:URL(fileURLWithPath:output)) }
        if CommandLine.arguments.contains("--caption-preview") {
            window.setContentSize(NSSize(width:900,height:440))
        } else { window.close() }
    }

    /// A separate process watchdog must bound this replay: a blocked main actor cannot time itself out.
    private static func replayHang(output:String,snapshot:String,uniqueIDs:Bool,session:AppSession) async {
        let resultURL=URL(fileURLWithPath:output)
        let root=resultURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        session.verificationInProgress=true
        session.config=Configuration();session.config.pipeline = .translate;session.config.subtitleLayout = .bilingual
        session.fontSize=25;session.followsLatestCaption=true;session.sessionStartedAt=Date()
        let liveState=CommandLine.arguments.contains("--replay-live-state")
        if liveState { session.running=true;session.status="翻译中";session.configurationReady=true }
        if CommandLine.arguments.contains("--replay-settings") { session.showSettings(.records) }
        let window=NSPanel(contentRect:NSRect(x:0,y:0,width:832,height:370),styleMask:[.borderless,.nonactivatingPanel,.resizable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false
        // Include the production controlActiveState environment used by selectable text.
        let view=NSHostingView(rootView:OverlayRootView(session:session));window.contentView=view
        do {
            let object=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:snapshot))) as! [String:Any]
            if let events=object["events"] as? [[String:Any]],let completions=object["completions"] as? [[String:Any]] {
                await replayTimeline(events:events,completions:completions,uniqueIDs:uniqueIDs,session:session,window:window,root:root,resultURL:resultURL)
                window.close();return
            }
            let saved=object["rows"] as! [[String:Any]]
            let rows=saved.enumerated().map { index,row in
                CaptionParagraph(id:uniqueIDs ? "replay-\(index)":row["id"] as! String,
                    source:row["source"] as! String,translation:row["translation"] as! String,isFinal:true)
            }
            session.captionParagraphs=Array(rows.prefix(1));window.orderFrontRegardless()
            for tick in 0..<80 {
                if liveState { session.systemLevel=0;session.microphoneLevel=Float(tick%10)/10 }
                if tick == 5 { session.captionParagraphs=rows }
                // Exercise native re-layout as the live provider appends text and the user resizes.
                if tick == 30 { window.setContentSize(NSSize(width:560,height:240)) }
                if tick == 50 { window.setContentSize(NSSize(width:900,height:440)) }
                let beat:[String:Any]=["tick":tick,"time":Date().timeIntervalSince1970,"unique_ids":uniqueIDs]
                try JSONSerialization.data(withJSONObject:beat).write(to:root.appendingPathComponent("heartbeat.json"),options:.atomic)
                try await Task.sleep(nanoseconds:100_000_000)
            }
            view.layoutSubtreeIfNeeded();view.displayIfNeeded()
            if let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) {
                view.cacheDisplay(in:view.bounds,to:bitmap)
                try bitmap.representation(using:.png,properties:[:])?.write(to:root.appendingPathComponent("replay.png"))
            }
            let result:[String:Any]=["success":true,"main_actor_ticks":80,"unique_ids":Set(rows.map(\.id)).count == rows.count,
                "rows":rows.map { ["id":$0.id,"source":$0.source,"translation":$0.translation] },
                "scope":"卡死现场文字在生产 CaptionView 中回放，含窗口缩放；外部进程监测主线程心跳，无音频及云请求"]
            try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:resultURL)
        } catch {
            let result:[String:Any]=["success":false,"error":error.localizedDescription]
            if let data=try? JSONSerialization.data(withJSONObject:result) { try? data.write(to:resultURL) }
        }
        window.close()
    }

    private static func replayTimeline(events:[[String:Any]],completions:[[String:Any]],uniqueIDs:Bool,
                                       session:AppSession,window:NSWindow,root:URL,resultURL:URL) async {
        var misses:[String]=[],applied=0,duplicateProjections=0,maxGap:TimeInterval=0,selectionCount=0
        let coordinator=CaptionReflowCoordinator { input,_ in
            guard let saved=completions.first(where: { $0["source"] as? String == input.source.joined() && $0["translation"] as? String == input.translation.joined() }),
                  let groups=saved["groups"] as? [[Int]] else {
                throw CaptionError.message("回放输入未匹配记录的模型结果")
            }
            try await Task.sleep(nanoseconds:UInt64((saved["elapsed"] as? Double ?? 1)*1_000_000_000))
            return String(decoding:try JSONSerialization.data(withJSONObject:["groups":groups]),as:UTF8.self)
        }
        coordinator.onChange = { rows,status in
            if Set(rows.map(\.id)).count != rows.count { duplicateProjections += 1 }
            session.captionParagraphs=uniqueIDs ? rows.enumerated().map { i,row in
                var changed=row;changed.id="\(row.id):position-\(i)";return changed
            }:rows
            session.reflowStatus=status
        }
        coordinator.onApplied = { _,_,_ in applied += 1 }
        session.captionReflow=coordinator
        var config=CaptionReflowConfiguration();config.enabled=true
        window.orderFrontRegardless()
        let began=Date();var previous=began,eventIndex=0,transcript=Transcript(),tick=0
        let end=(events.last?["seconds"] as? Double ?? 0)+5
        while Date().timeIntervalSince(began)<end {
            if CommandLine.arguments.contains("--replay-live-state"),tick%2 == 0 {
                session.systemLevel=0;session.microphoneLevel=Float(tick%20)/20
            }
            if CommandLine.arguments.contains("--replay-select-text"),(tick == 40 || tick == 540),let host=window.contentView {
                func select(_ view:NSView)->Bool {
                    if let field=view as? NSTextField,field.isSelectable,field.stringValue.count>30 {
                        window.makeFirstResponder(field);field.selectText(nil);return true
                    }
                    for child in view.subviews { if select(child) { return true } }
                    return false
                }
                window.makeKeyAndOrderFront(nil)
                if select(host) { selectionCount += 1 }
            }
            let now=Date();maxGap=max(maxGap,now.timeIntervalSince(previous));previous=now
            while eventIndex<events.count,(events[eventIndex]["seconds"] as? Double ?? 0)<=now.timeIntervalSince(began) {
                let event=events[eventIndex];eventIndex += 1
                let update=TextUpdate(track:event["track"] as? String ?? "source",text:event["text"] as? String ?? "",
                    replace:event["event_type"] as? String == "text.replace",finality:TextFinality(rawValue:event["finality"] as? String ?? "") ?? .unspecified,
                    boundary:event["boundary_origin"] as? String == "provider",providerID:event["provider_segment_id"] as? String,
                    sourceProviderID:event["source_provider_segment_id"] as? String)
                _=transcript.apply(update,epoch:1,pipeline:.translate)
                coordinator.update(transcript.captionParagraphs(epoch:1),configuration:config,context:"replay:1:translate")
            }
            let beat:[String:Any]=["tick":tick,"time":now.timeIntervalSince1970,"event_index":eventIndex,"applied":applied,"duplicate_projections":duplicateProjections]
            if let data=try? JSONSerialization.data(withJSONObject:beat) { try? data.write(to:root.appendingPathComponent("heartbeat.json"),options:.atomic) }
            tick += 1;try? await Task.sleep(nanoseconds:50_000_000)
        }
        if applied != completions.count { misses.append("applied \(applied), expected \(completions.count)") }
        let raw=transcript.captionParagraphs(epoch:1),rows=coordinator.rows
        let lossless=rows.map(\.source).joined() == raw.map(\.source).joined() && rows.map(\.translation).joined() == raw.map(\.translation).joined()
        coordinator.cancel()
        let result:[String:Any]=["success":misses.isEmpty && lossless && maxGap<1,"main_actor_ticks":tick,"maximum_heartbeat_gap_seconds":maxGap,
            "checks":["all_recorded_jobs_applied":misses.isEmpty,"text_preserved":lossless,"main_actor_responsive":maxGap<1],
            "applied_jobs":applied,"duplicate_projections":duplicateProjections,"selection_count":selectionCount,"misses":misses,"unique_ids_control":uniqueIDs,
            "scope":"按原始时序回放本次会话的文字事件，生产整理协调器与原生字幕窗口，复用已记录的模型结果；不上传音频或重新请求模型"]
        if let data=try? JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]) { try? data.write(to:resultURL) }
        session.running=false
    }
}
