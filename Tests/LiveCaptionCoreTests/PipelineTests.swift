import AVFoundation
import AudioBridge
import LiveCaptionCore

final class PipelineChecks {
    func testCrashRecoveryPreservesPartialFragmentAndCorrectedText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = Configuration(); let log = try SessionLog(configuration:config,rootOverride:root)
        try await log.begin(); try await log.beginEpoch(1,configuration:config)
        try await log.text(TextUpdate(track:"source",text:"wrong preview",replace:true,finality:.interim),epoch:1)
        try await log.text(TextUpdate(track:"source",text:"correct classroom text",replace:true,finality:.final,boundary:true),epoch:1)
        try await log.flush()
        var rejectedLiveOwner = false
        do { _ = try LogRecovery.recoverIfNeeded(root:root) } catch { rejectedLiveOwner = true }
        XCTAssertTrue(rejectedLiveOwner)
        let metaURL = log.directory.appendingPathComponent("session.json")
        var meta = try JSONSerialization.jsonObject(with:Data(contentsOf:metaURL)) as! [String:Any]
        meta["owner_pid"] = 0
        try JSONSerialization.data(withJSONObject:meta).write(to:metaURL,options:.atomic)
        let file = try FileHandle(forWritingTo:log.directory.appendingPathComponent("events.jsonl"))
        try file.seekToEnd(); try file.write(contentsOf:Data("{\"unfinished\":".utf8)); try file.close()
        let recovered = try LogRecovery.recoverIfNeeded(root:root); XCTAssertTrue(recovered)
        let text = try String(contentsOf:log.directory.appendingPathComponent("transcript.md"))
        XCTAssertTrue(text.contains("correct classroom text")); XCTAssertFalse(text.contains("wrong preview"))
        XCTAssertTrue(FileManager.default.fileExists(atPath:log.directory.appendingPathComponent("events.partial-fragment.txt").path))
        let rows = try String(contentsOf:log.directory.appendingPathComponent("events.jsonl")).split(separator:"\n").map { try JSONSerialization.jsonObject(with:Data($0.utf8)) as! [String:Any] }
        XCTAssertEqual(rows.last?["event_type"] as? String,"session.recovered")
        let again = try LogRecovery.recoverIfNeeded(root:root); XCTAssertFalse(again)
    }
    func testIndependentModelsHaveDifferentSetupContracts() throws {
        let migrated = try Configuration.decode(Data(#"{"apiKey":"  test-key  ","pipeline":"translate"}"#.utf8))
        XCTAssertEqual(migrated.apiKey,"test-key"); XCTAssertEqual(migrated.systemChannelMode,.auto)
        var c = Configuration()
        let transcribe = c.setup()["setup"] as! [String: Any]
        XCTAssertEqual(transcribe["model"] as? String, "models/gemini-3.5-transcribe-live")
        XCTAssertNotNil(transcribe["inputAudioTranscription"])
        let tg = transcribe["generationConfig"] as! [String: Any]
        XCTAssertEqual(tg["responseModalities"] as? [String], ["TEXT"])
        XCTAssertNil(tg["translationConfig"]); XCTAssertNil(tg["outputAudioTranscription"])
        c.pipeline = .translate; c.translateProvider = .google
        let translate = c.setup()["setup"] as! [String: Any]
        let generation = translate["generationConfig"] as! [String: Any]
        XCTAssertEqual(generation["responseModalities"] as? [String], ["AUDIO"])
        XCTAssertNotNil(translate["inputAudioTranscription"])
        XCTAssertNotNil(translate["outputAudioTranscription"])
        XCTAssertNotNil(generation["translationConfig"])
        XCTAssertNil(generation["inputAudioTranscription"])
        XCTAssertNil(generation["outputAudioTranscription"])
        c.translationMode = .speech
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: translate, options: .sortedKeys), try JSONSerialization.data(withJSONObject: c.setup()["setup"]!, options: .sortedKeys))
    }
    func testInterimCorrectionFinalAndNewUtteranceDoNotDuplicate() throws {
        var state = Transcript()
        let messages = [
            #"{"serverContent":{"interimInputTranscription":{"text":"Energy story"}}}"#,
            #"{"serverContent":{"interimInputTranscription":{"text":"Energy storage","finished":true}}}"#,
            #"{"serverContent":{"inputTranscription":{"text":"Energy storage matters."}}}"#,
            #"{"serverContent":{"inputTranscription":{"text":"Next slide."}}}"#
        ]
        for m in messages { for case .text(let u) in try GoogleProtocol.events(from: Data(m.utf8), pipeline: .transcribe) { _ = state.apply(u, epoch: 1, pipeline: .transcribe) } }
        XCTAssertEqual(state.segments.count, 2)
        XCTAssertEqual(state.segments[0].text, "Energy storage matters.")
        XCTAssertEqual(state.segments[0].revision, 3)
        XCTAssertEqual(state.segments[0].finality, .final)
        XCTAssertFalse(state.recentText(track: "source").contains("story"))
    }
    func testInterruptedHypothesisRemainsExplicitlyUnconfirmed() {
        var state = Transcript()
        _ = state.apply(TextUpdate(track: "source", text: "not yet complete", replace: true, finality: .interim), epoch: 1, pipeline: .transcribe)
        _ = state.close(epoch: 1, providerBoundary: false)
        _ = state.apply(TextUpdate(track: "source", text: "new connection", replace: true, finality: .interim), epoch: 2, pipeline: .transcribe)
        XCTAssertEqual(state.segments.count, 2)
        XCTAssertEqual(state.segments[0].finality, .unconfirmed)
        XCTAssertEqual(state.segments[1].epoch, 2)
    }
    func testTranslateAudioAndIndependentTextTracks() throws {
        let m = #"{"serverContent":{"inputTranscription":{"text":"Hello"},"outputTranscription":{"text":"你好"},"modelTurn":{"parts":[{"inlineData":{"mimeType":"audio/pcm;rate=24000","data":"AAA="}}]},"turnComplete":true}}"#
        let events = try GoogleProtocol.events(from: Data(m.utf8), pipeline: .translate)
        var tracks: [String] = []; var audioCount = 0; var boundary = false
        for event in events {
            if case .text(let u) = event { tracks.append(u.track); XCTAssertFalse(u.replace) }
            if case .audio(let bytes, let rate) = event { audioCount += 1; XCTAssertEqual(bytes.count,2); XCTAssertEqual(rate,24000) }
            if case .boundary = event { boundary = true }
        }
        XCTAssertEqual(tracks,["source","translation"]); XCTAssertEqual(audioCount,1); XCTAssertTrue(boundary)
    }
    func testOngoingClassReadableBeforeFinalAndAfterCorrection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var config = Configuration(); config.apiKey = "test-secret-never-log"
        let log = try SessionLog(configuration: config, rootOverride: root)
        try await log.begin(); try await log.beginEpoch(1, configuration: config)
        try await log.text(TextUpdate(track: "source", text: "This is an unfinished lecture", replace: true, finality: .interim), epoch: 1)
        try await Task.sleep(nanoseconds: 650_000_000)
        let dir = log.directory
        let partial = try String(contentsOf: dir.appendingPathComponent("live.md"))
        XCTAssertTrue(partial.contains("unfinished lecture")); XCTAssertTrue(partial.contains("识别中"))
        try await log.text(TextUpdate(track: "source", text: "This is the final lecture text.", replace: true, finality: .final, boundary: true), epoch: 1)
        try await log.flush()
        let full = try String(contentsOf: dir.appendingPathComponent("transcript.md"))
        XCTAssertFalse(full.contains("unfinished lecture")); XCTAssertEqual(full.components(separatedBy: "This is the final lecture text.").count-1,1)
        let events = try String(contentsOf: dir.appendingPathComponent("events.jsonl"))
        XCTAssertFalse(events.contains(config.apiKey))
        let lines = try events.split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        XCTAssertEqual(lines.compactMap { $0["sequence"] as? Int },Array(1...lines.count))
        let index = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("latest.json"))) as! [String: Any]
        XCTAssertEqual(index["active"] as? Bool,true)
        XCTAssertEqual(index["written_sequence"] as? Int,index["snapshot_sequence"] as? Int)
        try await log.finish(tailIncomplete: false)
        let stopped = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("latest.json"))) as! [String: Any]
        XCTAssertEqual(stopped["active"] as? Bool,false)
        let stoppedIndex = try Data(contentsOf:root.appendingPathComponent("latest.json"))
        try await log.setState("late_running_callback"); try await log.flush()
        let afterLateCallback = try Data(contentsOf:root.appendingPathComponent("latest.json"))
        XCTAssertEqual(stoppedIndex,afterLateCallback)
    }
    func testRouteSwitchPreservesOneSessionAndLateOldMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var config = Configuration(); config.pipeline = .translate
        let log = try SessionLog(configuration: config, rootOverride: root)
        try await log.begin(); try await log.beginEpoch(1, configuration: config)
        config.pipeline = .transcribe; try await log.beginEpoch(2, configuration: config)
        try await log.text(TextUpdate(track: "translation", text: "旧连接尾部", replace: false), epoch: 1)
        try await log.text(TextUpdate(track: "source", text: "New original", replace: true, finality: .final, boundary: true), epoch: 2)
        var restored = config; restored.pipeline = .translate
        try await log.activateEpoch(1,configuration:restored)
        let meta = try JSONSerialization.jsonObject(with:Data(contentsOf:log.directory.appendingPathComponent("session.json"))) as! [String:Any]
        XCTAssertEqual(meta["connection_count"] as? Int,2)
        XCTAssertEqual(meta["active_connection_epoch"] as? Int,1)
        try await log.finish(tailIncomplete: true)
        let rows = try String(contentsOf: log.directory.appendingPathComponent("events.jsonl")).split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        let old = rows.first { $0["text"] as? String == "旧连接尾部" }!
        XCTAssertEqual(old["pipeline"] as? String,"translate")
        XCTAssertEqual(Set(rows.compactMap { $0["session_id"] as? String }).count,1)
    }
    func testRingHandlesStereoAntiPhaseWithoutLosingSpeech() throws {
        XCTAssertEqual(lc_process_descends_from(getpid(),getpid()),1)
        XCTAssertEqual(lc_process_descends_from(getpid(),0),0)
        if getppid()>1 { XCTAssertEqual(lc_process_descends_from(getpid(),getppid()),1) }
        let ring = lc_ring_create()!; defer { lc_ring_destroy(ring) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!; buffer.frameLength = 480
        for i in 0..<480 { buffer.floatChannelData![0][i] = 0.2; buffer.floatChannelData![1][i] = -0.2 }
        var desc = format.streamDescription.pointee
        XCTAssertEqual(lc_ring_write(ring, buffer.audioBufferList, &desc, 480, 0),1)
        var mono = [Float](repeating: 0, count: 480); var rate = 0.0; var host: UInt64 = 0
        let count = mono.withUnsafeMutableBufferPointer { lc_ring_read(ring,$0.baseAddress,480,&rate,&host) }
        XCTAssertEqual(count,480); XCTAssertEqual(rate,48000); XCTAssertEqual(mono[0],0.2,accuracy:0.001)
        lc_ring_set_channel_mode(ring,2)
        XCTAssertEqual(lc_ring_write(ring,buffer.audioBufferList,&desc,480,0),1)
        _ = mono.withUnsafeMutableBufferPointer { lc_ring_read(ring,$0.baseAddress,480,&rate,&host) }
        XCTAssertEqual(mono[0],-0.2,accuracy:0.001)
        for _ in 0..<200 { _ = lc_ring_write(ring,buffer.audioBufferList,&desc,480,0) }
        XCTAssertGreaterThan(lc_ring_dropped(ring),0)
    }
    func testEmbeddedNoiseSuppressorReallyProcessesFiniteAudio() throws {
        let processor = lc_noise_create(); XCTAssertNotNil(processor)
        guard let processor else { return }; defer { lc_noise_destroy(processor) }
        var seed: UInt64 = 17; var before = 0.0; var after = 0.0
        for frame in 0..<300 {
            var audio = (0..<480).map { _ -> Float in seed = seed &* 6364136223846793005 &+ 1; return Float(Int64(bitPattern: seed)>>40)/Float(1<<23)*0.08 }
            if frame > 150 { before += audio.reduce(0) { $0+Double($1*$1) } }
            XCTAssertEqual(audio.withUnsafeMutableBufferPointer { lc_noise_process(processor,$0.baseAddress) },0)
            XCTAssertTrue(audio.allSatisfy { $0.isFinite && abs($0)<=1 })
            if frame > 150 { after += audio.reduce(0) { $0+Double($1*$1) } }
        }
        XCTAssertGreaterThan(after,0); XCTAssertLessThan(after,before*0.95)
    }
}
