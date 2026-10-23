import Foundation
import CryptoKit

/// Human-readable projection. Operational metadata remains in session.json/events.jsonl.
public enum SessionMarkdown {
    public static let bodyMarker = "<!-- transcript -->\n\n"
    public static func hash(_ body:String) -> String {
        SHA256.hash(data:Data(body.utf8)).map { String(format:"%02x",$0) }.joined()
    }
    public static func shortTime(_ date:Date) -> String {
        String(SessionLog.timestamp(date).dropFirst(11).prefix(8))
    }
    public static func entry(time:Date,track:String,finality:TextFinality,text:String) -> String {
        guard !text.isEmpty else { return "" }
        let state = finality == .interim ? "（识别中）" : (finality == .unconfirmed ? "（未确认）" : "")
        return "[\(shortTime(time))] \(track == "source" ? "原文" : "译文")\(state)：\(text)\n\n"
    }
    public static func document(body:String,info:String,title:String="会话记录",summary:String?=nil) -> String {
        "# \(title)\n\n" + (summary.map { "摘要：\($0)\n\n" } ?? "") + info + "\n\n" + bodyMarker + body
    }
    public static func body(in markdown:String) -> String {
        if let range=markdown.range(of:bodyMarker) { return String(markdown[range.upperBound...]) }
        // Migrate only the known historical projection; never rewrite the journal or spoken text.
        let lines=markdown.components(separatedBy:"\n")
        guard let start=lines.firstIndex(where: { $0.range(of:"^(?:> )?\\[\\d{4}-\\d{2}-\\d{2}T",options:.regularExpression) != nil }) else { return "" }
        var result=Array(lines[start...]).joined(separator:"\n")
        let pattern="(?m)^\\[\\d{4}-\\d{2}-\\d{2}T(\\d{2}:\\d{2}:\\d{2})[^\\]]*\\] (原文|译文) · ([^\\n]+)\\n\\n"
        let regex=try! NSRegularExpression(pattern:pattern)
        for match in regex.matches(in:result,range:NSRange(result.startIndex...,in:result)).reversed() {
            guard let full=Range(match.range,in:result),let time=Range(match.range(at:1),in:result),let track=Range(match.range(at:2),in:result),let status=Range(match.range(at:3),in:result) else { continue }
            let state=result[status].contains("未确认") ? "（未确认）" : (result[status].contains("识别中") ? "（识别中）" : "")
            let label="[\(result[time])] \(result[track])\(state)："
            result.replaceSubrange(full,with:label)
        }
        return result
    }
}
