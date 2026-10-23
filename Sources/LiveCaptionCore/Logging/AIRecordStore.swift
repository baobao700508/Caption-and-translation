import Foundation

/// Synchronous invalidation prevents a disabled/reconfigured job from committing after an await.
public final class AIRecordPermission:@unchecked Sendable {
    private let lock=NSLock()
    private var enabled=false
    private var revision:UInt64=0
    public init() {}
    @discardableResult public func update(enabled:Bool) -> UInt64 {
        lock.lock();defer { lock.unlock() };self.enabled=enabled;revision &+= 1;return revision
    }
    public func require(_ token:UInt64) throws {
        lock.lock();let valid=enabled && revision == token;lock.unlock()
        guard valid,!Task.isCancelled else { throw CancellationError() }
    }
}
public struct AIRecordWork:Sendable {
    public let directory:URL
    public let sessionID:String
    public let needsModel:Bool
    public init(directory:URL,sessionID:String,needsModel:Bool) { self.directory=directory;self.sessionID=sessionID;self.needsModel=needsModel }
}
public struct AIRecordSummary:Codable,Sendable {
    public var sessionID:String
    public var relativePath:String
    public var startedAt:String
    public var title:String
    public var summary:String
    public var logHash:String
    public var generatedAt:String
    public var provider:String
    public var model:String
    public var state:String
}
public actor AIRecordStore {
    public nonisolated let permission=AIRecordPermission()
    private var inFlight:Set<String>=[]
    private let client:any AISummarizing
    public init(client:any AISummarizing=AISummaryClient()) { self.client=client }
    private func write(_ data:Data,to url:URL) throws {
        try data.write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
    private func encode<T:Encodable>(_ value:T) throws -> Data {
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes];return try encoder.encode(value)
    }
    private func registry(_ root:URL) throws -> [String:AIRecordSummary] {
        let file=root.appendingPathComponent("ai-index.json")
        guard FileManager.default.fileExists(atPath:file.path) else { return [:] }
        return try JSONDecoder().decode([String:AIRecordSummary].self,from:Data(contentsOf:file))
    }
    private func checked(_ directory:URL,root:URL) throws -> (id:String,relative:String,meta:[String:Any]) {
        let canonical=root.resolvingSymlinksInPath().standardizedFileURL
        let dir=directory.resolvingSymlinksInPath().standardizedFileURL
        guard dir.path.hasPrefix(canonical.path+"/"),dir.deletingLastPathComponent().deletingLastPathComponent() == canonical,
              directory.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL,
              (try directory.resourceValues(forKeys:[.isSymbolicLinkKey])).isSymbolicLink != true,
              let meta=try JSONSerialization.jsonObject(with:Data(contentsOf:dir.appendingPathComponent("session.json"))) as? [String:Any],
              let id=meta["session_id"] as? String,UUID(uuidString:id) != nil,dir.lastPathComponent.lowercased() == id.lowercased() else {
            throw CaptionError.message("会话目录或记录 ID 无效，未改动该记录。")
        }
        return (id,String(dir.path.dropFirst(canonical.path.count+1)),meta)
    }
    private func body(_ directory:URL) throws -> String {
        SessionMarkdown.body(in:try String(contentsOf:directory.appendingPathComponent("transcript.md"),encoding:.utf8))
    }
    private func cached(_ directory:URL,hash:String) -> AIRecordSummary? {
        guard let data=try? Data(contentsOf:directory.appendingPathComponent("ai-summary.json")),
              let value=try? JSONDecoder().decode(AIRecordSummary.self,from:data),value.logHash == hash,value.state == "complete" else { return nil }
        return value
    }
    /// Read-only: enabling or opening Settings never triggers this plan's execution.
    public func plan(root:URL) throws -> [AIRecordWork] {
        guard FileManager.default.fileExists(atPath:root.path) else { return [] }
        let index=try registry(root),files=FileManager.default
        let indexMarkdown=(try? String(contentsOf:root.appendingPathComponent("index.md"),encoding:.utf8)) ?? ""
        var work:[AIRecordWork]=[]
        for day in try files.contentsOfDirectory(at:root,includingPropertiesForKeys:[.isDirectoryKey,.isSymbolicLinkKey],options:.skipsHiddenFiles) {
            let values=try day.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
            guard values.isDirectory == true,values.isSymbolicLink != true,day.lastPathComponent.range(of:"^\\d{4}-\\d{2}-\\d{2}$",options:.regularExpression) != nil else { continue }
            for directory in try files.contentsOfDirectory(at:day,includingPropertiesForKeys:[.isDirectoryKey,.isSymbolicLinkKey],options:.skipsHiddenFiles) {
                let values=try directory.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
                guard values.isDirectory == true,values.isSymbolicLink != true,files.fileExists(atPath:directory.appendingPathComponent("session.json").path) else { continue }
                let record=try checked(directory,root:root)
                guard record.meta["active"] as? Bool == false else { continue }
                let text=try body(directory);guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { continue }
                let hash=SessionMarkdown.hash(text),saved=cached(directory,hash:hash)
                let markdown=try String(contentsOf:directory.appendingPathComponent("transcript.md"),encoding:.utf8)
                let indexed=index[record.id]
                let projectionsPresent=saved.map { markdown.hasPrefix("# "+Self.escape($0.title)+"\n") && markdown.contains("摘要："+Self.escape($0.summary)+"\n") } ?? false
                let indexPresent=indexMarkdown.contains("ID：`\(record.id)`") && indexMarkdown.contains("正文 SHA-256：`\(hash)`") && indexMarkdown.contains("(\(record.relative)/transcript.md)")
                if saved == nil || indexed?.logHash != hash || indexed?.state != "complete" || indexed?.relativePath != record.relative || !projectionsPresent || !indexPresent {
                    work.append(AIRecordWork(directory:directory,sessionID:record.id,needsModel:saved == nil))
                }
            }
        }
        return work.sorted { $0.directory.path < $1.directory.path }
    }
    public func markPending(directory:URL,root:URL,token:UInt64) throws {
        try permission.require(token)
        let record=try checked(directory,root:root)
        let entry=AIRecordSummary(sessionID:record.id,relativePath:record.relative,startedAt:record.meta["started_at"] as? String ?? "",title:"会话记录",summary:"",logHash:"",generatedAt:"",provider:"",model:"",state:record.meta["active"] as? Bool == true ? "recording" : "pending")
        try upsert(entry,root:root,token:token)
    }
    /// Cache first, then materialize Markdown and index. A failed projection retries without paying again.
    @discardableResult public func process(directory:URL,root:URL,settings:AISummarySettings,key:String,token:UInt64) async throws -> Bool {
        try permission.require(token)
        let record=try checked(directory,root:root)
        guard record.meta["active"] as? Bool == false else { throw CaptionError.message("该会话仍在记录，结束后再补生成。") }
        let flight=directory.path
        guard inFlight.insert(flight).inserted else { throw CaptionError.message("该记录正在生成，请等待完成。") }
        defer { inFlight.remove(flight) }
        let text=try body(directory),hash=SessionMarkdown.hash(text)
        guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw CaptionError.message("该记录没有文字，无需生成摘要。") }
        var result=cached(directory,hash:hash)
        let usedModel=result == nil
        try audit(root:root,event:usedModel ? "summary.started" : "summary.cached",id:record.id,hash:hash)
        do {
            if result == nil {
                let brief=try await client.summarize(text,settings:settings,key:key)
                try permission.require(token)
                guard try SessionMarkdown.hash(body(directory)) == hash else { throw CaptionError.message("生成期间正文发生变化，请重试。") }
                result=AIRecordSummary(sessionID:record.id,relativePath:record.relative,startedAt:record.meta["started_at"] as? String ?? "",title:brief.title,summary:brief.summary,logHash:hash,generatedAt:SessionLog.timestamp(),provider:settings.provider,model:settings.model,state:"complete")
                try write(encode(result!),to:directory.appendingPathComponent("ai-summary.json"))
            }
            guard var saved=result,saved.sessionID == record.id else { throw CaptionError.message("摘要归属异常，未写入索引。") }
            saved.relativePath=record.relative
            try permission.require(token)
            let state=record.meta["state"] as? String ?? ""
            let incomplete=record.meta["tail_incomplete"] as? Bool == true || state == "stopped_tail_incomplete" || state == "recovered_after_crash"
            let info="\(saved.startedAt) · 已结束 · 时间戳为本机收字时间（UTC）\n记录 ID：\(record.id)\n<!-- snapshot_sequence: \(record.meta["snapshot_sequence"] as? Int ?? 0) -->" + (incomplete ? "\n> 末段可能不完整。" : "")
            let full=SessionMarkdown.document(body:text,info:info,title:Self.escape(saved.title),summary:Self.escape(saved.summary))
            try write(Data(full.utf8),to:directory.appendingPathComponent("transcript.md"))
            let liveURL=directory.appendingPathComponent("live.md")
            if FileManager.default.fileExists(atPath:liveURL.path) {
                let recent=SessionMarkdown.body(in:try String(contentsOf:liveURL,encoding:.utf8))
                try permission.require(token)
                try write(Data(SessionMarkdown.document(body:recent,info:info+"\n最近内容；完整记录见 transcript.md。",title:Self.escape(saved.title),summary:Self.escape(saved.summary)).utf8),to:liveURL)
            }
            try permission.require(token)
            try upsert(saved,root:root,token:token)
            try? FileManager.default.removeItem(at:directory.appendingPathComponent("ai-summary-error.json"))
            try audit(root:root,event:"summary.completed",id:record.id,hash:hash)
            return usedModel
        } catch {
            if (try? permission.require(token)) != nil {
                // Store no server response, key, URL, or transcript in diagnostics.
                let detail=error is CancellationError ? "已取消" : (error as? CaptionError)?.localizedDescription ?? "生成或文件写入失败，可重试。"
                try? write(JSONSerialization.data(withJSONObject:["session_id":record.id,"log_hash":hash,"error":detail,"at":SessionLog.timestamp()],options:.sortedKeys),to:directory.appendingPathComponent("ai-summary-error.json"))
                try? audit(root:root,event:"summary.failed",id:record.id,hash:hash)
            }
            throw error
        }
    }
    private func audit(root:URL,event:String,id:String,hash:String) throws {
        let url=root.appendingPathComponent("ai-events.jsonl")
        if !FileManager.default.fileExists(atPath:url.path) { FileManager.default.createFile(atPath:url.path,contents:nil,attributes:[.posixPermissions:0o600]) }
        let handle=try FileHandle(forWritingTo:url);defer { try? handle.close() };try handle.seekToEnd()
        var row=try JSONSerialization.data(withJSONObject:["event":event,"session_id":id,"log_hash":hash,"at":SessionLog.timestamp()],options:.sortedKeys);row.append(10);try handle.write(contentsOf:row)
    }
    private func upsert(_ entry:AIRecordSummary,root:URL,token:UInt64) throws {
        try permission.require(token)
        var entries=try registry(root);entries[entry.sessionID]=entry
        try write(encode(entries),to:root.appendingPathComponent("ai-index.json"))
        try permission.require(token)
        let blocks=entries.values.sorted { $0.startedAt > $1.startedAt }.map { item in
            let link=item.relativePath+"/transcript.md"
            let status=item.state == "complete" ? Self.escape(item.summary) : "记录中／待生成；结束后可生成标题与摘要。"
            return "## [\(Self.escape(item.title))](\(link))\n\n\(item.startedAt) · \(item.state == "complete" ? "已生成" : "待生成")\n\n\(status)\n\nID：`\(item.sessionID)`  \n正文 SHA-256：`\(item.logHash.isEmpty ? "待完成" : item.logHash)`\n"
        }
        try write(Data(("# 会话记录索引\n\n标题与摘要由 AI 生成，正文以各会话记录为准。关闭期间不更新；重新开启不会自动补历史，请在设置中手动补齐。\n\n"+blocks.joined(separator:"\n")).utf8),to:root.appendingPathComponent("index.md"))
    }
    private static func escape(_ value:String) -> String {
        var result=value.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;")
        for character in ["\\","[","]","(",")","*","_","`","#","!",">"] { result=result.replacingOccurrences(of:character,with:"\\"+character) }
        return result
    }
}
