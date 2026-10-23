import Foundation
import LiveCaptionCore

private actor SaTGate {
    var inputs:[CaptionReflowInput]=[]
    var waiting:[Int:CheckedContinuation<String,Error>]=[:]
    func call(_ input:CaptionReflowInput) async throws -> String {
        let i=inputs.count;inputs.append(input)
        return try await withCheckedThrowingContinuation { waiting[i]=$0 }
    }
    func count()->Int { inputs.count }
    func resolve(_ i:Int) {
        guard inputs.indices.contains(i) else { return }
        let input=inputs[i]
        var points=input.providerBoundaries.filter { $0.count == 2 && $0[0]>0 && (input.translation.isEmpty || $0[1]>0) }
        if input.translation.isEmpty && input.source.count>3 { points=[[input.source.count/2,0]] }
        points=points.filter { $0[0]<input.source.count }
        points.append([input.source.count,input.translation.count])
        let data=try! JSONSerialization.data(withJSONObject:["groups":points])
        waiting.removeValue(forKey:i)?.resume(returning:String(decoding:data,as:UTF8.self))
    }
}

extension PipelineChecks {
    func testSaTLocalSelectionAndExplicitBilingualLinks() async throws {
        var c=SaTReflowConfiguration();c.minimumCharacters=20
        let s1="This first explanation concerns memory and sleep. ",s2="Now the lecturer discusses possible treatments and trials."
        let t1="第一部分解释睡眠和记忆之间的关系。",t2="接下来讨论可能的治疗方法以及临床试验。"
        let first=CaptionReflowInput(source:s1,translation:t1)
        let input=CaptionReflowInput(source:s1+s2,translation:t1+t2,providerBoundaries:[[first.source.count,first.translation.count]])
        let infer:SaTCaptionReflow.Infer = { request,c in
            let data=try JSONSerialization.jsonObject(with:request) as! [String:Any]
            let source=data["source"] as! [String],target=data["translation"] as! [String]
            return try JSONSerialization.data(withJSONObject:["version":1,"model":c.model,
                "source":source.indices.map { ["end":$0+1,"probability":0.95] as [String:Any] },
                "translation":target.indices.map { ["end":$0+1,"probability":0.95] as [String:Any] }])
        }
        let result=try await SaTCaptionReflow.complete(input,configuration:c,infer:infer)
        let rows=try input.render(result,id:"sat")
        XCTAssertEqual(rows.count,2);XCTAssertEqual(rows[0].source,s1);XCTAssertEqual(rows[0].translation,t1)
        let noLink=CaptionReflowInput(source:s1+s2,translation:t1+t2)
        let retained=try await SaTCaptionReflow.complete(noLink,configuration:c,infer:infer)
        XCTAssertEqual(try noLink.render(retained,id:"retained").count,1)
        let restored=try Configuration.decode(JSONEncoder().encode({ () -> Configuration in
            var v=Configuration();v.captionReflow.enabled=true;v.captionReflow.sat=c;return v
        }()))
        XCTAssertEqual(restored.captionReflow.sat,c);try restored.captionReflow.validate()
    }
    func testSaTLongLowConfidenceKeepsReadableLinkedParagraphs() async throws {
        let source=String(repeating:"A complete explanation with an explicit translation link. ",count:12)
        let translation=String(repeating:"这是一段有明确原译文关联的完整说明。",count:10)
        let first=CaptionReflowInput(source:source,translation:translation)
        let input=CaptionReflowInput(source:source+source,translation:translation+translation,
            providerBoundaries:[[first.source.count,first.translation.count]])
        let infer:SaTCaptionReflow.Infer = { request,c in
            let data=try JSONSerialization.jsonObject(with:request) as! [String:Any]
            let source=data["source"] as! [String],target=data["translation"] as! [String]
            return try JSONSerialization.data(withJSONObject:["version":1,"model":c.model,
                "source":source.indices.map { ["end":$0+1,"probability":0.2] as [String:Any] },
                "translation":target.indices.map { ["end":$0+1,"probability":0.1] as [String:Any] }])
        }
        let c=SaTReflowConfiguration()
        let response=try await SaTCaptionReflow.complete(input,configuration:c,infer:infer)
        let rows=try input.render(response,id:"readable")
        XCTAssertEqual(rows.count,2)
        XCTAssertEqual(rows.first?.source,source);XCTAssertEqual(rows.first?.translation,translation)
        XCTAssertEqual(rows.map(\.source).joined(),source+source)
        let noLink=CaptionReflowInput(source:source+source,translation:translation+translation)
        let unchanged=try await SaTCaptionReflow.complete(noLink,configuration:c,infer:infer)
        XCTAssertEqual(try noLink.render(unchanged,id:"unlinked").count,1)
    }
    @MainActor func testSaTAllFourRoutesDraftFinalAndRevision() async throws {
        for route in ["google","whisperKit","text","speech"] {
            let gate=SaTGate(),coordinator=CaptionReflowCoordinator(debounce:0,minimumInterval:0) { input,_ in try await gate.call(input) }
            var c=CaptionReflowConfiguration();c.enabled=true
            let pipeline:Pipeline = ["google","whisperKit"].contains(route) ? .transcribe:.translate
            var transcript=Transcript(),parser=BailianProtocol()
            let first="Sleep affects the brain and the formation of memories. ",second="The next topic is how treatments might improve the quality of sleep."
            func apply(_ update:TextUpdate) {
                _=transcript.apply(update,epoch:1,pipeline:pipeline)
                coordinator.update(transcript.captionParagraphs(epoch:1),configuration:c,context:"route-\(route):1:\(pipeline.rawValue)")
                XCTAssertEqual(coordinator.rows.map(\.source).joined(),transcript.captionParagraphs(epoch:1).map(\.source).joined())
                XCTAssertEqual(coordinator.rows.map(\.translation).joined(),transcript.captionParagraphs(epoch:1).map(\.translation).joined())
                XCTAssertEqual(Set(coordinator.rows.map(\.id)).count,coordinator.rows.count)
            }
            func cloud(_ object:[String:Any]) throws {
                for case .text(let update) in try parser.events(from:JSONSerialization.data(withJSONObject:object)) { apply(update) }
            }
            if route == "google" {
                for case .text(let u) in try GoogleProtocol.events(from:JSONSerialization.data(withJSONObject:["serverContent":["interimInputTranscription":["text":"Wrong draft "+first]]]),pipeline:.transcribe) { apply(u) }
            } else if route == "whisperKit" {
                apply(TextUpdate(track:"source",text:"Wrong draft "+first,replace:true,finality:.interim,providerID:"whisper-0"))
            } else {
                try cloud(["type":"input_audio_buffer.speech_started","item_id":"s0","audio_start_ms":0])
                try cloud(["type":"conversation.item.created","previous_item_id":"s0","item":["id":"t0","content":[]]])
                try cloud(["type":"conversation.item.input_audio_transcription.delta","item_id":"s0","delta":"Wrong draft "+first])
                try cloud(["type":route == "speech" ? "response.audio_transcript.delta":"response.text.delta","item_id":"t0","response_id":"r0","delta":"临时中文，之后会被修订。"])
            }
            try await Task.sleep(nanoseconds:10_000_000)
            XCTAssertEqual(await gate.count(),0);XCTAssertEqual(coordinator.rows.count,1)
            if route == "google" {
                for case .text(let u) in try GoogleProtocol.events(from:JSONSerialization.data(withJSONObject:["serverContent":["inputTranscription":["text":first+second]]]),pipeline:.transcribe) { apply(u) }
            } else if route == "whisperKit" {
                apply(TextUpdate(track:"source",text:first+second,replace:true,finality:.final,boundary:true,providerID:"whisper-0"))
            } else {
                try cloud(["type":"conversation.item.input_audio_transcription.completed","item_id":"s0","transcript":first])
                try await Task.sleep(nanoseconds:5_000_000);XCTAssertEqual(await gate.count(),0)
                try cloud(["type":route == "speech" ? "response.audio_transcript.done":"response.text.done","item_id":"t0","response_id":"r0","transcript":"第一部分解释睡眠与记忆。","text":"第一部分解释睡眠与记忆。"])
                try cloud(["type":"input_audio_buffer.speech_started","item_id":"s1","audio_start_ms":10000])
                try cloud(["type":"conversation.item.created","previous_item_id":"s1","item":["id":"t1","content":[]]])
                try cloud(["type":"conversation.item.input_audio_transcription.completed","item_id":"s1","transcript":second])
                try cloud(["type":route == "speech" ? "response.audio_transcript.done":"response.text.done","item_id":"t1","response_id":"r1","transcript":"下一部分讨论改善睡眠的治疗方法。","text":"下一部分讨论改善睡眠的治疗方法。"])
                try cloud(["type":"response.done","response":["id":"r1","status":"completed"]])
                try cloud(["type":"response.done","response":["id":"r0","status":"completed"]])
            }
            try await satWait { await gate.count()>0 }
            // An interim append while inference is running must remain visible and must not cancel it.
            apply(TextUpdate(track:"source",text:"New draft stays visible.",replace:true,finality:.interim,providerID:"tail"))
            await gate.resolve(0)
            try await satWait { !coordinator.pending }
            XCTAssertGreaterThan(coordinator.rows.count,1)
            XCTAssertFalse(coordinator.rows.map(\.source).joined().contains("Wrong draft"))
            let fixedID=coordinator.rows.first?.id
            apply(TextUpdate(track:"source",text:"New draft corrected.",replace:true,finality:.interim,providerID:"tail"))
            XCTAssertEqual(coordinator.rows.first?.id,fixedID)
            // Correct a final provider segment. Only affected text can be invalidated.
            if route == "whisperKit" {
                apply(TextUpdate(track:"source",text:"Corrected final. "+first+second,replace:true,finality:.final,boundary:true,providerID:"whisper-0"))
                try await satWait { await gate.count()>1 };await gate.resolve(1)
                try await satWait { !coordinator.pending }
                XCTAssertTrue(coordinator.rows.map(\.source).joined().hasPrefix("Corrected final."))
            }
            coordinator.reset()
        }
    }
    @MainActor func testSaTStaleEpochAndFailureRetainAllText() async throws {
        let gate=SaTGate(),coordinator=CaptionReflowCoordinator(debounce:0,minimumInterval:0) { input,_ in try await gate.call(input) }
        var c=CaptionReflowConfiguration();c.enabled=true
        let old=[CaptionParagraph(id:"old",source:"Old final caption with enough words to divide into blocks.",translation:"",isFinal:true,singleTrack:true)]
        coordinator.update(old,configuration:c,context:"old:1:transcribe")
        try await satWait { await gate.count()==1 }
        let fresh=[CaptionParagraph(id:"new",source:"New session draft.",translation:"",singleTrack:true)]
        coordinator.update(fresh,configuration:c,context:"new:2:transcribe");await gate.resolve(0)
        try await Task.sleep(nanoseconds:10_000_000)
        XCTAssertEqual(coordinator.rows.map(\.source).joined(),"New session draft.")
        let failure=CaptionReflowCoordinator(debounce:0,minimumInterval:0) { _,_ in throw CaptionError.message("Local model missing") }
        failure.update(old,configuration:c,context:"failure:1:transcribe")
        try await satWait { !failure.pending }
        XCTAssertEqual(failure.rows.map(\.source).joined(),old[0].source)
        coordinator.reset();failure.reset()
    }
    @MainActor func testSaTAuditFailureInvalidConfigurationAndDisabled() async throws {
        let gate=SaTGate(),coordinator=CaptionReflowCoordinator(debounce:0,minimumInterval:0) { input,_ in try await gate.call(input) }
        var c=CaptionReflowConfiguration();c.enabled=true
        let rows=[CaptionParagraph(id:"source",source:"The complete original must remain visible even when local setup or audit fails.",translation:"",isFinal:true,singleTrack:true)]
        var invalid=c;invalid.sat.pythonExecutable=""
        coordinator.update(rows,configuration:invalid,context:"same-context")
        XCTAssertEqual(coordinator.rows.map(\.source).joined(),rows[0].source)
        XCTAssertFalse(coordinator.pending);XCTAssertEqual(await gate.count(),0)
        coordinator.onTrace = { _ in throw CaptionError.message("Audit unavailable") }
        coordinator.update(rows,configuration:c,context:"same-context")
        try await satWait { !coordinator.pending }
        XCTAssertEqual(await gate.count(),0)
        XCTAssertEqual(coordinator.rows.map(\.source).joined(),rows[0].source)
        XCTAssertTrue(coordinator.status.contains("完整文字已保留"))
        coordinator.onTrace=nil
        for _ in 0..<2 {
            c.enabled=false
            coordinator.update(rows,configuration:c,context:"same-context")
            XCTAssertEqual(coordinator.rows.map(\.source).joined(),rows[0].source)
            XCTAssertFalse(coordinator.pending)
        }
        coordinator.reset()
    }
    func testSaTRealLocalRuntimeWhenRequested() async throws {
        guard let python=ProcessInfo.processInfo.environment["LIVECAPTION_SAT_TEST_PYTHON"] else { return }
        var c=SaTReflowConfiguration();c.pythonExecutable=python;c.minimumCharacters=20
        let texts=["Sleep supports memory. Next we discuss treatments. ","睡眠影响记忆。接下来讨论治疗方法。", "Unicode café e\u{301} 👩🏽‍🏫. A second topic follows."]
        for text in texts {
            let input=CaptionReflowInput(source:text,translation:"")
            let response=try await SaTCaptionReflow.complete(input,configuration:c)
            XCTAssertEqual(try input.render(response,id:"actual-sat").map(\.source).joined(),text)
        }
    }
    @MainActor private func satWait(_ condition:() async -> Bool) async throws {
        let start=Date()
        while !(await condition()) && Date().timeIntervalSince(start)<5 { try await Task.sleep(nanoseconds:2_000_000) }
        let passed=await condition();XCTAssertTrue(passed)
    }
}


