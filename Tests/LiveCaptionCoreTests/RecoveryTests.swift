import Foundation
import LiveCaptionCore

private actor GoogleFlushTransport: RealtimeTransport {
    private var queue:[Data]=[]
    private var waiter:CheckedContinuation<Data,Error>?
    private var ended=false
    let finalOnEnd:Bool
    let finalDelay:UInt64
    let automaticInterim:Bool
    init(finalOnEnd:Bool=true,finalDelay:UInt64=0,automaticInterim:Bool=true) { self.finalOnEnd=finalOnEnd;self.finalDelay=finalDelay;self.automaticInterim=automaticInterim }
    func deliver(_ text:String) { push(text) }
    private func push(_ text:String) {
        let data=Data(text.utf8)
        if let waiter { self.waiter=nil;waiter.resume(returning:data) } else { queue.append(data) }
    }
    func open(_ request:URLRequest) async throws {}
    func send(_ data:Data) async throws {
        let root=try JSONSerialization.jsonObject(with:data) as! [String:Any]
        if root["setup"] != nil { push(#"{"setupComplete":{}}"#) }
        if let input=root["realtimeInput"] as? [String:Any] {
            if input["audio"] != nil && automaticInterim { push(#"{"serverContent":{"interimInputTranscription":{"text":"The final words"}}}"#) }
            if input["audioStreamEnd"] as? Bool == true {
                ended=true
                if finalOnEnd {
                    Task { try? await Task.sleep(nanoseconds:finalDelay);push(#"{"serverContent":{"inputTranscription":{"text":"The final words are preserved."}}}"#) }
                }
            }
        }
    }
    func receive() async throws -> Data {
        if !queue.isEmpty { return queue.removeFirst() }
        return try await withCheckedThrowingContinuation { waiter=$0 }
    }
    func close() async { waiter?.resume(throwing:CancellationError());waiter=nil }
    func endWasSent()->Bool { ended }
}
private actor GoogleFlushEvents {
    var final=false
    var interim=false
    var failed=false
    var basis:String?
    func receive(_ event:ProviderEvent) {
        if case .text(let text)=event { if text.finality == .final { final=true };if text.finality == .interim { interim=true } }
        if case .diagnostic("provider.google_input_finalized",let fields)=event { basis=fields["basis"] as? String }
        if case .error = event { failed=true }
    }
}
extension PipelineChecks {
    func testGoogleFinalBeforeTrailingSilenceDoesNotBecomeIncomplete() async throws {
        let transport=GoogleFlushTransport(finalOnEnd:false,automaticInterim:false),events=GoogleFlushEvents()
        var config=Configuration();config.apiKey="offline-google-key";config.pipeline = .transcribe
        let connection=GoogleConnection(configuration:config,transport:transport,finishTimeout:0.25) { await events.receive($0) }
        try await connection.connect();try await connection.sendAudio(Data(repeating:1,count:3200))
        await transport.deliver(#"{"serverContent":{"inputTranscription":{"text":"and eliminating them."}}}"#)
        for _ in 0..<100 { if await events.final { break };try await Task.sleep(nanoseconds:1_000_000) }
        let receivedFinal=await events.final;XCTAssertTrue(receivedFinal)
        // The real session sent quiet audio after this speech was already final;
        // audioStreamEnd did not produce another transcript for the silence.
        try await connection.sendAudio(Data(repeating:0,count:3200))
        let started=Date(),confirmed=await connection.finish();XCTAssertTrue(confirmed)
        XCTAssertGreaterThan(Date().timeIntervalSince(started),0.2)
        let basis=await events.basis;XCTAssertEqual(basis,"received_transcripts_final_after_drain")
        await connection.close()
    }
    func testGoogleOldFinalCannotHideLaterUnfinishedSpeech() async throws {
        let transport=GoogleFlushTransport(finalOnEnd:false,automaticInterim:false),events=GoogleFlushEvents()
        var config=Configuration();config.apiKey="offline-google-key";config.pipeline = .transcribe
        let connection=GoogleConnection(configuration:config,transport:transport,finishTimeout:0.25) { await events.receive($0) }
        try await connection.connect();try await connection.sendAudio(Data(repeating:1,count:3200))
        await transport.deliver(#"{"serverContent":{"inputTranscription":{"text":"Previous speech is final."}}}"#)
        for _ in 0..<100 { if await events.final { break };try await Task.sleep(nanoseconds:1_000_000) }
        try await connection.sendAudio(Data(repeating:2,count:3200))
        await transport.deliver(#"{"serverContent":{"interimInputTranscription":{"text":"These new words are not final"},"turnComplete":true}}"#)
        for _ in 0..<100 { if await events.interim { break };try await Task.sleep(nanoseconds:1_000_000) }
        let confirmed=await connection.finish();XCTAssertFalse(confirmed)
        await connection.close()
    }
    func testGoogleCancellationCannotConfirmOldFinal() async throws {
        let transport=GoogleFlushTransport(finalOnEnd:false,automaticInterim:false),events=GoogleFlushEvents()
        var config=Configuration();config.apiKey="offline-google-key";config.pipeline = .transcribe
        let connection=GoogleConnection(configuration:config,transport:transport,finishTimeout:1) { await events.receive($0) }
        try await connection.connect();try await connection.sendAudio(Data(repeating:1,count:3200))
        await transport.deliver(#"{"serverContent":{"inputTranscription":{"text":"Previous speech is final."}}}"#)
        for _ in 0..<100 { if await events.final { break };try await Task.sleep(nanoseconds:1_000_000) }
        try await connection.sendAudio(Data(repeating:0,count:3200))
        let finishing=Task { await connection.finish() }
        for _ in 0..<100 { if await transport.endWasSent() { break };try await Task.sleep(nanoseconds:1_000_000) }
        finishing.cancel();let confirmed=await finishing.value;XCTAssertFalse(confirmed)
        await connection.close()
    }
    func testGoogleMissingResultOrFailureCannotConfirm() async throws {
        for withOldFinal in [false,true] {
            let transport=GoogleFlushTransport(finalOnEnd:false,automaticInterim:false),events=GoogleFlushEvents()
            var config=Configuration();config.apiKey="offline-google-key";config.pipeline = .transcribe
            let connection=GoogleConnection(configuration:config,transport:transport,finishTimeout:0.25) { await events.receive($0) }
            try await connection.connect();try await connection.sendAudio(Data(repeating:1,count:3200))
            if withOldFinal {
                await transport.deliver(#"{"serverContent":{"inputTranscription":{"text":"Previous speech is final."}}}"#)
                for _ in 0..<100 { if await events.final { break };try await Task.sleep(nanoseconds:1_000_000) }
                try await connection.sendAudio(Data(repeating:0,count:3200))
                await transport.deliver(#"{"error":{"message":"simulated connection failure"}}"#)
                for _ in 0..<100 { if await events.failed { break };try await Task.sleep(nanoseconds:1_000_000) }
            }
            let confirmed=await connection.finish();XCTAssertFalse(confirmed)
            await connection.close()
        }
    }
    func testOverflowIsCountedWithoutRetainingAudio() {
        let queue=AudioPacketQueue()
        for i in 0..<55 {
            let t=Double(i)/10
            queue.append(CapturedAudio(data:Data(repeating:UInt8(i),count:3200),timing:AudioTiming(captureStartedAt:t,captureEndedAt:t+0.1,preparedAt:t+0.1)))
        }
        let lost=queue.takeOverflow()
        XCTAssertEqual(lost?.samples,56000);XCTAssertEqual(lost?.startedAt,0);XCTAssertEqual(lost?.endedAt,3.5)
        XCTAssertNil(queue.takeOverflow());XCTAssertEqual(queue.takeBatch()?.data.count,64000)
    }
    func testGoogleWaitsForDelayedFinal() async throws {
        let transport=GoogleFlushTransport(finalDelay:2_300_000_000)
        var config=Configuration();config.apiKey="offline-google-key"
        let connection=GoogleConnection(configuration:config,transport:transport,finishTimeout:4) { _ in }
        try await connection.connect();try await connection.sendAudio(Data(repeating:1,count:3200))
        let started=Date(),confirmed=await connection.finish()
        XCTAssertTrue(confirmed);XCTAssertGreaterThan(Date().timeIntervalSince(started),2.2)
        await connection.close()
    }
    func testReconnectQueueDropsOldFramesAndKeepsFuture() {
        let queue=AudioPacketQueue(limit:50)
        for i in 0..<40 {
            let t=Double(i)/10
            queue.append(CapturedAudio(data:Data(repeating:UInt8(i),count:3200),timing:AudioTiming(captureStartedAt:t,captureEndedAt:t+0.1,preparedAt:t+0.1)))
        }
        // A 3.5 second outage is deliberately discarded, not replayed after recovery.
        let dropped=queue.discard(before:3.5)
        XCTAssertEqual(dropped.reduce(0,{$0+$1.data.count/2}),56000)
        let fresh=queue.takeBatch(maxPackets:5)
        XCTAssertEqual(fresh?.timing.captureStartedAt,3.5)
        XCTAssertEqual(fresh?.data,Data((35..<40).flatMap { Array(repeating:UInt8($0),count:3200) }))
        XCTAssertNil(queue.takeBatch())
    }
    func testGoogleFlushAcceptsFinalAfterEnd() async throws {
        let transport=GoogleFlushTransport(),events=GoogleFlushEvents()
        var config=Configuration();config.apiKey="offline-google-key";config.pipeline = .transcribe
        let connection=GoogleConnection(configuration:config,transport:transport) { await events.receive($0) }
        try await connection.connect()
        try await connection.sendAudio(Data(repeating:1,count:3200))
        let confirmed=await connection.finish()
        let ended=await transport.endWasSent(),final=await events.final
        XCTAssertTrue(ended);XCTAssertTrue(final);XCTAssertTrue(confirmed)
        await connection.close()
    }
    func testGoogleFlushRejectsInterimTimeout() async throws {
        let transport=GoogleFlushTransport(finalOnEnd:false)
        var config=Configuration();config.apiKey="offline-google-key"
        let connection=GoogleConnection(configuration:config,transport:transport,finishTimeout:0.25) { _ in }
        try await connection.connect();try await connection.sendAudio(Data(repeating:1,count:3200))
        let confirmed=await connection.finish();XCTAssertFalse(confirmed)
        var rejected=false
        do { try await connection.sendAudio(Data(repeating:1,count:3200)) } catch { rejected=true }
        XCTAssertTrue(rejected);await connection.close()
    }
}
