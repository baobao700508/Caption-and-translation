import Foundation
import LiveCaptionCore

extension PipelineChecks {
    func testFinalOnlyTranslationRetainsSourceLink() throws {
        var parser=BailianProtocol(),transcript=Transcript()
        let objects:[[String:Any]] = [
            ["type":"input_audio_buffer.speech_started","item_id":"s1","audio_start_ms":0],
            ["type":"conversation.item.created","previous_item_id":"s1","item":["id":"t1","content":[["type":"text"]]]],
            ["type":"conversation.item.input_audio_transcription.completed","item_id":"s1","transcript":"Final source."],
            ["type":"response.done","response":["id":"r1","status":"completed","output":[["id":"t1","content":[["type":"text","text":"最终译文。"]]]]]]
        ]
        for object in objects {
            for case .text(let update) in try parser.events(from:JSONSerialization.data(withJSONObject:object)) {
                _=transcript.apply(update,epoch:1,pipeline:.translate)
            }
        }
        XCTAssertEqual(transcript.captionParagraphs(epoch:1).count,1)
        XCTAssertEqual(transcript.captionParagraphs(epoch:1).first?.translation,"最终译文。")
    }
    func testCaptionParagraphsPairByIdentityAndKeepRevisions() {
        var transcript=Transcript()
        _=transcript.apply(TextUpdate(track:"source",text:"First paragraph.",replace:true,providerID:"s1"),epoch:1,pipeline:.translate)
        _=transcript.apply(TextUpdate(track:"source",text:"Second paragraph.",replace:true,providerID:"s2"),epoch:1,pipeline:.translate)
        // Translation of the second paragraph arrives first; it must not be paired with the first.
        _=transcript.apply(TextUpdate(track:"translation",text:"第二段。",replace:true,providerID:"t2",sourceProviderID:"s2"),epoch:1,pipeline:.translate)
        _=transcript.apply(TextUpdate(track:"translation",text:"第一",replace:true,providerID:"t1",sourceProviderID:"s1"),epoch:1,pipeline:.translate)
        let firstID=transcript.captionParagraphs(epoch:1)[0].id
        _=transcript.apply(TextUpdate(track:"translation",text:"第一段，已修订。",replace:true,finality:.final,boundary:true,providerID:"t1"),epoch:1,pipeline:.translate)
        let rows=transcript.captionParagraphs(epoch:1)
        XCTAssertEqual(rows.count,2)
        XCTAssertEqual(rows[0].id,firstID)
        XCTAssertEqual(rows[0].source,"First paragraph.")
        XCTAssertEqual(rows[0].translation,"第一段，已修订。")
        XCTAssertEqual(rows[1].translation,"第二段。")
        _=transcript.apply(TextUpdate(track:"source",text:"New connection.",replace:true,providerID:"s1"),epoch:2,pipeline:.translate)
        XCTAssertEqual(transcript.captionParagraphs(epoch:2).count,1)
        XCTAssertEqual(transcript.captionParagraphs(epoch:2)[0].translation,"")
    }
    func testCaptionLateSourceAndUnlinkedTranslation() {
        var transcript=Transcript()
        _=transcript.apply(TextUpdate(track:"translation",text:"迟到原文的译文。",replace:true,providerID:"t1",sourceProviderID:"s1"),epoch:1,pipeline:.translate)
        let rowID=transcript.captionParagraphs(epoch:1)[0].id
        _=transcript.apply(TextUpdate(track:"source",text:"Late source.",replace:true,providerID:"s1"),epoch:1,pipeline:.translate)
        _=transcript.apply(TextUpdate(track:"translation",text:"无关联译文。",replace:true,providerID:"unknown"),epoch:1,pipeline:.translate)
        let rows=transcript.captionParagraphs(epoch:1)
        XCTAssertEqual(rows.count,2)
        XCTAssertEqual(rows[0].id,rowID)
        XCTAssertEqual(rows[0].source,"Late source.")
        XCTAssertEqual(rows[1].source,"")
        XCTAssertTrue(rows[1].unlinkedTranslation)
        // Presentation does not truncate the full transcript used by logs.
        XCTAssertEqual(transcript.segments.count,3)
    }
}