extension PipelineChecks {
    func testSaTOnlyMigrationDropsCloudConfiguration() throws {
        for engine in ["jev","chat","unknown"] {
            let data=Data("{\"captionReflow\":{\"enabled\":true,\"engine\":\"\(engine)\",\"apiKey\":\"unused-secret\",\"baseURL\":\"https://unused.invalid\",\"jev\":{\"apiKey\":\"unused-jev-secret\"},\"sat\":{\"model\":\"sat-3l\",\"pythonExecutable\":\"/usr/bin/python3\",\"paragraphThreshold\":0.75,\"minimumCharacters\":180,\"timeoutSeconds\":120}}}".utf8)
            let config=try Configuration.decode(data)
            XCTAssertEqual(config.captionReflow.engine,.sat);XCTAssertTrue(config.captionReflow.enabled)
            XCTAssertEqual(config.captionReflow.sat.minimumCharacters,180)
            let encoded=String(decoding:try JSONEncoder().encode(config.captionReflow),as:UTF8.self)
            XCTAssertFalse(encoded.contains("apiKey"));XCTAssertFalse(encoded.contains("baseURL"));XCTAssertFalse(encoded.contains("unused"))
            XCTAssertFalse(encoded.contains("jev"));XCTAssertFalse(encoded.contains("chat"))
        }
    }
    @MainActor func testSaTOffPreservesVADGroupsAndCancelsWork() async throws {
        var config=CaptionReflowConfiguration();config.enabled=false
        config.sat.pythonExecutable="" // Off never validates or starts local inference.
        let gate=SaTGate(),coordinator=CaptionReflowCoordinator(debounce:0) { input,_ in try await gate.call(input) }
        var parser=BailianProtocol(),transcript=Transcript()
        func event(_ fields:[String:Any]) throws {
            for event in try parser.events(from:JSONSerialization.data(withJSONObject:fields)) {
                if case .text(let update)=event { _=transcript.apply(update,epoch:1,pipeline:.translate) }
            }
            coordinator.update(transcript.captionParagraphs(epoch:1),configuration:config,context:"vad:1:translate")
            XCTAssertEqual(coordinator.rows,transcript.captionParagraphs(epoch:1))
        }
        for n in 1...3 {
            try event(["type":"input_audio_buffer.speech_started","item_id":"vad-\(n)","audio_start_ms":n*2000])
            try event(["type":"input_audio_buffer.speech_stopped","item_id":"vad-\(n)","audio_end_ms":n*2000+1500])
            try event(["type":"conversation.item.input_audio_transcription.completed","item_id":"vad-\(n)","transcript":"VAD group \(n). Two sentences remain in one server group."])
            try event(["type":"conversation.item.created","previous_item_id":"vad-\(n)","item":["id":"target-\(n)"]])
        }
        for n in [3,1,2] {
            try event(["type":"response.done","response":["id":"response-\(n)","status":"completed","output":[["id":"target-\(n)","content":[["text":"第\(n)段。两句话仍在同一个服务语段里。"]]]]]])
        }
        XCTAssertEqual(coordinator.rows.count,3)
        XCTAssertEqual(coordinator.rows.map(\.id),(1...3).map { "1:source:vad-\($0)" })
        XCTAssertEqual(coordinator.rows.map(\.translation),(1...3).map { "第\($0)段。两句话仍在同一个服务语段里。" })
        let providerRows=coordinator.rows
        XCTAssertEqual(await gate.count(),0);XCTAssertFalse(coordinator.pending)

        config.sat=SaTReflowConfiguration();config.enabled=true
        coordinator.update(providerRows,configuration:config,context:"vad:1:translate")
        try await satWait { await gate.count()==1 }
        config.enabled=false;coordinator.update(providerRows,configuration:config,context:"vad:1:translate")
        await gate.resolve(0);await coordinator.finish()
        XCTAssertEqual(coordinator.rows,providerRows);XCTAssertFalse(coordinator.pending)
        XCTAssertEqual(await gate.count(),1)
        let delayedGate=SaTGate(),delayed=CaptionReflowCoordinator(debounce:0.05) { input,_ in try await delayedGate.call(input) }
        config.enabled=true;delayed.update(providerRows,configuration:config,context:"scheduled")
        config.enabled=false;delayed.update(providerRows,configuration:config,context:"scheduled")
        try await Task.sleep(nanoseconds:80_000_000)
        XCTAssertEqual(await delayedGate.count(),0);XCTAssertEqual(delayed.rows,providerRows)
    }
}
