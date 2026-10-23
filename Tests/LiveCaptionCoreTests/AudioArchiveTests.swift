import AVFoundation
import LiveCaptionCore

private actor AudioSink: ProviderConnection {
    var received = Data()
    func connect(handle: String?) async throws {}
    func sendAudio(_ data: Data) async throws {
        if data == Data([0xff,0xff]) { throw CaptionError.message("simulated send failure") }
        received.append(data)
    }
    func finish() async -> Bool { true }
    func close() async {}
    func bytes() -> Data { received }
}

extension PipelineChecks {
    func testDecodedTimelinePreservesSilenceAndCallbackTimes() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let archive=try AudioArchive(sessionDirectory:root)
        let voiced=Data([0xff,0x01,0x01,0x00]),silence=Data(repeating:0,count:480)
        try archive.probeTimeline(voiced,rate:24000,track:"decoded-output",epoch:1,callbackAt:100,callbackUptime:50)
        try archive.probeTimeline(silence,rate:24000,track:"decoded-output",epoch:1,callbackAt:100.01,callbackUptime:50.01)
        try archive.probeTimeline(voiced,rate:24000,track:"decoded-output",epoch:2,callbackAt:103,callbackUptime:53)
        try archive.finish()
        let file=try Data(contentsOf:root.appendingPathComponent("audio/probe-decoded-output.wav"))
        XCTAssertEqual(Data(file.dropFirst(44)),voiced+silence+voiced)
        let rows=try String(contentsOf:root.appendingPathComponent("audio/probe-decoded-output-index.jsonl")).split(separator:"\n").map { try JSONSerialization.jsonObject(with:Data($0.utf8)) as! [String:Any] }
        XCTAssertEqual(rows.count,3);XCTAssertEqual(rows[1]["sample_offset"] as? Int,2)
        XCTAssertEqual(rows[2]["sample_offset"] as? Int,242)
        XCTAssertEqual(rows[2]["connection_epoch"] as? Int,2)
        XCTAssertEqual(rows[2]["callback_at_unix_seconds"] as? Double,103)
        XCTAssertEqual(rows[2]["callback_uptime_seconds"] as? Double,53)
    }
    func testSenderCatchesUpAfterOnePointFiveSecondWrites() throws {
        let queue = AudioPacketQueue();var expected = Data(),received = Data();var dropped=0
        for tick in 0..<90 {
            let data = Data(repeating:UInt8(tick),count:3200);expected.append(data)
            dropped += queue.append(CapturedAudio(data:data,timing:AudioTiming(captureStartedAt:Double(tick)/10,captureEndedAt:Double(tick+1)/10,preparedAt:Double(tick+1)/10)))
            if tick % 15 == 14,let batch = queue.takeBatch() { received.append(batch.data) }
        }
        while let batch = queue.takeBatch() { received.append(batch.data) }
        print("1.5s send-completion trace: discarded packets = \(dropped)")
        XCTAssertEqual(dropped,0);XCTAssertEqual(received,expected)
    }

    func testDelayedMicrophoneCallbacksDoNotInventSilence() throws {
        var timeline = AudioTimeline()
        var cursor = 0.0; var rendered = [Float]()
        // Device delivers 100ms blocks at their END; callback timestamp marks the START.
        for tick in 1...210 {
            let now = Double(tick)/100
            if tick % 10 == 0 && tick <= 200 {
                timeline.append([Float](repeating:0.25,count:4800),at:Double(tick-10)/100,receivedAt:now)
            }
            if tick < 10 { continue }
            while cursor+0.01 <= min(2,now-0.04)+1e-9 && timeline.canRead(at:cursor,frames:480,now:now) {
                let (samples,_) = timeline.read(at:cursor,frames:480)
                rendered.append(contentsOf:samples); cursor += 0.01
            }
        }
        XCTAssertEqual(rendered.count,96000)
        let inventedSilence = rendered.filter { $0 == 0 }.count
        print("100ms microphone callbacks: invented silent samples = \(inventedSilence) / \(rendered.count)")
        XCTAssertEqual(inventedSilence,0)
        // A genuinely stalled lane eventually permits an explicit, logged gap.
        XCTAssertTrue(timeline.canRead(at:2,frames:480,now:2.4))
    }

    func testSlowSenderCoalescesWithoutWaitingOrLosingPCM() throws {
        let queue = AudioPacketQueue()
        var expected = Data(), received = Data(); var dropped = 0
        for tick in 0..<80 {
            let data = Data(repeating:UInt8(tick),count:3200)
            expected.append(data)
            dropped += queue.append(CapturedAudio(data:data,timing:AudioTiming(captureStartedAt:Double(tick)/10,captureEndedAt:Double(tick+1)/10,preparedAt:Double(tick+1)/10)))
            // A 400ms network write consumes only one send opportunity per four 100ms input packets.
            if tick % 4 == 3 {
                let packet = queue.takeBatch()!
                XCTAssertEqual(packet.data.count,12800)
                XCTAssertEqual(Float(packet.timing.captureEndedAt-packet.timing.captureStartedAt),0.4,accuracy:0.0001)
                XCTAssertEqual(Float(packet.timing.preparedAt),Float(Double(tick-2)/10),accuracy:0.0001)
                received.append(packet.data)
            }
        }
        XCTAssertEqual(dropped,0); XCTAssertEqual(received,expected)
        let fresh = CapturedAudio(data:Data([1,0]),timing:AudioTiming(captureStartedAt:8,captureEndedAt:8.1,preparedAt:8.1))
        queue.append(fresh); XCTAssertEqual(queue.takeBatch()?.data,fresh.data) // no batching timer
        XCTAssertNil(queue.takeBatch()); queue.finish()
    }

    func testArchivedConnectionExactPCMAndEpochs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let log = try SessionLog(configuration:Configuration(),rootOverride:root)
        try await log.begin()
        let sink = AudioSink()
        let old = ArchivedConnection(connection:sink,archive:log.audioArchive,epoch:1)
        let next = ArchivedConnection(connection:sink,archive:log.audioArchive,epoch:3)
        let data = Data((0..<3200).map { UInt8($0 % 251) })
        try await old.sendAudio(data)
        var rejected = false
        do { try await old.sendAudio(Data([0xff,0xff])) } catch { rejected = true }
        XCTAssertTrue(rejected)
        try await next.sendAudio(Data(data.prefix(160)))
        try log.audioArchive.input([Float](repeating:0.25,count:480),microphone:false)
        try log.audioArchive.input([Float](repeating:0.1,count:480),microphone:true)
        try await log.flush()
        let audio = log.directory.appendingPathComponent("audio")
        let wavURL = audio.appendingPathComponent("uploaded.wav")
        let beforeStop = try Data(contentsOf:wavURL)
        let sent = await sink.bytes()
        XCTAssertEqual(Data(beforeStop.dropFirst(44)),sent)
        let file = try AVAudioFile(forReading:wavURL)
        XCTAssertEqual(file.processingFormat.sampleRate,16000)
        XCTAssertEqual(file.processingFormat.channelCount,1)
        XCTAssertEqual(Int(file.length),sent.count/2)
        let rows = try String(contentsOf:audio.appendingPathComponent("upload-index.jsonl")).split(separator:"\n").map { try JSONSerialization.jsonObject(with:Data($0.utf8)) as! [String:Any] }
        XCTAssertEqual(rows.count,2)
        XCTAssertEqual(rows[0]["connection_epoch"] as? Int,1)
        XCTAssertEqual(rows[1]["connection_epoch"] as? Int,3)
        XCTAssertEqual(rows[1]["sample_offset"] as? Int,1600)
        let raw = try AVAudioFile(forReading:audio.appendingPathComponent("system-before-ns.wav"))
        XCTAssertEqual(raw.processingFormat.sampleRate,48000)
        XCTAssertEqual(Int(raw.length),480)
        try await log.finish(tailIncomplete:false)
        try log.audioArchive.finish() // idempotent
        XCTAssertEqual(try Data(contentsOf:wavURL),beforeStop)
        var lateRejected = false
        do { try log.audioArchive.sent(data,epoch:1,submittedAt:SessionLog.timestamp()) } catch { lateRejected = true }
        XCTAssertTrue(lateRejected)
        let permissions = try FileManager.default.attributesOfItem(atPath:wavURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions,0o600)
        let manifest = try JSONSerialization.jsonObject(with:Data(contentsOf:audio.appendingPathComponent("recording.json"))) as! [String:Any]
        XCTAssertEqual(manifest["finished"] as? Bool,true)
        let journal = try String(contentsOf:log.directory.appendingPathComponent("events.jsonl"))
        XCTAssertFalse(journal.contains(data.base64EncodedString()))
    }
}
