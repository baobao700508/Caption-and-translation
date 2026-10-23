import Foundation
import SwiftUI
import LiveCaptionCore

@MainActor final class AIRecordController:ObservableObject {
    @Published var settings:AISummarySettings { didSet { settingsChanged(from:oldValue) } }
    @Published var apiKey="" { didSet { keyChanged() } }
    @Published private(set) var message="关闭时不调用模型，也不更新 AI 索引。"
    @Published private(set) var working=false
    @Published private(set) var inspecting=false
    @Published private(set) var plan:[AIRecordWork]=[]
    @Published var showPlan=false
    private let store=AIRecordStore()
    private var token:UInt64=0
    private var root:URL?
    private var task:Task<Void,Never>?
    private var saveKeyTask:Task<Void,Never>?
    private var loadKeyTask:Task<Void,Never>?
    private var jobID=UUID()
    private var eligible:Set<URL>=[]
    private var automaticQueue:[URL]=[]
    private var loadingKey=false
    private let defaults:UserDefaults
    init(defaults:UserDefaults = .standard) {
        self.defaults=defaults
        settings=defaults.data(forKey:"ai-summary-settings").flatMap { try? JSONDecoder().decode(AISummarySettings.self,from:$0) } ?? AISummarySettings()
        token=store.permission.update(enabled:settings.enabled)
        loadKey()
        if settings.enabled { message="已开启。只处理新会话；历史记录需要手动补齐。" }
    }
    var modelCount:Int { plan.filter(\.needsModel).count }
    var repairCount:Int { plan.count-modelCount }
    var rootPath:String { root?.path ?? "" }
    private var keyService:String {
        (Bundle.main.bundleIdentifier ?? "local.livecaption.mac")+".ai-summary."+SessionMarkdown.hash(settings.baseURL)
    }
    func setRoot(_ url:URL) {
        let next=url.standardizedFileURL
        guard root != next else { return }
        cancelWork();root=next;eligible.removeAll();automaticQueue.removeAll();plan=[]
    }
    private func cancelWork() {
        token=store.permission.update(enabled:settings.enabled)
        task?.cancel();task=nil;jobID=UUID();working=false;inspecting=false;showPlan=false
    }
    private func settingsChanged(from old:AISummarySettings) {
        cancelWork()
        if !settings.enabled { eligible.removeAll();automaticQueue.removeAll() }
        if let data=try? JSONEncoder().encode(settings) { defaults.set(data,forKey:"ai-summary-settings") }
        message=settings.enabled ? "已开启。重新开启不会补历史，请手动补齐摘要与索引。" : "已关闭。不调用模型、不更新索引；历史记录不会在重新开启时自动补齐。"
        if old.baseURL != settings.baseURL || old.useLocalCPA != settings.useLocalCPA { loadKey() }
    }
    private func loadKey() {
        loadKeyTask?.cancel();saveKeyTask?.cancel()
        loadingKey=true;apiKey="";loadingKey=false
        guard !settings.useLocalCPA,!settings.baseURL.isEmpty else { return }
        let service=keyService
        loadKeyTask=Task { [weak self] in
            try? await Task.sleep(nanoseconds:350_000_000)
            guard !Task.isCancelled else { return }
            let key=await Task.detached { KeyStorage.load(service:service) ?? "" }.value
            guard !Task.isCancelled,let self,self.keyService == service,self.apiKey.isEmpty else { return }
            self.loadingKey=true;self.apiKey=key;self.loadingKey=false
        }
    }
    private func keyChanged() {
        guard !loadingKey,!settings.useLocalCPA else { return }
        loadKeyTask?.cancel();saveKeyTask?.cancel();cancelWork()
        let key=apiKey,service=keyService
        saveKeyTask=Task { [weak self] in
            try? await Task.sleep(nanoseconds:500_000_000)
            guard !Task.isCancelled else { return }
            let saved=await Task.detached { KeyStorage.save(key,service:service) }.value
            guard !Task.isCancelled,let self else { return }
            if !saved { self.message="API Key 未能保存到钥匙串，请检查系统授权后重新填写。" }
        }
    }
    func started(directory:URL,root:URL) {
        setRoot(root)
        guard settings.enabled else { return }
        eligible.insert(directory)
        let token=self.token
        Task { [weak self] in
            guard let self else { return }
            do { try await self.store.markPending(directory:directory,root:root,token:token) }
            catch is CancellationError {} catch { self.message="AI 索引未能标记新会话；结束后可手动补齐。" }
        }
    }
    func finished(directory:URL) {
        guard settings.enabled,eligible.remove(directory) != nil,let root else { return }
        let token=self.token
        Task { [weak self] in
            guard let self else { return }
            try? await self.store.markPending(directory:directory,root:root,token:token)
            guard self.settings.enabled,self.token == token else { return }
            self.automaticQueue.append(directory);self.drainAutomaticQueue()
        }
    }
    private func drainAutomaticQueue() {
        guard settings.enabled,!working,!inspecting,!showPlan,!automaticQueue.isEmpty else { return }
        let directory=automaticQueue.removeFirst()
        run([AIRecordWork(directory:directory,sessionID:directory.lastPathComponent,needsModel:true)])
    }
    func inspectHistory() {
        guard settings.enabled,!working,!inspecting,let root else { return }
        inspecting=true;let id=UUID();jobID=id
        task=Task { [weak self] in
            guard let self else { return }
            defer { if self.jobID == id { self.inspecting=false } }
            do {
                let work=try await store.plan(root:root)
                guard self.jobID == id,!Task.isCancelled,self.settings.enabled else { return }
                self.plan=work;self.showPlan=true
            } catch { if self.jobID == id { self.message="无法检查历史记录，请确认日志目录可访问。" } }
        }
    }
    func runPlan() { showPlan=false;run(plan) }
    func cancelPlan() { showPlan=false;drainAutomaticQueue() }
    private func run(_ work:[AIRecordWork]) {
        guard settings.enabled,!working,let root else { return }
        let snapshot=settings,manualKey=apiKey,token=self.token,id=UUID()
        jobID=id;working=true
        task=Task { [weak self] in
            guard let self else { return }
            var completed=0,failed=0
            var lastError=""
            var resolvedKey:String?
            for (index,item) in work.enumerated() {
                guard !Task.isCancelled,self.jobID == id,self.settings.enabled else { break }
                self.message="正在补齐 \(index+1)/\(work.count)：\(item.needsModel ? "生成标题与摘要" : "修复记录与索引")"
                do {
                    if item.needsModel && resolvedKey == nil { resolvedKey=try await self.resolveKey(settings:snapshot,manualKey:manualKey) }
                    try store.permission.require(token)
                    try await store.process(directory:item.directory,root:root,settings:snapshot,key:resolvedKey ?? "",token:token);completed += 1
                }
                catch is CancellationError { break }
                catch { failed += 1;lastError=(error as? CaptionError)?.localizedDescription ?? "文件读写失败，请检查目录权限。" }
            }
            guard self.jobID == id else { return }
            self.working=false
            self.message="完成 \(completed) 条，失败 \(failed) 条。"+(failed>0 ? "\(lastError) 再次点击补齐可重试，已完成项不会重复调用。" : "记录和 index.md 已同步补齐。")
            self.plan=[];self.drainAutomaticQueue()
        }
    }
    func testConnection() {
        guard settings.enabled,!working,!inspecting else { return }
        let snapshot=settings,manualKey=apiKey,id=UUID(),token=self.token
        jobID=id;working=true;message="正在测试连接（只发送一段示例文字）…"
        task=Task { [weak self] in
            guard let self else { return }
            do {
                let key=try await self.resolveKey(settings:snapshot,manualKey:manualKey)
                try store.permission.require(token)
                _ = try await AISummaryClient().summarize("会议讨论了下周发布计划，决定先完成测试，再发布新版本。",settings:snapshot,key:key)
                try store.permission.require(token)
                if self.jobID == id { self.message="连接成功，模型能生成标题与摘要。" }
            } catch { if self.jobID == id { self.message=(error as? CaptionError)?.localizedDescription ?? "连接失败，请检查配置后重试。" } }
            if self.jobID == id { self.working=false;self.drainAutomaticQueue() }
        }
    }
    private func resolveKey(settings:AISummarySettings,manualKey:String) async throws -> String {
        guard settings.useLocalCPA else { return manualKey }
        let endpoint=try settings.endpoint()
        return try await Task.detached { try CPAClientCredential.read(endpoint:endpoint) }.value
    }
}
