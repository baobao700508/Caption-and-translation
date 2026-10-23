import Foundation
import LiveCaptionCore

extension PipelineChecks {
    func testCatchUpHysteresisBoundsAndReset() throws {
        var control=PlaybackCatchUpController()
        _=control.update(queuedSeconds:1.6,elapsedSeconds:0.1)
        XCTAssertTrue(control.catchingUp);XCTAssertGreaterThan(control.rate,1)
        _=control.update(queuedSeconds:1.0,elapsedSeconds:0.1)
        XCTAssertTrue(control.catchingUp)
        _=control.update(queuedSeconds:0.7,elapsedSeconds:0.1)
        XCTAssertFalse(control.catchingUp)
        for _ in 0..<100 { _=control.update(queuedSeconds:60,elapsedSeconds:0.1) }
        XCTAssertEqual(control.rate,1.5)
        _=control.update(queuedSeconds:0,elapsedSeconds:0.1)
        XCTAssertEqual(control.rate,1);XCTAssertFalse(control.catchingUp)
        _=control.update(queuedSeconds:10,elapsedSeconds:.nan)
        XCTAssertTrue(control.rate.isFinite);XCTAssertEqual(control.rate,1)
        control.reset();XCTAssertEqual(control.rate,1)
        var disabled=PlaybackCatchUpConfiguration();disabled.enabled=false
        control=PlaybackCatchUpController(configuration:disabled)
        XCTAssertEqual(control.update(queuedSeconds:60,elapsedSeconds:1),1)
    }
    func testCatchUpSustainedTranslationSurplusDoesNotGrowUnbounded() {
        var control=PlaybackCatchUpController(),queued=0.0,arrived=0.0,played=0.0
        var firstEnd=0.0,lastEnd=0.0
        for tick in 0..<9000 {
            queued+=0.12;arrived+=0.12 // 1.2 seconds of translation per wall-clock second.
            let speed=control.update(queuedSeconds:queued,elapsedSeconds:0.1)
            let consumed=min(queued,0.1*speed);queued-=consumed;played+=consumed
            XCTAssertTrue(speed>=1 && speed<=1.5)
            if tick==2999 { firstEnd=queued }
            if tick==8999 { lastEnd=queued }
        }
        XCTAssertLessThan(queued,6);XCTAssertLessThan(abs(lastEnd-firstEnd),0.1)
        XCTAssertLessThan(abs(arrived-played-queued),0.00001)
        // A natural pause drains everything; no audio is skipped to catch up.
        for _ in 0..<300 { let speed=control.update(queuedSeconds:queued,elapsedSeconds:0.1);let n=min(queued,0.1*speed);queued-=n;played+=n }
        XCTAssertEqual(queued,0);XCTAssertLessThan(abs(arrived-played),0.00001)
    }
    func testTransportAndPartialCatchUpConfiguration() throws {
        let c=try Configuration.decode(Data(#"{"translateProvider":"bailian","bailianTransport":"websocket","playbackCatchUp":{"maximumRate":1.3}}"#.utf8))
        XCTAssertEqual(c.bailianTransport,.websocket);XCTAssertEqual(c.playbackCatchUp.maximumRate,1.3)
        XCTAssertEqual(c.playbackCatchUp.enterSeconds,1.5)
        XCTAssertTrue(c.bailianTransport.make() is WebSocketTransport)
        XCTAssertTrue(BailianTransport.webrtc.make() is BailianWebRTCTransport)
        let legacy=try Configuration.decode(Data(#"{"apiKey":"legacy"}"#.utf8))
        XCTAssertEqual(legacy.bailianTransport,.webrtc)
        var bad=c.playbackCatchUp;bad.maximumRate=3
        var rejected=false;do {try bad.validate()}catch{rejected=true};XCTAssertTrue(rejected)
        bad=c.playbackCatchUp;bad.enterSeconds=bad.exitSeconds
        rejected=false;do {try bad.validate()}catch{rejected=true};XCTAssertTrue(rejected)
    }
}
