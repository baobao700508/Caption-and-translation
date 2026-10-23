import Foundation
import LiveCaptionCore

extension PipelineChecks {
    func testReflowLosslessAndRejectedPlans() throws {
        let s="Dr. Smith paid $3.14. 👩🏽‍💻 Cafe\u{301}\r\nNext sentence. "
        let t="史密斯博士付了 3.14 美元。👩🏽‍💻\r\n下一句。"
        let input=CaptionReflowInput(source:s,translation:t)
        let rows=try input.render("```json\n{\"groups\":[[1,1],[\(input.source.count),\(input.translation.count)]]}\n```",id:"test")
        XCTAssertEqual(Array(rows.map(\.source).joined().utf8),Array(s.utf8))
        XCTAssertEqual(Array(rows.map(\.translation).joined().utf8),Array(t.utf8))
        for text in ["{\"groups\":[[1,1]]}","{\"groups\":[[1,1],[1,2]]}","{\"groups\":[[-1,1]]}","{\"groups\":[[999999,999999]]}","{\"groups\":[[1,1,1]]}","{\"source\":\"modified words\"}"] {
            var rejected=false; do { _=try input.render(text,id:"bad") } catch { rejected=true }; XCTAssertTrue(rejected)
        }
        let mono=CaptionReflowInput(source:s,translation:"")
        XCTAssertEqual(try mono.render("{\"groups\":[[\(mono.source.count),0]]}",id:"mono").map(\.source).joined(),s)
    }
    func testReflowWaitsForBothFinalTracks() {
        var t=Transcript()
        _=t.apply(TextUpdate(track:"source",text:"Ready.",replace:true,finality:.final,boundary:true,providerID:"s"),epoch:1,pipeline:.translate)
        _=t.apply(TextUpdate(track:"translation",text:"就绪。",replace:true,finality:.interim,providerID:"t",sourceProviderID:"s"),epoch:1,pipeline:.translate)
        XCTAssertFalse(t.captionParagraphs(epoch:1)[0].isFinal)
        _=t.apply(TextUpdate(track:"translation",text:"就绪。",replace:true,finality:.final,boundary:true,providerID:"t",sourceProviderID:"s"),epoch:1,pipeline:.translate)
        XCTAssertTrue(t.captionParagraphs(epoch:1)[0].isFinal)
        _=t.apply(TextUpdate(track:"source",text:"Only transcription.",replace:true,finality:.final,boundary:true,providerID:"s"),epoch:2,pipeline:.transcribe)
        XCTAssertTrue(t.captionParagraphs(epoch:2)[0].isFinal)
    }
}
