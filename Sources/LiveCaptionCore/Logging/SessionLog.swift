import Foundation

public actor SessionLog {
    nonisolated public let sessionID: String
    nonisolated public let directory: URL
    nonisolated public let root: URL
    nonisolated public let audioArchive: AudioArchive
    public private(set) var transcript = Transcript()
    public private(set) var sequence = 0
    private var epoch = 0
    private var configs: [Int: Configuration] = [:]
    private var configuration: Configuration
    private var handle: FileHandle
    private var reflowHandle:FileHandle?
    private var reflowSequence=0
    private var snapshotTask: Task<Void, Never>?
    private let started = Date()
    private var active = true
    private var state = "preparing"
    private var notices: [(Date, String)] = []
    private var lastText: Date?
    private var closed = false
    private var snapshotSequence = 0
    public static func timestamp(_ date: Date = Date()) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.string(from: date)
    }
    public init(configuration: Configuration, rootOverride: URL? = nil) throws {
        self.configuration = configuration
        sessionID = UUID().uuidString.lowercased()
        root = rootOverride ?? URL(fileURLWithPath: (configuration.logDirectory as NSString).expandingTildeInPath, isDirectory: true)
        let day = DateFormatter(); day.dateFormat = "yyyy-MM-dd"; day.locale = Locale(identifier: "en_US_POSIX")
        directory = root.appendingPathComponent(day.string(from: Date())).appendingPathComponent(sessionID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent("events.jsonl")
        guard FileManager.default.createFile(atPath: path.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CaptionError.message("无法创建会话日志") }
        handle = try FileHandle(forWritingTo: path)
        audioArchive = try AudioArchive(sessionDirectory: directory)
    }
    deinit { try? handle.close();try? reflowHandle?.close() }
    public func begin() throws {
        try record("session.started",fields:["app_version":Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "unbundled",
                                            "app_build":Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "unbundled"])
        try snapshot()
    }
    public func beginEpoch(_ number: Int, configuration: Configuration) throws {
        epoch = number; configs[number] = configuration; self.configuration = configuration
        try record("connection.started", fields: ["connection_epoch": number])
    }
    public func activateEpoch(_ number: Int, configuration: Configuration) throws {
        epoch = number; self.configuration = configuration; configs[number] = configuration
        try record("connection.active",fields:["connection_epoch":number]); try snapshot()
    }
    public func changeConfiguration(_ config: Configuration, eventType: String = "mode.changed") throws {
        configuration = config; configs[epoch] = config
        try record(eventType, fields: config.safeMetadata)
    }
    public func setState(_ newState: String) throws { guard !closed else { return }; state = newState; try record("state.changed", fields: ["state": newState]); try snapshot() }
    public func captionLayout(_ rows:[CaptionParagraph],providerGroupIDs:[String],epoch:Int,model:String,elapsed:Double,attempts:Int=1) throws {
        let content:[String:Any] = ["schema_version":1,"session_id":sessionID,"connection_epoch":epoch,
            "derived_presentation":true,"updated_at":Self.timestamp(),"model":model,
            "rows":rows.map { ["id":$0.id,"source":$0.source,"translation":$0.translation] }]
        try JSONSerialization.data(withJSONObject:content,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("caption-layout.json"),options:.atomic)
        try record("caption.layout.applied",fields:["connection_epoch":epoch,"reflow_model":model,"elapsed_seconds":elapsed,"attempts":attempts,"row_count":rows.count,"provider_group_count":providerGroupIDs.count,
            "row_ids":rows.map(\.id),"unique_row_ids":Set(rows.map(\.id)).count == rows.count])
    }
    public func reflowTrace(_ trace:CaptionReflowTrace) throws {
        guard !closed else { throw CaptionError.message("分段日志已关闭，不能保存判断过程") }
        if reflowHandle == nil {
            let url=directory.appendingPathComponent("reflow-decisions.jsonl")
            guard FileManager.default.createFile(atPath:url.path,contents:nil,attributes:[.posixPermissions:0o600]) else { throw CaptionError.message("无法创建分段判断日志") }
            reflowHandle=try FileHandle(forWritingTo:url)
        }
        reflowSequence += 1
        // Request bodies contain no authentication fields. Redact configured secrets defensively
        // even if a test fixture or a future diagnostic accidentally includes one in text.
        let safe=configuration.redacted(String(decoding:trace.data,as:UTF8.self))
        var fields=(try JSONSerialization.jsonObject(with:Data(safe.utf8))) as? [String:Any] ?? [:]
        fields["event_type"]=trace.event;fields["trace_sequence"]=reflowSequence
        fields["received_at"]=Self.timestamp();fields["session_id"]=sessionID;fields["schema_version"]=1
        if fields["connection_epoch"] == nil { fields["connection_epoch"]=epoch }
        var data=try JSONSerialization.data(withJSONObject:fields,options:[.sortedKeys,.withoutEscapingSlashes]);data.append(0x0a)
        try reflowHandle?.write(contentsOf:data)
        var summary:[String:Any]=["trace_file":"reflow-decisions.jsonl","trace_sequence":reflowSequence]
        for key in ["job_id","context","stage","reason","elapsed_seconds","question_count","connection_epoch"] { summary[key]=fields[key] }
        try record(trace.event,fields:summary)
    }
    @discardableResult public func text(_ update: TextUpdate, epoch: Int) throws -> Transcript {
        guard !closed else { return transcript }
        let config = configs[epoch] ?? configuration
        guard let segment = transcript.apply(update, epoch: epoch, pipeline: config.pipeline) else { return transcript }
        lastText = Date()
        var fields: [String: Any] = ["connection_epoch": epoch, "track": segment.track, "segment_id": segment.id,
            "revision": segment.revision, "text": update.text, "finality": segment.finality.rawValue,
            "audio_start_ms": segment.audioStart as Any? ?? NSNull(), "audio_end_ms": segment.audioEnd as Any? ?? NSNull(),
            "time_origin": segment.audioStart == nil ? "local_receive" : "provider_audio"]
        if let providerID = update.providerID { fields["provider_segment_id"] = providerID }
        if let sourceID = update.sourceProviderID { fields["source_provider_segment_id"] = sourceID }
        if let speakerID = segment.speakerID { fields["speaker_id"] = speakerID }
        if update.boundary { fields["boundary_origin"] = "provider" }
        try record(update.replace ? "text.replace" : "text.append", fields: fields)
        if update.boundary { try record("segment.closed", fields: ["connection_epoch": epoch, "segment_id": segment.id, "finality": segment.finality.rawValue, "boundary_origin": "provider"]) }
        scheduleSnapshot()
        return transcript
    }
    public func closeEpoch(_ number: Int, providerBoundary: Bool = false) throws {
        for segment in transcript.close(epoch: number, providerBoundary: providerBoundary) {
            try record("segment.closed", fields: ["connection_epoch": number, "segment_id": segment.id, "finality": segment.finality.rawValue, "boundary_origin": providerBoundary ? "provider" : "application"])
        }
        scheduleSnapshot()
    }
    public func record(_ type: String, fields: [String: Any] = [:]) throws {
        guard !closed else { return }
        sequence += 1
        let eventEpoch = fields["connection_epoch"] as? Int ?? epoch
        var event = (configs[eventEpoch] ?? configuration).safeMetadata
        event.merge(fields) { _, new in new }
        event["schema_version"] = 1; event["session_id"] = sessionID; event["sequence"] = sequence
        event["connection_epoch"] = eventEpoch; event["event_type"] = type; event["received_at"] = Self.timestamp()
        var data = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys, .withoutEscapingSlashes])
        data.append(0x0a)
        try handle.write(contentsOf: data)
        if ["gap", "pipeline.changed", "input.changed", "error", "audio.processing"].contains(type) {
            let detail = fields["message"] as? String ?? type
            notices.append((Date(), detail)); scheduleSnapshot()
        }
    }
    private func scheduleSnapshot() {
        guard snapshotTask == nil else { return }
        snapshotTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.scheduledSnapshot()
        }
    }
    private var snapshotFailure: String?
    private func scheduledSnapshot() {
        snapshotTask = nil
        do { try snapshot() } catch { snapshotFailure = "记录快照写入失败" }
    }
    public func checkHealth() throws { if let failure = snapshotFailure { throw CaptionError.message(failure) } }
    public func flush() throws { guard !closed else { return }; try audioArchive.flush(); snapshotTask?.cancel(); snapshotTask = nil; try snapshot(); try handle.synchronize();try reflowHandle?.synchronize() }
    private func atomic(_ data: Data, at url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private func json(_ object: [String: Any], at url: URL) throws { try atomic(JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), at: url) }
    private func snapshot() throws {
        guard !closed else { return }
        snapshotSequence = sequence
        let now = Date()
        let info = "\(Self.timestamp(started)) · \(active ? "记录中" : "已结束") · 时间戳为本机收字时间（UTC）\n记录 ID：\(sessionID) · 更新：\(Self.timestamp(now))\n<!-- snapshot_sequence: \(snapshotSequence) -->" + (state == "stopped_tail_incomplete" ? "\n> 末段可能不完整。" : "")
        func render(since: Date?) -> String {
            var entries: [(Date, String)] = transcript.segments.filter { since == nil || $0.receivedAt >= since! }.map { s in
                return (s.receivedAt,SessionMarkdown.entry(time:s.receivedAt,track:s.track,finality:s.finality,text:s.text))
            }
            entries += notices.filter { since == nil || $0.0 >= since! }.map { ($0.0, "> [\(SessionMarkdown.shortTime($0.0))] \($0.1)\n\n") }
            return entries.sorted { $0.0 < $1.0 }.map(\.1).joined()
        }
        try atomic(Data(SessionMarkdown.document(body:render(since:nil),info:info).utf8), at: directory.appendingPathComponent("transcript.md"))
        try atomic(Data(SessionMarkdown.document(body:render(since:now.addingTimeInterval(-600)),info:info+"\n最近十分钟；完整记录见 transcript.md。").utf8), at: directory.appendingPathComponent("live.md"))
        var meta = configuration.safeMetadata
        meta.merge(["session_id": sessionID, "started_at": Self.timestamp(started), "active": active, "state": state,
                    "updated_at": Self.timestamp(now), "owner_pid": ProcessInfo.processInfo.processIdentifier, "connection_count": configs.keys.max() ?? 0, "active_connection_epoch":epoch, "written_sequence": sequence, "snapshot_sequence": snapshotSequence]) { _, n in n }
        try json(meta, at: directory.appendingPathComponent("session.json"))
        let relative = String(directory.path.dropFirst(root.path.count + 1))
        try json(["schema_version": 1, "session_id": sessionID, "session_path": relative, "active": active, "state": state,
                  "pipeline": configuration.pipeline.rawValue, "written_sequence": sequence, "snapshot_sequence": snapshotSequence,
                  "updated_at": Self.timestamp(now), "transcript": relative + "/transcript.md", "live": relative + "/live.md", "audio": relative + "/audio"], at: root.appendingPathComponent("latest.json"))
    }
    public func finish(tailIncomplete: Bool) throws {
        guard !closed else { return }
        snapshotTask?.cancel(); snapshotTask = nil
        let epochs = Set(transcript.segments.filter { !$0.closed }.map(\.epoch))
        for e in epochs { try closeEpoch(e) }
        snapshotTask?.cancel(); snapshotTask = nil
        var audioFailure: Error?
        do { try audioArchive.finish() } catch {
            audioFailure = error
            try record("audio.archive_failed", fields:["message":"录音收尾失败；保留已有 WAV 与索引供检查"])
        }
        active = false; state = tailIncomplete ? "stopped_tail_incomplete" : "stopped"
        try record("session.stopped", fields: ["tail_incomplete": tailIncomplete])
        try snapshot(); try handle.synchronize(); try reflowHandle?.synchronize();try reflowHandle?.close();reflowHandle=nil;try handle.close(); closed = true
        if let audioFailure { throw audioFailure }
    }
}
