import AppKit
import AVFoundation
import SwiftUI
import LiveCaptionCore

/// Exercises the real AppSession sender, provider, caption state and live journal. No audio devices.
@MainActor enum FileReplaySmoke {
    static func run(fixture:String,output:String,configurationPath:String,speech:Bool,session:AppSession) async {
        let original=session.config
        session.verificationInProgress=true
        defer { session.verificationInProgress=false;session.testOnlyFilePCM=nil;session.testOnlyDisconnectAfter=nil;session.testOnlyReconnectDelay=0;session.config=original }
        let outputURL=URL(fileURLWithPath:output),root=outputURL.deletingLastPathComponent()
        var uiTicks=0,maximumUIGap:TimeInterval=0
        var visibleChanges:[[String:Any]]=[],lastVisibleIDs:[String]=[]
        var initialCaptured=false,splitCaptured=false
        var fixedIDs:[String]=[],fixedText:[String:[String]]=[:]
        var stabilityViolations:[[String:Any]]=[],fixedCorrections:[[String:Any]]=[]
        let uiHeartbeat=Task { @MainActor in
            var previous=Date()
            while !Task.isCancelled {
                let now=Date();maximumUIGap=max(maximumUIGap,now.timeIntervalSince(previous));previous=now;uiTicks += 1
                let rows=session.captionParagraphs,ids=rows.map(\.id)
                if !rows.isEmpty,ids != lastVisibleIDs {
                    lastVisibleIDs=ids
                    visibleChanges.append(["tick":uiTicks,"row_ids":ids,"row_count":rows.count,
                        "source":rows.map(\.source).joined(),"translation":rows.map(\.translation).joined()])
                }
                let committed=rows.filter(\.isFinal),currentIDs=committed.map(\.id)
                if Array(currentIDs.prefix(fixedIDs.count)) != fixedIDs {
                    stabilityViolations.append(["tick":uiTicks,"previous_fixed_ids":fixedIDs,"current_fixed_ids":currentIDs])
                }
                for row in committed {
                    let text=[row.source,row.translation]
                    if let previous=fixedText[row.id],previous != text {
                        fixedCorrections.append(["tick":uiTicks,"id":row.id,"before":previous,"after":text])
                    }
                    fixedText[row.id]=text
                }
                fixedIDs=currentIDs
                let firstPending = !initialCaptured && !rows.isEmpty && ids.allSatisfy { $0.hasPrefix("pending-") }
                let firstSplit = !splitCaptured && rows.count>1 && ids.contains { $0.hasPrefix("reflow-") }
                if firstPending || firstSplit,let panel=NSApp.windows.first(where:{ $0.title == "LiveCaption 字幕" && $0.isVisible }),let host=panel.contentView {
                    host.layoutSubtreeIfNeeded();host.displayIfNeeded()
                    if let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds) {
                        host.cacheDisplay(in:host.bounds,to:bitmap)
                        try? bitmap.representation(using:.png,properties:[:])?.write(to:root.appendingPathComponent(firstPending ? "live-before-model.png":"live-model-split.png"))
                    }
                    if firstPending { initialCaptured=true } else { splitCaptured=true }
                }
                let beat:[String:Any]=["tick":uiTicks,"time":now.timeIntervalSince1970,"maximum_gap_seconds":maximumUIGap]
                if let data=try? JSONSerialization.data(withJSONObject:beat) { try? data.write(to:root.appendingPathComponent("ui-heartbeat.json"),options:.atomic) }
                do { try await Task.sleep(nanoseconds:100_000_000) } catch { return }
            }
        }
        defer { uiHeartbeat.cancel();session.overlay?.hide() }
        var result:[String:Any]=["scope":"真实应用的文件输入→同款队列→所选识别或翻译引擎→AppSession字幕状态→原生字幕渲染与运行中日志；不采集、不播放、不验证物理扬声器","mode":CommandLine.arguments.contains("--file-transcribe") ? "transcribe" : (speech ? "speech":"subtitles")]
        do {
            let format=try AVAudioFile(forReading:URL(fileURLWithPath:fixture)).fileFormat
            guard format.sampleRate == 16000,format.channelCount == 1,format.commonFormat == .pcmFormatInt16 else {
                throw CaptionError.message("真人测试 WAV 必须为 16 kHz 单声道 PCM16")
            }
            let bytes=try Data(contentsOf:URL(fileURLWithPath:fixture))
            // The finite verification fixtures are standard mono PCM16 RIFF files.
            var cursor=12,pcm:Data?
            while cursor+8<=bytes.count {
                let n=Int(bytes[cursor+4])|Int(bytes[cursor+5])<<8|Int(bytes[cursor+6])<<16|Int(bytes[cursor+7])<<24
                guard n>=0,cursor+8+n<=bytes.count else { throw CaptionError.message("WAV 数据块异常") }
                if String(decoding:bytes[cursor..<cursor+4],as:UTF8.self)=="data" { pcm=bytes.subdata(in:cursor+8..<cursor+8+n);break }
                cursor+=8+n+(n%2)
            }
            guard let pcm,!pcm.isEmpty else { throw CaptionError.message("WAV 没有音频") }
            session.config=try Configuration.load(from:URL(fileURLWithPath:configurationPath))
            if CommandLine.arguments.contains("--file-google") { session.config.transcribeProvider = .google }
            if CommandLine.arguments.contains("--file-no-reflow") { session.config.captionReflow.enabled=false }
            session.config.pipeline = CommandLine.arguments.contains("--file-transcribe") ? .transcribe : .translate
            session.config.translateProvider = .bailian
            session.config.translationMode=speech ? .speech:.subtitles;session.config.subtitleLayout = .bilingual
            session.config.logDirectory=root.appendingPathComponent("app-file-logs").path
            session.configurationReady=true;session.testOnlyFilePCM=pcm
            func option(_ flag:String)->Double? {
                guard let i=CommandLine.arguments.firstIndex(of:flag),i+1<CommandLine.arguments.count else { return nil }
                return Double(CommandLine.arguments[i+1])
            }
            session.testOnlyDisconnectAfter=option("--file-disconnect-after")
            session.testOnlyReconnectDelay=option("--file-reconnect-delay") ?? 0
            let stopAfter=option("--file-stop-after")
            await session.start(persistSettings:false)
            guard session.running,!session.busy,let directory=session.currentDirectory else { throw CaptionError.message(session.errorMessage ?? "应用未开始") }
            // Keep the actual floating window mounted throughout live updates, not just for a final screenshot.
            session.overlay?.show()
            result["live_caption_window_visible"]=session.overlay?.isVisible == true
            result["log_path"]=directory.path
            try await Task.sleep(nanoseconds:UInt64((stopAfter ?? (Double(pcm.count)/32000/2))*1e9))
            let live=try String(contentsOf:directory.appendingPathComponent("live.md"))
            let journal=try String(contentsOf:directory.appendingPathComponent("events.jsonl"))
            result["live_readable_while_running"]=session.running && journal.contains("\"track\":\"source\"") && live.count>100
            if CommandLine.arguments.contains("--file-disable-reflow-midway") {
                result["sat_applied_before_disable"]=journal.contains("\"caption.layout.applied\"")
                session.setReflowEnabled(false,fileURL:URL(fileURLWithPath:configurationPath))
                await session.reflowSettingsSave?.value
                result["disable_immediately_matches_provider_segments"]=session.captionParagraphs == session.providerCaptionParagraphs && !session.captionReflow.pending
                // Changing the display policy explicitly changes identities once.
                fixedIDs=[];fixedText=[:]
            }
            if stopAfter == nil { await session.waitForFileReplay() }
            await session.stop()
            let reflowStart=Date()
            while session.captionReflow.pending && Date().timeIntervalSince(reflowStart)<30 { try await Task.sleep(nanoseconds:50_000_000) }
            result["reflow_status"]=session.reflowStatus
            if CommandLine.arguments.contains("--file-disable-reflow-midway") {
                result["disabled_final_matches_provider_segments"]=session.captionParagraphs == session.providerCaptionParagraphs
                result["provider_segment_count"]=session.providerCaptionParagraphs.count
            }
            result["caption_rows"]=session.captionParagraphs.map { ["source":$0.source,"translation":$0.translation] }
            result["source_subtitle"]=session.sourceText;result["translated_subtitle"]=session.translatedText
            let uploaded=try AVAudioFile(forReading:directory.appendingPathComponent("audio/uploaded.wav"))
            let observedURL=directory.appendingPathComponent("audio/webrtc-input-observed.wav")
            let observed=try AVAudioFile(forReading:session.config.provider == .bailian && session.config.bailianTransport == .webrtc ? observedURL : directory.appendingPathComponent("audio/uploaded.wav"))
            result["submitted_samples"]=uploaded.length;result["encoder_input_samples"]=observed.length
            let encoded=try Data(contentsOf:session.config.provider == .bailian && session.config.bailianTransport == .webrtc ? observedURL : directory.appendingPathComponent("audio/uploaded.wav"))
            let submitted=try Data(contentsOf:directory.appendingPathComponent("audio/uploaded.wav"))
            let expected=stopAfter == nil ? pcm : Data(pcm.prefix(submitted.count-44))
            let exact=Data(encoded.dropFirst(44)) == expected && Data(submitted.dropFirst(44)) == expected
            result["input_pcm_byte_identical"]=exact
            result["physical_playback_buffers"]=session.hardware.scheduledBuffers
            let journalEnd=try String(contentsOf:directory.appendingPathComponent("events.jsonl"))
            let complete=journalEnd.contains(#""tail_incomplete":false"#)
            result["tail_confirmed"]=complete
            let events=journalEnd.split(separator:"\n").compactMap { try? JSONSerialization.jsonObject(with:Data($0.utf8)) as? [String:Any] }
            result["final_connection_tail_confirmed"]=events.last(where: { $0["event_type"] as? String == "connection.final_finish" })?["confirmed"] as? Bool ?? false
            result["discarded_input_samples"]=session.discardedInputSamples
            result["discarded_output_samples"]=session.discardedOutputSamples
            result["injected_disconnect_after"]=session.testOnlyDisconnectAfter as Any? ?? NSNull()
            result["injected_reconnect_delay"]=session.testOnlyReconnectDelay
            result["requested_stop_after"]=stopAfter as Any? ?? NSNull()
            let translatedURL=directory.appendingPathComponent("audio/translated.wav")
            let translatedSamples=(try? AVAudioFile(forReading:translatedURL).length) ?? 0
            result["translated_samples"]=translatedSamples
            result["success"]=session.errorMessage == nil && exact && (speech ? translatedSamples>0 : translatedSamples==0) && !session.sourceText.isEmpty && (session.config.pipeline == .transcribe || !session.translatedText.isEmpty) && result["live_readable_while_running"] as? Bool == true && complete
            result["error"]=session.errorMessage as Any? ?? NSNull()
            result["reflow_applied_count"]=journalEnd.components(separatedBy:"caption.layout.applied").count-1
            let host=NSHostingView(rootView:CaptionView(session:session)),size=NSSize(width:1100,height:560)
            let window=NSWindow(contentRect:NSRect(origin:.zero,size:size),styleMask:[.borderless],backing:.buffered,defer:false)
            window.contentView=host;host.frame=NSRect(origin:.zero,size:size);host.layoutSubtreeIfNeeded();host.display()
            if let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds) { host.cacheDisplay(in:host.bounds,to:bitmap);try bitmap.representation(using:.png,properties:[:])?.write(to:root.appendingPathComponent("caption.png")) }
        } catch {
            if session.running { await session.stop() }
            result["success"]=false;result["error"]=session.config.redacted(error.localizedDescription)
        }
        try? FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        result["main_actor_ticks"]=uiTicks;result["maximum_main_actor_gap_seconds"]=maximumUIGap
        result["visible_presentation_changes"]=visibleChanges
        result["fixed_boundary_violations"]=stabilityViolations
        result["fixed_content_corrections"]=fixedCorrections
        let terminalRows=session.captionParagraphs,terminalIDs=terminalRows.filter(\.isFinal).map(\.id)
        if Array(terminalIDs.prefix(fixedIDs.count)) != fixedIDs {
            stabilityViolations.append(["tick":"terminal_snapshot","previous_fixed_ids":fixedIDs,"current_fixed_ids":terminalIDs])
        }
        result["final_fixed_row_ids"]=terminalIDs
        result["final_visible_rows"]=terminalRows.map { ["id":$0.id,"source":$0.source,"translation":$0.translation,"committed":$0.isFinal] as [String:Any] }
        result["fixed_boundary_violations"]=stabilityViolations
        result["fixed_boundaries_preserved"]=stabilityViolations.isEmpty
        result["success"]=(result["success"] as? Bool ?? false) && stabilityViolations.isEmpty
        result["live_window_responsive"]=uiTicks>10 && maximumUIGap<1
        result["success"]=(result["success"] as? Bool ?? false) && (result["live_window_responsive"] as? Bool ?? false)
        try? JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:outputURL,options:.atomic)
    }
}
