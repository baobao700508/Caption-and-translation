import Foundation
import LiveCaptionCore

private actor SummaryFixture:AISummarizing {
    private(set) var calls=0
    var failures:Int
    let delay:UInt64
    init(failures:Int=0,delay:UInt64=0) { self.failures=failures;self.delay=delay }
    func summarize(_ text:String,settings:AISummarySettings,key:String) async throws -> AISummary {
        calls += 1
        if delay>0 { try await Task.sleep(nanoseconds:delay) }
        if failures>0 { failures -= 1;throw CaptionError.message("测试服务暂时失败") }
        return AISummary(title:"发布讨论",summary:"先修复设置点击范围，再完成验证并发布。")
    }
}
extension PipelineChecks {
    func testCPAUsesOnlyLocalClientConfiguration() throws {
        let file=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".yaml")
        defer { try? FileManager.default.removeItem(at:file) }
        try Data("port: 8318\napi-keys:\n  - \"fixture-client-key\"\nother: ignored\n".utf8).write(to:file)
        XCTAssertEqual(try CPAClientCredential.read(endpoint:URL(string:"http://127.0.0.1:8318/v1")!,configurationURL:file),"fixture-client-key")
        do { _ = try CPAClientCredential.read(endpoint:URL(string:"https://remote.example/v1")!,configurationURL:file);XCTAssertTrue(false) } catch {}
        try Data("api-keys: []\n".utf8).write(to:file)
        do { _ = try CPAClientCredential.read(endpoint:URL(string:"http://127.0.0.1:8318/v1")!,configurationURL:file);XCTAssertTrue(false) } catch {}
        let old=try JSONDecoder().decode(AISummarySettings.self,from:Data(#"{"enabled":false,"provider":"CPA","baseURL":"","model":""}"#.utf8))
        XCTAssertFalse(old.useLocalCPA)
    }
    private func summaryRecord(root:URL) async throws -> URL {
        let log=try SessionLog(configuration:Configuration(),rootOverride:root)
        try await log.begin();try await log.beginEpoch(1,configuration:Configuration())
        try await log.text(TextUpdate(track:"source",text:"First fix navigation, then test and release.",replace:true,finality:.final,boundary:true),epoch:1)
        try await log.finish(tailIncomplete:false);return log.directory
    }
    func testAIRecordDisabledReenableAndManualBackfill() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let directory=try await summaryRecord(root:root),client=SummaryFixture(),store=AIRecordStore(client:client)
        let original=try Data(contentsOf:directory.appendingPathComponent("transcript.md"))
        let off=store.permission.update(enabled:false)
        do { try await store.process(directory:directory,root:root,settings:AISummarySettings(),key:"",token:off);XCTAssertTrue(false) } catch is CancellationError {}
        let callsOff=await client.calls;XCTAssertEqual(callsOff,0)
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("index.md").path))
        let on=store.permission.update(enabled:true)
        let plan=try await store.plan(root:root)
        XCTAssertEqual(plan.count,1);XCTAssertEqual(plan.first?.needsModel,true)
        let callsBeforeManual=await client.calls;XCTAssertEqual(callsBeforeManual,0)
        XCTAssertEqual(try Data(contentsOf:directory.appendingPathComponent("transcript.md")),original)
        try await store.process(directory:directory,root:root,settings:AISummarySettings(),key:"",token:on)
        let full=try String(contentsOf:directory.appendingPathComponent("transcript.md"))
        XCTAssertTrue(full.contains("# 发布讨论"));XCTAssertTrue(full.contains("摘要：先修复"))
        XCTAssertTrue(full.contains("snapshot_sequence:"))
        let body=SessionMarkdown.body(in:full),index=try String(contentsOf:root.appendingPathComponent("index.md"))
        XCTAssertTrue(index.contains(SessionMarkdown.hash(body)));XCTAssertTrue(index.contains(directory.lastPathComponent+"/transcript.md"))
        let after=try await store.plan(root:root);XCTAssertEqual(after.count,0)
        let disabled=store.permission.update(enabled:false)
        let indexBefore=try Data(contentsOf:root.appendingPathComponent("index.md"))
        do { try await store.process(directory:directory,root:root,settings:AISummarySettings(),key:"",token:disabled);XCTAssertTrue(false) } catch is CancellationError {}
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("index.md")),indexBefore)
    }
    func testAIRecordFailureRetryAndIndexOnlyRepair() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let directory=try await summaryRecord(root:root),client=SummaryFixture(failures:1),store=AIRecordStore(client:client)
        let token=store.permission.update(enabled:true)
        do { try await store.process(directory:directory,root:root,settings:AISummarySettings(),key:"",token:token);XCTAssertTrue(false) } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath:directory.appendingPathComponent("ai-summary.json").path))
        try await store.process(directory:directory,root:root,settings:AISummarySettings(),key:"",token:token)
        try await store.process(directory:directory,root:root,settings:AISummarySettings(),key:"",token:token)
        let calls=await client.calls;XCTAssertEqual(calls,2)
        try FileManager.default.removeItem(at:root.appendingPathComponent("index.md"))
        var plan=try await store.plan(root:root);XCTAssertEqual(plan.count,1);XCTAssertEqual(plan.first?.needsModel,false)
        try await store.process(directory:directory,root:root,settings:AISummarySettings(),key:"",token:token)
        let callsRepaired=await client.calls;XCTAssertEqual(callsRepaired,2)
        let index=try String(contentsOf:root.appendingPathComponent("index.md"))
        XCTAssertEqual(index.components(separatedBy:"ID：`"+directory.lastPathComponent+"`").count-1,1)
        try Data("# damaged projection\n".utf8).write(to:root.appendingPathComponent("index.md"))
        plan=try await store.plan(root:root);XCTAssertEqual(plan.first?.needsModel,false)
    }
    func testAIRecordProjectionFailureUsesCachedSummary() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let directory=try await summaryRecord(root:root),client=SummaryFixture(),store=AIRecordStore(client:client)
        let token=store.permission.update(enabled:true),index=root.appendingPathComponent("index.md")
        try FileManager.default.createDirectory(at:index,withIntermediateDirectories:true)
        do { try await store.process(directory:directory,root:root,settings:AISummarySettings(),key:"",token:token);XCTAssertTrue(false) } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath:directory.appendingPathComponent("ai-summary.json").path))
        try FileManager.default.removeItem(at:index)
        try await store.process(directory:directory,root:root,settings:AISummarySettings(),key:"",token:token)
        let calls=await client.calls;XCTAssertEqual(calls,1)
        let work=try await store.plan(root:root);XCTAssertEqual(work.count,0)
    }
    func testAIRecordDisableInFlightRejectsLateResult() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let directory=try await summaryRecord(root:root),client=SummaryFixture(delay:300_000_000),store=AIRecordStore(client:client)
        let token=store.permission.update(enabled:true)
        let job=Task { try await store.process(directory:directory,root:root,settings:AISummarySettings(),key:"",token:token) }
        while await client.calls == 0 { try await Task.sleep(nanoseconds:10_000_000) }
        store.permission.update(enabled:false);store.permission.update(enabled:true)
        do { _ = try await job.value;XCTAssertTrue(false) } catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath:directory.appendingPathComponent("ai-summary.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("index.md").path))
    }
    func testAIRecordCompactLegacyAndLongInput() throws {
        let legacy="# 课堂记录\n\n会话：example\n\n[2026-10-22T23:05:12.123Z] 原文 · 识别定稿 · translate · connection 1\n\nHello 世界.\n\n[2026-10-22T23:05:13.000Z] 译文 · 未确认 · translate · connection 1\n\n你好。\n\n"
        let body=SessionMarkdown.body(in:legacy)
        XCTAssertEqual(body,"[23:05:12] 原文：Hello 世界.\n\n[23:05:13] 译文（未确认）：你好。\n\n")
        XCTAssertEqual(SessionMarkdown.body(in:SessionMarkdown.document(body:body,info:"meta",title:"AI title",summary:"brief")),body)
        let long=String(repeating:"中文 and English 🗣️\n",count:4000)
        let chunks=AISummaryClient.chunks(long)
        XCTAssertTrue(chunks.count>1);XCTAssertEqual(chunks.joined(),long)
        var settings=AISummarySettings();settings.provider="CPA";settings.model="fixture";settings.baseURL="http://127.0.0.1:8318/v1"
        XCTAssertEqual(try settings.endpoint().path,"/v1/chat/completions")
        settings.baseURL="https://example.org/v1/chat/completions";XCTAssertEqual(try settings.endpoint().path,"/v1/chat/completions")
        settings.baseURL="http://remote.example/v1"
        do { _ = try settings.endpoint();XCTAssertTrue(false) } catch {}
    }
}
