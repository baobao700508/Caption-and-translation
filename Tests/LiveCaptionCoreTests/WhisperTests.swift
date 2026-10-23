import Foundation
@testable import LiveCaptionCore
import WhisperKit

extension PipelineChecks {
    func testWhisperDoesNotFreezeHalfAPhraseAtAModelSegment() throws {
        let unsafe=[TranscriptionSegment(end:10.6,text:"arrival of the young"),
                    TranscriptionSegment(start:10.6,end:14,text:" princess. The French, in return, invited")]
        XCTAssertNil(WhisperRollingCut.choose(segments:unsafe,duration:14.4))
        let safe=[TranscriptionSegment(end:11.12,text:"arrival of the young princess."),
                  TranscriptionSegment(start:11.12,end:14,text:" The French, in return, invited")]
        let cut=WhisperRollingCut.choose(segments:safe,duration:14.4)
        XCTAssertEqual(cut?.prefix,"arrival of the young princess.")
        XCTAssertEqual(cut?.suffix," The French, in return, invited")
    }
    func testWhisperRoutingDoesNotRequireCloudKeyOrRotate() throws {
        var config=Configuration();config.apiKey="";config.bailianAPIKey=""
        config.transcribeProvider = .whisperKit
        try config.validate()
        XCTAssertEqual(config.provider,.whisperKit)
        XCTAssertEqual(config.activeAPIKey,"")
        XCTAssertEqual(config.safeMetadata["provider_region"] as? String,"local")
        XCTAssertNil(config.scheduledConnectionRotationSeconds)
        config.pipeline = .translate
        XCTAssertEqual(config.provider,.bailian)
        config.pipeline = .transcribe;config.transcribeProvider = .google
        var rejectsMissingKey=false
        do { try config.validate() } catch { rejectsMissingKey=true }
        XCTAssertTrue(rejectsMissingKey)
        let legacy=try Configuration.decode(Data(#"{"apiKey":"test-google","transcribeModel":"original-model"}"#.utf8))
        XCTAssertEqual(legacy.transcribeProvider,.google)
        XCTAssertEqual(legacy.model,"original-model")
    }
    func testWhisperConfigurationRoundTripAndInvalidMode() throws {
        var config=Configuration();config.transcribeProvider = .whisperKit
        config.localWhisper.language="zh";config.localWhisper.updateIntervalSeconds=1
        let partial=try Configuration.decode(Data(#"{"transcribeProvider":"whisperKit","localWhisper":{"language":"zh"}}"#.utf8))
        try partial.validate()
        XCTAssertEqual(partial.localWhisper.language,"zh")
        XCTAssertEqual(partial.localWhisper.model,LocalWhisperConfiguration().model)
        let restored=try Configuration.decode(JSONEncoder().encode(config))
        XCTAssertEqual(restored.transcribeProvider,.whisperKit)
        XCTAssertEqual(restored.localWhisper.language,"zh")
        config.translateProvider = .whisperKit
        var rejected=false
        do { try config.validate() } catch { rejected=true }
        XCTAssertTrue(rejected)
    }
}
