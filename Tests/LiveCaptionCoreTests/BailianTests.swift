import Foundation
import LiveCaptionCore

private actor SimulatedBailian: RealtimeTransport {
    private var queue: [Data] = []
    private var waiter: CheckedContinuation<Data,Error>?
    private var closed = false
    private var messages: [[String:Any]] = []
    private var request: URLRequest?
    let acknowledge: Bool
    let greet: Bool
    let failSetup: Bool
    let duplicateGreeting: Bool
    let delayedPlayout: Bool
    let signalPlayout: Bool
    let lateDetectionChange: Bool
    init(acknowledge: Bool = true, greet: Bool = true, failSetup: Bool = false,duplicateGreeting:Bool = false,delayedPlayout:Bool = false,signalPlayout:Bool = true,lateDetectionChange:Bool = false) {
        self.lateDetectionChange=lateDetectionChange
        self.acknowledge = acknowledge; self.greet = greet; self.failSetup = failSetup
        self.duplicateGreeting=duplicateGreeting
        self.delayedPlayout=delayedPlayout; self.signalPlayout=signalPlayout
    }
    private func push(_ object: [String:Any]) throws {
        let bytes = try JSONSerialization.data(withJSONObject:object)
        if let waiter { self.waiter = nil; waiter.resume(returning:bytes) }
        else { queue.append(bytes) }
    }
    func open(_ request: URLRequest) async throws {
        self.request = request
        if greet { try push(["type":"session.created"]) }
        if greet && duplicateGreeting { try push(["type":"session.created"]) }
    }
    func send(_ data: Data) async throws {
        let object = try JSONSerialization.jsonObject(with:data) as! [String:Any]
        messages.append(object)
        switch object["type"] as? String {
        case "session.update":
            if failSetup {
                try push(["type":"error","error":["code":"401","message":request?.value(forHTTPHeaderField:"Authorization") ?? ""]])
            } else {
                var session = object["session"] as! [String:Any]
                session["model"] = "qwen3.8-livetranslate-flash-realtime"
                let requestedInput = (session["audio"] as? [String:Any])?["input"] as? [String:Any] ?? [:]
                session["audio"] = ["input":["format":["type":"pcm","sample_rate":16000],"turn_detection":requestedInput["turn_detection"] ?? [:]],"output":["format":["type":"pcm","sample_rate":24000]]]
                try push(["type":"session.updated","session":session])
            }
        case "input_audio_buffer.append":
            if lateDetectionChange {
                try push(["type":"session.updated","session":["model":"qwen3.8-livetranslate-flash-realtime",
                    "output_modalities":["text"],"translation":["language":"zh"],
                    "audio":["input":["format":["type":"pcm","sample_rate":16000],"turn_detection":["type":"speaker_detection","threshold":0.5]]]]])
            }
            try push(["type":"conversation.item.input_audio_transcription.delta","item_id":"source1","delta":"The classroom"])
            try push(["type":"response.text.delta","response_id":"response1","item_id":"target1","delta":"课堂"])
        case "session.finish":
            if acknowledge {
                try push(["type":"conversation.item.input_audio_transcription.completed","item_id":"source1","transcript":"The classroom continues."])
                try push(["type":"response.done","response":["id":"response1","status":"completed","output":[["id":"target1","content":[["type":"text","text":"课堂继续。"]]]]]])
                if delayedPlayout {
                    if signalPlayout { try push(["type":"_webrtc.stage","stage":"playout.draining","remote_finished":true]) }
                    Task {
                        try? await Task.sleep(nanoseconds:250_000_000)
                        if !closed { try? push(["type":"session.finished"]) }
                    }
                } else { try push(["type":"session.finished"]) }
            }
        default: break
        }
    }
    func receive() async throws -> Data {
        if !queue.isEmpty { return queue.removeFirst() }
        if closed { throw CaptionError.message("closed") }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func close() async {
        closed = true; waiter?.resume(throwing:CaptionError.message("closed")); waiter = nil
    }
    func sentTypes() -> [String] { messages.compactMap { $0["type"] as? String } }
    func wasOpened() -> Bool { request != nil }
    func keyIsolated() -> Bool {
        request?.value(forHTTPHeaderField:"Authorization") == "Bearer bailian-test-secret" && request?.value(forHTTPHeaderField:"x-goog-api-key") == nil
    }
}

private actor CollectedEvents {
    var events: [ProviderEvent] = []
    func append(_ event: ProviderEvent) { events.append(event) }
    func source() -> String {
        var state = Transcript()
        for case .text(let update) in events { _ = state.apply(update,epoch:1,pipeline:.translate) }
        return state.recentText(track:"source")
    }
    func errors() -> [String] { events.compactMap { if case .error(let text) = $0 { return text }; return nil } }
    func diagnosticNames() -> [String] { events.compactMap { if case .diagnostic(let name,_) = $0 { return name }; return nil } }
}

extension PipelineChecks {
    func testBailianSpeakerIdentityIsPreserved() async throws {
        var parser=BailianProtocol()
        var observed:[Int]=[]
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("speaker-check-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let log=try SessionLog(configuration:bailianConfiguration(),rootOverride:root)
        try await log.begin();try await log.beginEpoch(1,configuration:bailianConfiguration())
        for (index,speaker) in [0,0,2,2].enumerated() {
            let source="speaker-source-\(index)",target="speaker-target-\(index)"
            let start:[String:Any] = ["type":"input_audio_buffer.speech_started","item_id":source,"audio_start_ms":index*1000,"speaker_id":speaker]
            for case .diagnostic(_,let fields) in try parser.events(from:JSONSerialization.data(withJSONObject:start)) {
                if let id=fields["speaker_id"] as? Int { observed.append(id) }
            }
            _ = try parser.events(from:JSONSerialization.data(withJSONObject:["type":"conversation.item.created","previous_item_id":source,"item":["id":target,"content":[]]]))
            let events=try parser.events(from:JSONSerialization.data(withJSONObject:["type":"response.text.delta","item_id":target,"response_id":"r\(index)","delta":"中文"] ))
            for case .text(let update) in events {
                XCTAssertEqual(update.speakerID,speaker)
                let transcript=try await log.text(update,epoch:1)
                XCTAssertEqual(transcript.segments.last?.speakerID,speaker)
            }
        }
        XCTAssertEqual(observed,[0,0,2,2]);XCTAssertEqual(Set(observed).count,2)
        let vad=try parser.events(from:Data(#"{"type":"input_audio_buffer.speech_started","item_id":"no-speaker","audio_start_ms":5000}"#.utf8))
        for case .diagnostic(_,let fields) in vad { XCTAssertNil(fields["speaker_id"]) }
        try await log.finish(tailIncomplete:false)
        let directory=await log.directory
        let records=try String(contentsOf:directory.appendingPathComponent("events.jsonl")).split(separator:"\n").compactMap { try JSONSerialization.jsonObject(with:Data($0.utf8)) as? [String:Any] }
        let text=records.filter { ($0["event_type"] as? String)?.hasPrefix("text.") == true }
        XCTAssertEqual(text.compactMap{$0["speaker_id"] as? Int},[0,0,2,2])
        for bad in [true,-1,1.5,"1"] as [Any] {
            let e=try parser.events(from:JSONSerialization.data(withJSONObject:["type":"input_audio_buffer.speech_started","item_id":"invalid-\(bad)","speaker_id":bad]))
            for case .diagnostic(_,let fields) in e { XCTAssertNil(fields["speaker_id"]) }
        }
    }
    func testBailianLaterDetectorChangeCannotSilentlyFallback() async throws {
        var c=bailianConfiguration();c.translationMode = .subtitles;c.bailianTurnDetection = .serverVAD
        let transport=SimulatedBailian(lateDetectionChange:true),events=CollectedEvents()
        let connection=BailianConnection(configuration:c,transport:transport) { await events.append($0) }
        try await connection.connect();try await connection.sendAudio(Data(repeating:0,count:640))
        try await Task.sleep(nanoseconds:150_000_000)
        let errors=await events.errors(),names=await events.diagnosticNames(),sent=await transport.sentTypes()
        XCTAssertTrue(errors.contains(where:{$0.contains("语段检测")}))
        XCTAssertTrue(names.contains("provider.configuration_rejected"))
        XCTAssertEqual(sent.filter{$0 == "session.update"}.count,1)
        await connection.close()
    }
    func testTextOnlyNeverOpensGoogleAudioTranslation() async throws {
        var c = bailianConfiguration(); c.translateProvider = .google
        let transport = SimulatedBailian()
        let connection = GoogleConnection(configuration:c,transport:transport) { _ in }
        var rejected = false
        do { try await connection.connect() }
        catch { rejected = error.localizedDescription.contains("不支持仅文字") }
        XCTAssertTrue(rejected)
        let opened = await transport.wasOpened()
        XCTAssertFalse(opened)
        let sent = await transport.sentTypes()
        XCTAssertTrue(sent.isEmpty)
        await connection.close()
        c.translationMode = .speech; try c.validate()
        c.pipeline = .transcribe; c.translationMode = .subtitles; try c.validate()
    }
    func testClassroomConnectionRotationPolicy() {
        var config=Configuration();config.pipeline = .translate;config.translateProvider = .bailian
        for mode in [OutputMode.subtitles,.speech] {
            config.translationMode=mode
            XCTAssertNil(config.scheduledConnectionRotationSeconds)
        }
        config.pipeline = .transcribe
        XCTAssertEqual(config.scheduledConnectionRotationSeconds,540)
        config.pipeline = .translate;config.translateProvider = .google
        XCTAssertEqual(config.scheduledConnectionRotationSeconds,540)
    }
    func testBailianConfirmsRequestedSession() throws {
        for mode in OutputMode.allCases {
          for detector in BailianTurnDetection.allCases {
            var c = bailianConfiguration(); c.translationMode = mode; c.bailianTurnDetection = detector
            var session = BailianProtocol.setup(configuration:c)["session"] as! [String:Any]
            session["model"] = c.bailianTranslateModel
            session["audio"] = ["input":["format":["type":"pcm","sample_rate":16000],"turn_detection":detector.settings(for:mode)],"output":["format":["type":"pcm","sample_rate":24000],"voice":"Tina"]]
            let confirmed = try BailianProtocol.confirmedSession(["session":session],configuration:c)
            XCTAssertEqual(confirmed["target_language"] as? String,"zh")
            XCTAssertEqual(confirmed["audio_output_requested"] as? Bool,mode == .speech)
            XCTAssertEqual(confirmed["output_sample_rate"] as? Int,mode == .speech ? 24000 : nil)
            let expected = detector == .automatic ? BailianTurnDetection.serverVAD : detector
            XCTAssertEqual(confirmed["turn_detection"] as? String,expected.rawValue)
            XCTAssertEqual(confirmed["requested_turn_detection"] as? String,expected.rawValue)
            XCTAssertEqual((confirmed["server_turn_detection"] as? [String:Any])?["type"] as? String,expected.rawValue)
            XCTAssertEqual(confirmed["server_audio_output_voice"] as? String,mode == .speech ? "Tina":nil)
            if mode == .speech {
                XCTAssertEqual(confirmed["voice_clone_requested"] as? Bool,false)
                var cloneEnabled=session;cloneEnabled["enable_voice_clone"]=true
                var rejectedClone=false
                do { _=try BailianProtocol.confirmedSession(["session":cloneEnabled],configuration:c) } catch { rejectedClone=true }
                XCTAssertTrue(rejectedClone)
                var wrongVoice=session;wrongVoice["voice"]="default"
                var rejectedVoice=false
                do { _=try BailianProtocol.confirmedSession(["session":wrongVoice],configuration:c) } catch { rejectedVoice=true }
                XCTAssertTrue(rejectedVoice)
            }
            var wrong = session; wrong["translation"] = ["language":"en"]
            var rejected = false
            do { _ = try BailianProtocol.confirmedSession(["session":wrong],configuration:c) } catch { rejected = true }; XCTAssertTrue(rejected)
            wrong = session; wrong["output_modalities"] = mode == .speech ? ["text"] : ["text","audio"]
            rejected = false
            do { _ = try BailianProtocol.confirmedSession(["session":wrong],configuration:c) } catch { rejected = true }; XCTAssertTrue(rejected)
            wrong = session; wrong["audio"] = ["input":["format":["type":"pcm","sample_rate":48000]]]
            rejected = false
            do { _ = try BailianProtocol.confirmedSession(["session":wrong],configuration:c) } catch { rejected = true }; XCTAssertTrue(rejected)
            wrong = session
            var wrongAudio = session["audio"] as! [String:Any]
            var wrongInput = wrongAudio["input"] as! [String:Any]
            wrongInput["turn_detection"] = (expected == .serverVAD ? BailianTurnDetection.speakerDetection : .serverVAD).settings(for:mode)
            wrongAudio["input"] = wrongInput; wrong["audio"] = wrongAudio
            rejected = false
            do { _ = try BailianProtocol.confirmedSession(["session":wrong],configuration:c) } catch { rejected = true }; XCTAssertTrue(rejected)
            if expected == .speakerDetection {
                wrongInput["turn_detection"] = ["type":expected.rawValue,"threshold":0.9]
                wrongAudio["input"] = wrongInput; wrong["audio"] = wrongAudio
                rejected = false
                do { _ = try BailianProtocol.confirmedSession(["session":wrong],configuration:c) } catch { rejected = true }; XCTAssertTrue(rejected)
            }
          }
        }
    }
    func testBailianSourceAssociationAndAudioClock() throws {
        var parser = BailianProtocol()
        _ = try parser.events(from:Data(#"{"type":"input_audio_buffer.speech_started","item_id":"s1","audio_start_ms":420}"#.utf8))
        _ = try parser.events(from:Data(#"{"type":"conversation.item.created","item":{"id":"s1","content":[{"type":"input_audio"}]}}"#.utf8))
        _ = try parser.events(from:Data(#"{"type":"conversation.item.created","previous_item_id":"s1","item":{"id":"t1","content":[]}}"#.utf8))
        _ = try parser.events(from:Data(#"{"type":"input_audio_buffer.speech_stopped","item_id":"s1","audio_end_ms":1260}"#.utf8))
        let events = try parser.events(from:Data(#"{"type":"response.text.delta","response_id":"r1","item_id":"t1","delta":"中文"}"#.utf8))
        guard case .text(let text) = events.first else { XCTAssertTrue(false); return }
        XCTAssertEqual(text.sourceProviderID,"s1"); XCTAssertEqual(text.start,420); XCTAssertEqual(text.end,1260)
        var transcript = Transcript(); _ = transcript.apply(text,epoch:1,pipeline:.translate)
        XCTAssertEqual(transcript.segments.first?.sourceProviderID,"s1")
    }
    private func bailianConfiguration() -> Configuration {
        var c = Configuration(); c.pipeline = .translate
        c.apiKey = "google-test-secret"; c.bailianAPIKey = "bailian-test-secret"; c.bailianWorkspaceID = "workspace-example"
        return c
    }
    func testBailianConfiguration() throws {
        var c = bailianConfiguration(); try c.validate()
        XCTAssertEqual(c.model,"qwen3.8-livetranslate-flash-realtime")
        XCTAssertEqual(c.bailianURL.host,"workspace-example.ap-southeast-1.maas.aliyuncs.com")
        c.bailianRegion = .beijing
        XCTAssertEqual(c.bailianURL.host,"workspace-example.cn-beijing.maas.aliyuncs.com")
        let setup = BailianProtocol.setup(configuration:c)["session"] as! [String:Any]
        XCTAssertEqual(setup["output_modalities"] as? [String],["text"])
        XCTAssertNil(setup["voice"]); XCTAssertNil(setup["enable_voice_clone"]); XCTAssertNil(setup["voice_clone_options"])
        XCTAssertNil((setup["audio"] as? [String:Any])?["output"])
        XCTAssertEqual((setup["translation"] as? [String:String])?["language"],"zh")
        XCTAssertNil(setup["input_audio_transcription"])
        c.translationMode = .speech
        let speech = BailianProtocol.setup(configuration:c)["session"] as! [String:Any]
        XCTAssertEqual(speech["output_modalities"] as? [String],["text","audio"])
        XCTAssertEqual(speech["voice"] as? String,"Tina")
        XCTAssertEqual(speech["enable_voice_clone"] as? Bool,false)
        XCTAssertNil(speech["voice_clone_options"])
        let json = String(decoding:try JSONSerialization.data(withJSONObject:c.safeMetadata),as:UTF8.self)
        XCTAssertFalse(json.contains(c.apiKey)); XCTAssertFalse(json.contains(c.bailianAPIKey))
        c.pipeline = .transcribe
        XCTAssertEqual(c.provider,.google); XCTAssertEqual(c.model,c.transcribeModel)
        c.bailianAPIKey = ""; try c.validate() // Transcribe needs only its own key.
        c.pipeline = .translate
        var rejected = false
        do { try c.validate() } catch { rejected = true }
        XCTAssertTrue(rejected) // Never fall back to sending Google's key to Bailian.
        let legacy = try Configuration.decode(Data(#"{"apiKey":"legacy-google","pipeline":"translate"}"#.utf8))
        XCTAssertEqual(legacy.provider,.google)
        c.bailianAPIKey = "bailian-test-secret"; c.bailianWorkspaceID = "example/other-host"
        rejected = false
        do { try c.validate() } catch { rejected = true }; XCTAssertTrue(rejected)
    }
    func testBailianInterleavedText() throws {
        var parser = BailianProtocol(); var state = Transcript()
        let input = [
            #"{"type":"conversation.item.input_audio_transcription.delta","item_id":"s1","delta":"bad preview"}"#,
            #"{"type":"conversation.item.input_audio_transcription.delta","item_id":"s2","delta":"Next"}"#,
            #"{"type":"response.text.delta","event_id":"unique1","response_id":"r1","item_id":"t1","delta":"临时"}"#,
            #"{"type":"response.text.delta","event_id":"unique1","response_id":"r1","item_id":"t1","delta":"临时"}"#,
            #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"s1","transcript":"Correct source."}"#,
            #"{"type":"response.text.done","response_id":"r1","item_id":"t1","text":"最终译文。"}"#,
            #"{"type":"response.done","response":{"id":"r1","status":"completed","output":[{"id":"t1","content":[{"text":"最终译文。"}]}]}}"#,
            #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"s2","transcript":"Next source."}"#
        ]
        for message in input {
            for case .text(let u) in try parser.events(from:Data(message.utf8)) { _ = state.apply(u,epoch:1,pipeline:.translate) }
        }
        XCTAssertEqual(state.segments.count,3)
        XCTAssertEqual(state.segments[0].text,"Correct source.")
        XCTAssertEqual(state.segments[1].text,"Next source.")
        XCTAssertEqual(state.segments[2].text,"最终译文。")
        XCTAssertEqual(state.segments[2].revision,3)
        XCTAssertTrue(state.segments.allSatisfy { $0.finality == .final && $0.closed })
        // Late corrections target the original identified segment, even after it was closed.
        _ = state.apply(TextUpdate(track:"source",text:"",replace:true,finality:.final,boundary:true,providerID:"s1"),epoch:1,pipeline:.translate)
        XCTAssertEqual(state.segments.count,3); XCTAssertEqual(state.segments[0].text,"")
        _ = state.apply(TextUpdate(track:"source",text:"new epoch",replace:true,providerID:"s1"),epoch:2,pipeline:.translate)
        XCTAssertEqual(state.segments.count,4)
    }
    func testBailianAudioAndInterruptedResponse() throws {
        var parser = BailianProtocol(); var state = Transcript(); var bytes = 0
        let messages = [
            #"{"type":"response.audio_transcript.delta","item_id":"t1","response_id":"r1","delta":"译文"}"#,
            #"{"type":"response.audio.delta","delta":"AAA="}"#,
            #"{"type":"response.audio_transcript.done","item_id":"t1","response_id":"r1","transcript":"不完整译文"}"#,
            #"{"type":"response.done","response":{"id":"r1","status":"incomplete","output":[],"usage":{"input_tokens":7}}}"#
        ]
        for message in messages {
            for event in try parser.events(from:Data(message.utf8)) {
                if case .text(let u) = event { _ = state.apply(u,epoch:1,pipeline:.translate) }
                if case .audio(let data,let rate) = event { bytes += data.count; XCTAssertEqual(rate,24000) }
            }
        }
        XCTAssertEqual(bytes,2); XCTAssertEqual(state.segments.count,1)
        XCTAssertEqual(state.segments[0].text,"不完整译文"); XCTAssertEqual(state.segments[0].finality,.unconfirmed)
        var rejected = false
        do { _ = try parser.events(from:Data(#"{"type":"response.text.text","text":"old snapshot"}"#.utf8)) } catch { rejected = true }
        XCTAssertTrue(rejected)
    }
    func testBailianLifecycle() async throws {
        let transport = SimulatedBailian(); let evidence = CollectedEvents()
        let connection = BailianConnection(configuration:bailianConfiguration(),transport:transport,timeout:1) { await evidence.append($0) }
        try await connection.connect()
        try await connection.sendAudio(Data([0,0,1,0]))
        let complete = await connection.finish()
        XCTAssertTrue(complete)
        let source = await evidence.source(); XCTAssertEqual(source,"The classroom continues.")
        let keyIsolated = await transport.keyIsolated(); XCTAssertTrue(keyIsolated)
        let types = await transport.sentTypes(); XCTAssertEqual(types,["session.update","input_audio_buffer.append","session.finish"])
        var rejected = false
        do { try await connection.sendAudio(Data([0,0])) } catch { rejected = true }; XCTAssertTrue(rejected)
        await connection.close()
    }
    func testBailianDuplicateGreeting() async throws {
        let transport=SimulatedBailian(duplicateGreeting:true)
        let connection=BailianConnection(configuration:bailianConfiguration(),transport:transport,timeout:1) { _ in }
        try await connection.connect()
        let types=await transport.sentTypes()
        XCTAssertEqual(types.filter { $0 == "session.update" }.count,1)
        await connection.close()
    }
    func testBailianNativePlayoutDeadline() async throws {
        for signal in [true,false] {
            let transport=SimulatedBailian(delayedPlayout:true,signalPlayout:signal)
            let connection=BailianConnection(configuration:bailianConfiguration(),transport:transport,timeout:0.1) { _ in }
            try await connection.connect()
            let complete=await connection.finish()
            // Ordinary absent terminal responses must still time out; only native
            // confirmation of the server terminal event permits the playout window.
            XCTAssertEqual(complete,signal)
            await connection.close()
        }
    }
    func testBailianFailureAndTimeout() async throws {
        let timeoutTransport = SimulatedBailian(acknowledge:false)
        let connection = BailianConnection(configuration:bailianConfiguration(),transport:timeoutTransport,timeout:0.1) { _ in }
        try await connection.connect()
        let complete = await connection.finish(); XCTAssertFalse(complete); await connection.close()
        let noHello = BailianConnection(configuration:bailianConfiguration(),transport:SimulatedBailian(greet:false),timeout:0.1) { _ in }
        var rejected = false
        do { try await noHello.connect() } catch { rejected = true }; XCTAssertTrue(rejected); await noHello.close()
        let errors = CollectedEvents()
        let fail = BailianConnection(configuration:bailianConfiguration(),transport:SimulatedBailian(failSetup:true),timeout:0.2) { await errors.append($0) }
        rejected = false
        do { try await fail.connect() } catch {
            rejected = true; XCTAssertFalse(error.localizedDescription.contains("bailian-test-secret"))
        }
        XCTAssertTrue(rejected); let recorded = await errors.errors()
        XCTAssertFalse(recorded.joined().contains("bailian-test-secret")); await fail.close()
    }
    func testBailianLiveLogAndRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let config = bailianConfiguration(); let log = try SessionLog(configuration:config,rootOverride:root)
        try await log.begin(); try await log.beginEpoch(1,configuration:config)
        let c = BailianConnection(configuration:config,transport:SimulatedBailian(),timeout:1) { event in
            if case .text(let text) = event { _ = try? await log.text(text,epoch:1) }
        }
        try await c.connect(); try await c.sendAudio(Data([0,0]))
        try await Task.sleep(nanoseconds:400_000_000)
        let live = try String(contentsOf:log.directory.appendingPathComponent("live.md"))
        XCTAssertTrue(live.contains("The classroom")); XCTAssertTrue(live.contains("记录中"))
        let complete = await c.finish(); XCTAssertTrue(complete); await c.close(); try await log.flush()
        let journal = try String(contentsOf:log.directory.appendingPathComponent("events.jsonl"))
        XCTAssertFalse(journal.contains(config.apiKey)); XCTAssertFalse(journal.contains(config.bailianAPIKey))
        XCTAssertTrue(journal.contains("provider_segment_id"))
        let metaURL = log.directory.appendingPathComponent("session.json")
        var meta = try JSONSerialization.jsonObject(with:Data(contentsOf:metaURL)) as! [String:Any]
        meta["owner_pid"] = 0
        try JSONSerialization.data(withJSONObject:meta).write(to:metaURL,options:.atomic)
        _ = try LogRecovery.recoverIfNeeded(root:root)
        let recovered = try String(contentsOf:log.directory.appendingPathComponent("transcript.md"))
        XCTAssertTrue(recovered.contains("The classroom continues."))
        XCTAssertTrue(recovered.contains("课堂继续。"))
        XCTAssertEqual(recovered.components(separatedBy:"课堂继续。").count-1,1)
    }
}
