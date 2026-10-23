import Foundation
import Darwin

public enum LogRecovery {
    /// Replay a stopped writer's complete journal lines. A living owner must never be repaired.
    @discardableResult public static func recoverIfNeeded(root: URL) throws -> Bool {
        let latest = root.appendingPathComponent("latest.json")
        guard FileManager.default.fileExists(atPath: latest.path) else { return false }
        guard var index = try JSONSerialization.jsonObject(with: Data(contentsOf: latest)) as? [String: Any],
              index["active"] as? Bool == true, let relative = index["session_path"] as? String,
              let sessionID = index["session_id"] as? String else { return false }
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let directory = root.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
        guard directory.path.hasPrefix(canonicalRoot.path+"/") else { throw CaptionError.message("日志索引路径超出所选目录") }
        let metaURL = directory.appendingPathComponent("session.json")
        var meta = (try JSONSerialization.jsonObject(with: Data(contentsOf: metaURL))) as? [String: Any] ?? [:]
        if let pid = meta["owner_pid"] as? Int, pid > 0, kill(pid_t(pid),0) == 0 { throw CaptionError.message("该日志目录仍有活动记录进程，请先停止它或选择其他目录") }
        let eventsURL = directory.appendingPathComponent("events.jsonl")
        let data = try Data(contentsOf: eventsURL)
        let end = data.lastIndex(of: 10).map { $0+1 } ?? 0
        let complete = data.prefix(end)
        var order: [String] = [], segments: [String: [String: Any]] = [:]
        var lastSequence = 0
        for line in complete.split(separator: 10) {
            guard let row = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], row["session_id"] as? String == sessionID,
                  let sequence = row["sequence"] as? Int, sequence > lastSequence else { throw CaptionError.message("日志事件序号或会话归属异常，保留原文件供检查") }
            lastSequence = sequence
            guard let id = row["segment_id"] as? String else { continue }
            if let text = row["text"] as? String {
                if segments[id] == nil { order.append(id) }
                var segment = row
                if row["event_type"] as? String == "text.append" { segment["text"] = (segments[id]?["text"] as? String ?? "")+text }
                segments[id] = segment
            } else if row["event_type"] as? String == "segment.closed", let finality = row["finality"] { segments[id]?["finality"] = finality }
        }
        if end < data.count {
            let fragment = directory.appendingPathComponent("events.partial-fragment.txt")
            if !FileManager.default.fileExists(atPath: fragment.path) { try data.suffix(from: end).write(to: fragment, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600],ofItemAtPath:fragment.path) }
            let file = try FileHandle(forWritingTo: eventsURL); try file.truncate(atOffset: UInt64(end)); try file.close()
        }
        let now = SessionLog.timestamp()
        let recovery: [String: Any] = ["schema_version":1,"session_id":sessionID,"sequence":lastSequence+1,"connection_epoch":meta["connection_count"] as Any? ?? 0,
            "event_type":"session.recovered","received_at":now,"tail_incomplete":true,"message":"应用曾异常中止；末段可能不完整，按完整事件行恢复"]
        var row = try JSONSerialization.data(withJSONObject:recovery,options:.sortedKeys); row.append(10)
        let file = try FileHandle(forWritingTo:eventsURL); try file.seekToEnd(); try file.write(contentsOf:row); try file.synchronize(); try file.close()
        let info = "恢复于 \(now) · 已结束 · 记录 ID：\(sessionID)\n> 应用曾异常中止，末段可能不完整。时间为本机收字时间（UTC）。\n<!-- snapshot_sequence: \(lastSequence+1) -->"
        let body = order.compactMap { id -> String? in
            guard let s = segments[id], let text = s["text"] as? String else { return nil }
            let finality = s["finality"] as? String == "final" ? TextFinality.final : .unconfirmed
            let formatter=ISO8601DateFormatter();formatter.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
            let time=(s["received_at"] as? String).flatMap { formatter.date(from:$0) } ?? Date()
            return SessionMarkdown.entry(time:time,track:s["track"] as? String ?? "source",finality:finality,text:text)
        }.joined()
        try Data(SessionMarkdown.document(body:body,info:info).utf8).write(to:directory.appendingPathComponent("transcript.md"),options:.atomic)
        try Data(SessionMarkdown.document(body:String(body.suffix(12000)),info:info+"\n恢复预览；完整记录见 transcript.md。").utf8).write(to:directory.appendingPathComponent("live.md"),options:.atomic)
        for key in ["active","state","updated_at","written_sequence","snapshot_sequence"] {
            let value: Any
            switch key { case "active":value=false;case "state":value="recovered_after_crash";case "updated_at":value=now;default:value=lastSequence+1 }
            meta[key]=value;index[key]=value
        }
        meta["tail_incomplete"]=true
        try JSONSerialization.data(withJSONObject:meta,options:[.prettyPrinted,.sortedKeys]).write(to:metaURL,options:.atomic)
        try JSONSerialization.data(withJSONObject:index,options:[.prettyPrinted,.sortedKeys]).write(to:latest,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:latest.path)
        for name in ["transcript.md","live.md","session.json"] { try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:directory.appendingPathComponent(name).path) }
        return true
    }
}
