import AppKit
import SwiftUI
import Security
import LocalAuthentication
import AVFoundation
import LiveCaptionCore

@MainActor final class AppSession: ObservableObject {
    static let shared = AppSession()
    @Published var config = Configuration()
    @Published var status = "未开始"
    @Published var errorMessage: String?
    @Published var running = false
    @Published var busy = false
    @Published var configurationReady = false
    @Published var configurationLoading = false
    @Published var presentation: CaptionPresentation = .expanded
    @Published var settingsSection: SettingsSection = .session
    private var feedbackDismissTask:Task<Void,Never>?
    @Published var feedback: String? {
        didSet {
            feedbackDismissTask?.cancel()
            guard feedback != nil else { feedbackDismissTask=nil;return }
            feedbackDismissTask=Task { [weak self] in
                do { try await Task.sleep(nanoseconds:3_000_000_000) } catch { return }
                guard !Task.isCancelled else { return }
                self?.feedback=nil
            }
        }
    }
    @Published var sessionStartedAt: Date?
    @Published var sessionEndedAt: Date?
    @Published var lastCaptionAt: Date?
    var preferencesWindow: PreferencesWindowController?
    var menuBar: MenuBarController?
    let localModels=LocalModelManager()
    let aiRecords:AIRecordController
    @Published var sourceText = "选择音源，开始会话记录"
    @Published var translatedText = ""
    @Published var captionParagraphs: [CaptionParagraph] = []
    @Published var followsLatestCaption = true {
        didSet { if followsLatestCaption && !captionReflow.rows.isEmpty { captionParagraphs=captionReflow.rows } }
    }
    @Published var reflowStatus = "未启用"
    private var lastCaptionSnapshot: (Transcript,Int,Pipeline)?
    var providerCaptionParagraphs:[CaptionParagraph] {
        guard let (transcript,epoch,_)=lastCaptionSnapshot else { return [] }
        return transcript.captionParagraphs(epoch:epoch)
    }
    private let reflowSettingsWriter=CaptionReflowSettingsWriter()
    private var reflowSettingsRevision:UInt64=0
    private(set) var reflowSettingsSave:Task<Void,Never>?
    lazy var captionReflow:CaptionReflowCoordinator = {
        let coordinator=CaptionReflowCoordinator()
        coordinator.onChange = { [weak self] rows,status in
            guard let self else { return }
            self.reflowStatus=status
            // Do not move the passage being read; apply the newest projection on return to latest.
            if self.followsLatestCaption || self.captionParagraphs.isEmpty { self.captionParagraphs=rows }
        }
        coordinator.onApplied = { [weak self,weak coordinator] ids,_,seconds in
            guard let self,let coordinator,let log=self.logger ?? self.layoutLogger else { return }
            let rows=coordinator.rows,model=self.config.captionReflow.activeModel,epoch=self.lastCaptionSnapshot?.1 ?? 0
            let attempts=coordinator.attemptCount
            Task {
                do { try await log.captionLayout(rows,providerGroupIDs:ids,epoch:epoch,model:model,elapsed:seconds,attempts:attempts) }
                catch { self.reflowStatus="字幕已整理，但排版快照未保存；原始日志继续" }
            }
        }
        return coordinator
    }()
    @Published var systemLevel: Float = 0
    @Published var microphoneLevel: Float = 0
    @Published var processingDescription = "启动采集时自动启用降噪"
    @Published var recordingPlayback: String?
    var recordingPlayer: AVAudioPlayer?
    var recordingPlaybackTask: Task<Void, Never>?
    @Published var currentDirectory: URL?
    @Published var passthrough = false { didSet { overlay?.setPassthrough(passthrough); saveAppearance() } }
    @Published var fontSize = 25.0 { didSet { saveAppearance() } }
    @Published var overlayOpacity = 0.85 { didSet { saveAppearance() } }
    @Published var volume: Float = 0.7 { didSet { hardware.volume = volume } }
    lazy var hardware = AudioHardware()
    var overlay: OverlayController?
    private var logger: SessionLog?
    private var layoutLogger: SessionLog?
    private var displayedProviderItems:Set<String> = []
    private var connection: (any ProviderConnection)?
    private var drainTasks: [Int:Task<Bool,Never>] = [:]
    private var tailIncomplete = false
    private var audioStartedEpochs: Set<Int> = []
    private var frontend: AudioFrontend?
    private var packetTask: Task<Void, Never>?
    private var inputQueue:AudioPacketQueue?
    private var sendNotBefore:TimeInterval=0
    private var invalidatedEpochs:Set<Int>=[]
    private(set) var discardedInputSamples=0
    private var pendingRecoverySummary:(epoch:Int,discardedBefore:Int)?
    private(set) var discardedOutputSamples=0
    private var verificationFault:Task<Void,Never>?
    var testOnlyDisconnectAfter:TimeInterval?
    var testOnlyReconnectDelay:TimeInterval=0
    private var rotationTask: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    var reconnecting:Bool { recoveryTask != nil }
    private var epoch = 0
    private var epochCounter = 0
    private var handles: [Int:String] = [:]
    private var runID = UUID()
    private var stopping = false
    private var resumeHandle: String?
    private var fileDate: Date = .distantPast
    private var configurationURL = Configuration.desktopURL
    private var configurationRequestID = UUID()
    var testOnlySystemPID: pid_t?
    var verificationInProgress = false
    var testOnlyFilePCM: Data?
    private var fileReplayProducer: Task<Void,Never>?
    private var logScopeURL: URL?
    private var routeObserver: NSObjectProtocol?
    private var routeRecoveryTask:Task<Void,Never>?
    private(set) var audioInputRestartCount=0
    private(set) var audioEngineResumeCount=0
    private var preferencesRevision:UInt64=0
    private var hasRuntimePreferences=false
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var suspendTask: Task<Void,Never>?
    private var resumeWanted = false
    private let preferences:UserDefaults
    init(defaults:UserDefaults = .standard,configurationURL:URL = Configuration.desktopURL) {
        preferences=defaults
        aiRecords=AIRecordController(defaults:defaults)
        self.configurationURL=configurationURL
        if defaults.object(forKey:"caption-font-size") != nil { fontSize = min(44,max(16,defaults.double(forKey:"caption-font-size"))) }
        if defaults.object(forKey:"caption-opacity") != nil { overlayOpacity = min(1,max(0.45,defaults.double(forKey:"caption-opacity"))) }
        // Mouse passthrough deliberately starts off so the floating controls remain reachable.
        if let saved = preferences.data(forKey: "runtime-settings"), let restored = try? Configuration.decode(saved) {
            config = restored;hasRuntimePreferences=true
        }
        // AVAudioEngine posts from its internal serial queue. A main OperationQueue
        // observer waits synchronously and deadlocks against engine teardown on main.
        routeObserver = NotificationCenter.default.addObserver(forName:.AVAudioEngineConfigurationChange,object:nil,queue:nil) { [weak self] notification in
            guard let engine=notification.object as? AVAudioEngine else { return }
            Task { @MainActor [weak self] in self?.audioConfigurationChanged(engine) }
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.willSleepNotification,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in self?.prepareForSleep() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didWakeNotification,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in await self?.resumeAfterWake() }
        }
    }
}

// MARK: - 电源状态
extension AppSession {
    private func prepareForSleep() {
        guard running && !stopping else { return }
        routeRecoveryTask?.cancel();routeRecoveryTask=nil
        resumeWanted = true; busy = true; status = "休眠暂停"
        tailIncomplete = true
        rotationTask?.cancel(); recoveryTask?.cancel()
        frontend?.stop(); frontend = nil; let packets = packetTask; packetTask = nil; packets?.cancel()
        let old = connection; connection = nil
        let oldLogger = logger; let oldEpoch = epoch
        suspendTask = Task {
            await hardware.stop(); await old?.close(); await packets?.value
            try? await oldLogger?.closeEpoch(oldEpoch)
            try? await oldLogger?.record("gap",fields:["message":"系统休眠，期间不采集也不补录"])
            try? await oldLogger?.setState("sleeping")
        }
    }
    private func resumeAfterWake() async {
        guard resumeWanted && running && !stopping else { return }
        await suspendTask?.value; suspendTask = nil
        guard resumeWanted && running && !stopping else { return }
        resumeWanted = false; status = "唤醒后恢复中"
        do {
            do { try await openConnection(config:config,resuming:resumeHandle,change:true) }
            catch { resumeHandle = nil; try await openConnection(config:config,resuming:nil,change:true) }
            try await startAudio(); status = config.pipeline == .transcribe ? "转写中" : "翻译中"
            try await logger?.setState(status)
        } catch { errorMessage = redacted(error.localizedDescription); await stop() }
        busy = false
    }
}

// MARK: - 配置与偏好
extension AppSession {
    func reloadConfiguration(preservePreferences: Bool = false) async {
        let requestID = UUID(); configurationRequestID = requestID
        let reflowRevisionAtLoad=reflowSettingsRevision
        let preferencesRevisionAtLoad=preferencesRevision
        configurationLoading = true
        defer { if configurationRequestID == requestID { configurationLoading = false } }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds:8_000_000_000)
            guard let self, self.configurationRequestID == requestID, self.configurationLoading else { return }
            self.errorMessage = "配置读取仍在等待系统响应；可点“选择配置…”重新授予文件访问。"
        }
        let fallback = configurationURL
        let bookmark = verificationInProgress ? nil : preferences.data(forKey:"configuration-bookmark")
        let useKeychain = !verificationInProgress
        let result = await Task.detached(priority: .userInitiated) { () -> Result<(Configuration, Date, URL), Error> in
            do {
                var stale = false
                let url = bookmark.flatMap { try? URL(resolvingBookmarkData:$0,options:.withSecurityScope,relativeTo:nil,bookmarkDataIsStale:&stale) } ?? fallback
                let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                var config = try Configuration.load(from: url)
                if useKeychain && config.provider == .bailian && config.bailianAPIKey.isEmpty { config.bailianAPIKey = KeyStorage.load(provider:.bailian) ?? "" }
                if useKeychain && config.provider == .google && config.apiKey.isEmpty { config.apiKey = KeyStorage.load() ?? "" }
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return .success((config,date,url))
            } catch { return .failure(error) }
        }.value
        guard configurationRequestID == requestID else { return }
        switch result {
        case .success(let (loaded,date,url)):
            configurationURL = url
            let currentReflow=config.captionReflow
            // File dates also change when SaT/credentials save unrelated fields.
            // Automatic startup refreshes credentials, preserving the user's UI choices.
            // Only an explicit import/reload replaces already-saved preferences.
            if (!preservePreferences || !hasRuntimePreferences) && preferencesRevision == preferencesRevisionAtLoad { config = loaded }
            if reflowSettingsRevision != reflowRevisionAtLoad { config.captionReflow=currentReflow }
            config.bailianAPIKey = loaded.bailianAPIKey
            config.apiKey = loaded.apiKey
            if !verificationInProgress && preferences.integer(forKey:"caption-layout-control-version") < 1 {
                if config.subtitleLayout == .source {
                    config.subtitleLayout = .bilingual
                    feedback = "已恢复译文显示；可在字幕顶部选择原文、译文或双语。"
                }
                preferences.set(1,forKey:"caption-layout-control-version"); savePreferences()
            }
            fileDate = date
            if !verificationInProgress { preferences.set(date,forKey:"last-config-date") }
            errorMessage = nil
            configurationReady = true
            savePreferences()
        case .failure:
            configurationReady = false; errorMessage = "配置无法读取；可用“选择配置”选取桌面 JSON 文件，授予文件访问权限。"
        }
    }
    func chooseConfiguration() async {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.message = "选择桌面 LiveCaption配置.json"; panel.directoryURL = Configuration.desktopURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let data = try? url.bookmarkData(options:.withSecurityScope,includingResourceValuesForKeys:nil,relativeTo:nil) { preferences.set(data,forKey:"configuration-bookmark") }
        configurationURL = url; await reloadConfiguration()
    }
    var selectedConfigurationURL: URL { configurationURL }
    func openConfiguration() { NSWorkspace.shared.open(configurationURL) }
    func createInitialConfiguration(root:URL?=nil) async {
        guard !running && !busy else { return }
        let url=(root ?? LocalModelFiles.root).appendingPathComponent("Configuration.json")
        do {
            try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
            if !FileManager.default.fileExists(atPath:url.path) {
                var initial=Configuration();initial.pipeline = .transcribe;initial.transcribeProvider = .whisperKit
                initial.captionReflow.enabled=false
                let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
                try encoder.encode(initial).write(to:url,options:.withoutOverwriting)
            }
            let bookmark=try url.bookmarkData(options:.withSecurityScope,includingResourceValuesForKeys:nil,relativeTo:nil)
            if !verificationInProgress { preferences.set(bookmark,forKey:"configuration-bookmark") }
            configurationURL=url
            await reloadConfiguration()
            showSettings(.models)
            feedback="配置已创建。下载 Whisper 后即可本地转写；需要翻译时再填写云服务凭据。"
        } catch { errorMessage="无法创建配置："+error.localizedDescription }
    }
    func saveCloudCredentials() async {
        let snapshot=config
        guard snapshot.provider != .whisperKit,!snapshot.activeAPIKey.isEmpty else {
            errorMessage="请先填写当前云服务的 API Key。";return
        }
        let saved=await Task.detached { ()->Bool in
            KeyStorage.save(snapshot.activeAPIKey,provider:snapshot.provider)
        }.value
        guard saved else { errorMessage="钥匙串未能保存凭据，请检查系统授权后重试。";return }
        do {
            fileDate=try await reflowSettingsWriter.saveConnection(snapshot,url:configurationURL)
            preferences.set(fileDate,forKey:"last-config-date")
            savePreferences();feedback="服务凭据已保存到 macOS 钥匙串，其他选择已保存。"
        } catch { errorMessage="凭据已存钥匙串，但配置文件未能保存："+error.localizedDescription }
    }
    func preferencesChanged() { savePreferences() }
    private func saveAppearance() {
        guard !verificationInProgress else { return }
        preferences.set(fontSize,forKey:"caption-font-size")
        preferences.set(overlayOpacity,forKey:"caption-opacity")
    }
    private func savePreferences() {
        guard !verificationInProgress else { return }
        preferencesRevision += 1;hasRuntimePreferences=true
        var safe = config; safe.apiKey = ""; safe.bailianAPIKey = ""
        if let data = try? JSONEncoder().encode(safe) { preferences.set(data, forKey: "runtime-settings") }
    }
}

// MARK: - 录制、采集与发送
extension AppSession {
    func start(persistSettings: Bool = true) async {
        guard !running && !busy && configurationReady else { return }
        stopRecordingPlayback()
        busy = true; stopping = false; errorMessage = nil; status = "准备中"
        if persistSettings { await reloadConfiguration(preservePreferences: true) }
        do {
            guard configurationReady else { throw CaptionError.message("配置尚未就绪，请先选择配置文件") }
            try config.validate()
            if config.provider == .whisperKit && !LocalModelFiles.whisperReady(config.localWhisper) {
                showSettings(.models)
                throw CaptionError.message("请先在“本地模型”完成 Whisper 下载与验证，再开始记录。")
            }
            if persistSettings && config.provider != .whisperKit { let key = config.activeAPIKey; let provider = config.provider; await Task.detached { KeyStorage.save(key,provider:provider) }.value }
            if persistSettings { savePreferences() }
            let root = URL(fileURLWithPath:(config.logDirectory as NSString).expandingTildeInPath)
            if let bookmark = preferences.data(forKey:"log-directory-bookmark") {
                logScopeURL = await Task.detached {
                    var stale = false
                    guard let url = try? URL(resolvingBookmarkData:bookmark,options:.withSecurityScope,relativeTo:nil,bookmarkDataIsStale:&stale),
                          url.standardizedFileURL == root.standardizedFileURL, url.startAccessingSecurityScopedResource() else { return nil as URL? }
                    return url
                }.value
            }
            _ = try await Task.detached { try LogRecovery.recoverIfNeeded(root:root) }.value
            let sessionConfig = config
            let log = try await Task.detached { try SessionLog(configuration: sessionConfig) }.value; logger = log; layoutLogger = log
            try await log.begin(); currentDirectory = log.directory
            aiRecords.started(directory:log.directory,root:log.root)
            tailIncomplete = false; drainTasks.removeAll()
            audioStartedEpochs.removeAll()
            captionReflow.reset(); lastCaptionSnapshot=nil; displayedProviderItems=[]
            invalidatedEpochs=[];sendNotBefore=0;discardedInputSamples=0;discardedOutputSamples=0;pendingRecoverySummary=nil
            epoch = 0; epochCounter = 0; handles.removeAll(); runID = UUID(); sourceText = "等待识别文字…"; translatedText = ""; captionParagraphs = []; followsLatestCaption = true
            sessionStartedAt = Date(); sessionEndedAt = nil; lastCaptionAt = nil
            running = true
            try await openConnection(config: config, resuming: nil, change: false)
            try await startAudio()
            startHealthCheck()
            status = config.pipeline == .transcribe ? "转写中" : "翻译中"
            try await log.setState(status)
        } catch {
            if error is CancellationError && stopping { return }
            errorMessage = redacted(error.localizedDescription)
            await stop(); status = "启动失败"
        }
        busy = false
    }
    private func startAudio() async throws {
        let id = runID
        if verificationInProgress, let pcm=testOnlyFilePCM {
            hardware.playbackEnabled=false
            let queue=AudioPacketQueue(), origin=Date().timeIntervalSince1970
            try await logger?.record("verification.file_input_started",fields:["input_started_at":SessionLog.timestamp(Date(timeIntervalSince1970:origin)),"samples":pcm.count/2])
            let meterSystem=config.systemAudioEnabled,meterMicrophone=config.microphoneEnabled
            fileReplayProducer=Task.detached { [weak self] in
                defer { queue.finish() }
                for offset in stride(from:0,to:pcm.count,by:3200) {
                    let end=min(offset+3200,pcm.count), time=origin+Double(end)/32000
                    do {
                        let delay=time-Date().timeIntervalSince1970
                        if delay>0 { try await Task.sleep(nanoseconds:UInt64(delay*1e9)) }
                        try Task.checkCancellation()
                    } catch { return }
                    _ = queue.append(CapturedAudio(data:pcm.subdata(in:offset..<end),timing:AudioTiming(captureStartedAt:origin+Double(offset)/32000,captureEndedAt:time,preparedAt:Date().timeIntervalSince1970)))
                    // File replay exercises the same observable meter refresh as the real frontend (10 Hz).
                    var energy:Float=0
                    for i in stride(from:offset,to:end-1,by:2) {
                        let sample=Float(Int16(bitPattern:UInt16(pcm[i])|UInt16(pcm[i+1])<<8))/32768
                        energy += sample*sample
                    }
                    let level=sqrt(energy/Float(max(1,(end-offset)/2)))
                    await MainActor.run { [weak self] in
                        guard let self,self.runID == id else { return }
                        self.systemLevel=meterSystem ? level:0;self.microphoneLevel=meterMicrophone ? level:0
                    }
                }
            }
            startSending(queue,id:id)
            if let after=testOnlyDisconnectAfter {
                verificationFault=Task { [weak self] in
                    try? await Task.sleep(nanoseconds:UInt64(after*1e9))
                    guard !Task.isCancelled,let self,self.runID == id,self.running else { return }
                    try? await self.logger?.record("verification.disconnect",fields:["after_seconds":after,"reconnect_delay_seconds":self.testOnlyReconnectDelay])
                    self.requestRecovery(redacted:"验收注入：主动断开当前测试连接")
                    try? await self.logger?.record("verification.recovery_controls",fields:["can_stop":self.canToggleRecording,"mode_changes_blocked":self.busy])
                }
            }
            return
        }
        let info = try await hardware.start(config, onlySystemPID: testOnlySystemPID)
        guard running && !stopping && runID == id else { await hardware.stop(); throw CancellationError() }
        let playbackLog = logger
        hardware.playbackEvent = { type,fields in Task { try? await playbackLog?.record(type,fields:fields) } }
        hardware.playbackEnabled = config.pipeline == .translate && config.translationMode == .speech
        if let logger { try await logger.record("audio.processing", fields: info) }
        processingDescription = "系统：\(config.systemNoiseSuppression ? "WebRTC 轻度降噪" : "原音") · 麦克风：\(config.microphoneEnabled ? (hardware.microphoneUsesNative ? "Apple 语音处理" : "NS／旁路") : "关闭")"
        let front = AudioFrontend(systemRing: hardware.systemRing, microphoneRing: hardware.microphoneRing, config: config, nativeMic: hardware.microphoneUsesNative, archive: logger?.audioArchive,
            notice: { [weak self] message in Task { @MainActor in
                guard let self, self.runID == id else { return }
                do { try await self.logger?.record("gap", fields: ["message": message]) } catch { await self.failLog() }
                if message.contains("发送队列已满") { self.errorMessage = "音频上传积压并出现缺口；请结束本次记录后检查连接。原始录音仍保存在本机。" }
                if message.hasPrefix("前端异常") { self.errorMessage = message; await self.stop() }
            } }, meter: { [weak self] system, microphone in Task { @MainActor in
                guard let self, self.runID == id else { return }; self.systemLevel = system; self.microphoneLevel = microphone
            } })
        frontend = front; try front.start()
        startSending(front.packets,id:id)
    }
    private func startSending(_ queue:AudioPacketQueue,id:UUID) {
        inputQueue=queue
        packetTask = Task { [weak self] in
            var reported = false
            for await _ in queue.signals {
              while !Task.isCancelled {
                guard let self, self.runID == id else { break }
                if let overflow=queue.takeOverflow() { await self.recordDiscarded(overflow,reason:"queue_capacity") }
                let expired=queue.discard(before:max(self.sendNotBefore,Date().timeIntervalSince1970-0.75))
                await self.recordDiscarded(expired,reason:"expired_or_before_reconnect")
                guard let packet=queue.takeBatch(maxPackets:5) else { break }
                guard let connection = self.connection else {
                    if !reported { try? await self.logger?.record("gap", fields: ["message": "重连期间音频已丢弃，恢复后只发送新声音"]) }; reported = true
                    await self.recordDiscarded([packet],reason:"disconnected");continue
                }
                let sendingEpoch=self.epoch
                do {
                    try await connection.sendAudio(packet.data, timing:packet.timing); reported = false
                    if let summary=self.pendingRecoverySummary,sendingEpoch>summary.epoch,self.epoch == sendingEpoch {
                        self.pendingRecoverySummary=nil
                        let samples=self.discardedInputSamples-summary.discardedBefore
                        do { try await self.logger?.record("gap",fields:["message":String(format:"重连完成：已丢弃 %.3f 秒未发送的旧音频，从当前声音继续；不补传。断线前已交给连接的尾段是否送达仍不确定。",Double(samples)/16000),"discarded_input_samples":samples,"previous_connection_epoch":summary.epoch,"replayed":false]) }
                        catch { Task { await self.failLog() };return }
                    }
                }
                catch is AudioArchiveFailure {
                    self.errorMessage = "录音保存失败，采集已停止；请检查目录权限和磁盘空间。"
                    Task { await self.stop() }; break
                }
                catch {
                    await self.recordDiscarded([packet],reason:"send_failed_consumption_unknown")
                    // A late failure from the old connection must not tear down its replacement.
                    if self.epoch == sendingEpoch && self.connection != nil {
                        if self.stopping { self.tailIncomplete=true }
                        else { self.requestRecovery(redacted: self.config.provider == .whisperKit ? self.redacted(error.localizedDescription) : "音频发送失败，正在重连") }
                    }
                }
              }
                if Task.isCancelled { break }
            }
        }
    }
    private func recordDiscarded(_ packets:[CapturedAudio],reason:String) async {
        guard let first=packets.first,let last=packets.last else { return }
        await recordDiscarded(DiscardedAudio(samples:packets.reduce(0) { $0+$1.data.count/2 },startedAt:first.timing.captureStartedAt,endedAt:last.timing.captureEndedAt),reason:reason)
    }
    private func recordDiscarded(_ summary:DiscardedAudio,reason:String) async {
        discardedInputSamples += summary.samples
        try? await logger?.record("input.discarded",fields:["reason":reason,"sample_count":summary.samples,
            "capture_started_at":SessionLog.timestamp(Date(timeIntervalSince1970:summary.startedAt)),
            "capture_ended_at":SessionLog.timestamp(Date(timeIntervalSince1970:summary.endedAt)),"replayed":false])
    }
    func waitForFileReplay() async { await fileReplayProducer?.value; await packetTask?.value }
}

// MARK: - 云连接与服务事件
extension AppSession {
    private func openConnection(config desired: Configuration, resuming: String?, change: Bool) async throws {
        guard let logger else { return }
        epochCounter += 1; let newEpoch = epochCounter; let id = runID
        try await logger.beginEpoch(newEpoch, configuration: desired)
        let new = Connections.make(configuration: desired, audioArchive: logger.audioArchive, epoch: newEpoch) { [weak self] event in
            await self?.receive(event, epoch: newEpoch, id: id, pipeline: desired.pipeline)
        }
        do { try await new.connect(handle: resuming) }
        catch { await new.close(); throw error }
        guard running && !stopping && runID == id else { await new.close(); throw CancellationError() }
        let old = connection; let oldEpoch = epoch
        if recoveryTask != nil {
            sendNotBefore=Date().timeIntervalSince1970
            await recordDiscarded(inputQueue?.discard(before:sendNotBefore) ?? [],reason:"reconnect_cutover")
            hardware.clearPlayback()
            try await logger.record("input.reconnected",fields:["connection_epoch":newEpoch,"accept_capture_from":SessionLog.timestamp(Date(timeIntervalSince1970:sendNotBefore)),"policy":"discard_old_audio_start_fresh"])
        }
        connection = new; epoch = newEpoch; resumeHandle = handles[newEpoch]
        try await logger.activateEpoch(newEpoch,configuration:desired)
        if change {
            try await logger.record("pipeline.changed", fields: ["message": "线路或连接已切换至 \(desired.pipeline.rawValue)", "connection_epoch": newEpoch])
            // Keep the last visible caption until the new epoch actually produces text.
        }
        if let old {
            drainTasks[oldEpoch] = Task { [weak self] in
                let complete = await old.finish(); await old.close()
                guard let self, self.runID == id else { return complete }
                if !complete {
                    self.tailIncomplete = true
                    try? await logger.record("gap",fields:["message":"旧连接结束未收到完整收尾确认，尾部可能不完整","connection_epoch":oldEpoch])
                }
                try? await logger.closeEpoch(oldEpoch)
                self.handles.removeValue(forKey:oldEpoch)
                self.drainTasks.removeValue(forKey:oldEpoch)
                return complete
            }
        }
        rotationTask?.cancel()
        rotationTask = nil
        guard let rotationSeconds=desired.scheduledConnectionRotationSeconds else {
            try await logger.record("connection.rotation_policy",fields:["scheduled":false,"reason":desired.provider == .whisperKit ? "Local recognition has no network session deadline" : "No verified LiveTranslate connection deadline; preserve classroom context and recover only on actual connection failure"])
            return
        }
        if verificationInProgress, ProcessInfo.processInfo.environment["LIVECAPTION_TEST_DISABLE_ROTATION"] == "1" {
            try await logger.record("verification.rotation_disabled",fields:["reason":"Measure uninterrupted context growth; production rotation policy is unchanged"])
            return
        }
        rotationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(rotationSeconds*1e9))
            guard !Task.isCancelled, let self, self.running else { return }
            await self.rotate()
        }
    }
    private func receive(_ event: ProviderEvent, epoch eventEpoch: Int, id: UUID, pipeline: Pipeline) async {
        guard runID == id, let logger else { return }
        do {
            switch event {
            case .text(let update):
                let transcript = try await logger.text(update, epoch: eventEpoch)
                lastCaptionAt = Date()
                let activeHasText = transcript.segments.contains { $0.epoch == epoch && !$0.text.isEmpty }
                if !invalidatedEpochs.contains(eventEpoch) && (eventEpoch == epoch || !activeHasText) {
                    let projectedAt=Date()
                    displayTranscript(transcript, epoch:eventEpoch, pipeline:pipeline)
                    let displayKey="\(eventEpoch):\(update.track):\(update.providerID ?? "unidentified")"
                    if displayedProviderItems.insert(displayKey).inserted {
                        try await logger.record("caption.first_projected",fields:["connection_epoch":eventEpoch,"track":update.track,
                            "provider_segment_id":update.providerID as Any? ?? NSNull(),"projection_ms":Date().timeIntervalSince(projectedAt)*1000,
                            "reflow_pending":captionReflow.pending])
                    }
                }
            case .audio(let data, let rate):
                if invalidatedEpochs.contains(eventEpoch) {
                    discardedOutputSamples += data.count/2
                    try await logger.record("playback.stale_discarded",fields:["connection_epoch":eventEpoch,"sample_count":data.count/2]);return
                }
                if audioStartedEpochs.insert(eventEpoch).inserted { try await logger.record("translation.audio.first_received",fields:["connection_epoch":eventEpoch,"sample_rate":rate]) }
                try logger.audioArchive.translated(data,rate:Int(rate))
                if eventEpoch == epoch && !stopping && !hardware.play(data, rate: rate) {
                    hardware.playbackEnabled = false; hardware.clearPlayback()
                    errorMessage = "译音超过播放缓冲上限或格式异常，已暂停播放；原始译音、字幕与日志继续保存。可重新选择同传恢复。"
                    try await logger.record("playback.dropped", fields: ["message": "播放缓冲溢出或格式异常","maximum_buffered_seconds":config.playbackCatchUp.maximumBufferedSeconds])
                }
            case .boundary: if pipeline == .translate { try await logger.closeEpoch(eventEpoch, providerBoundary: true) }
            case .resumption(let h): handles[eventEpoch] = h; if eventEpoch == epoch { resumeHandle = h }
            case .goAway: if eventEpoch == epoch && !busy && !stopping { Task { await self.rotate() } }
            case .usage(let data): try await logger.record("usage", fields: ["usage": data, "connection_epoch": eventEpoch])
            case .diagnostic(let type,let data):
                try await logger.record(type,fields:data.merging(["connection_epoch":eventEpoch]) { _,new in new })
                if type == "local.whisper.model_preparing",busy,let message=data["message"] as? String { status=message }
                if type == "local.whisper.ready",busy { status="本地模型已就绪" }
            case .error(let text): if eventEpoch == epoch && running && !busy && !stopping { requestRecovery(redacted: redacted(text)) }
            case .ready, .finished: break
            }
        } catch { await failLog() }
    }
}

// MARK: - 字幕与 SaT 设置
extension AppSession {
    func displayTranscript(_ transcript:Transcript, epoch:Int, pipeline:Pipeline) {
        lastCaptionSnapshot=(transcript,epoch,pipeline)
        sourceText = transcript.recentText(track:"source",epoch:epoch)
        translatedText = pipeline == .translate ? transcript.recentText(track:"translation",epoch:epoch) : ""
        // Capture this session's journal at job creation, so an old cancelled job cannot log
        // its response into the next session or a different connection's configuration.
        let log=logger ?? layoutLogger
        captionReflow.onTrace = { event in try await log?.reflowTrace(event) }
        captionReflow.update(transcript.captionParagraphs(epoch:epoch),configuration:config.captionReflow,context:"\(runID):\(epoch):\(pipeline.rawValue)")
    }
    func useLayoutLogger(_ log:SessionLog) { layoutLogger=log }
    /// This synchronous entry point is used by the actual UI switch. Disk and
    /// Keychain work must never delay cancellation or revert the runtime state.
    func setReflowEnabled(_ enabled:Bool,fileURL:URL?=nil) {
        var value=config.captionReflow;value.enabled=enabled
        do {
            if enabled { try value.validate() }
            let revision=applyReflowConfiguration(value,origin:"switch")
            queueReflowSave(value,revision:revision,url:fileURL ?? configurationURL)
        } catch { errorMessage="无法开启 SaT 整理："+config.redacted(error.localizedDescription) }
    }
    func setSaTConfiguration(_ sat:SaTReflowConfiguration,fileURL:URL?=nil) {
        var value=config.captionReflow;value.sat=sat
        let revision=applyReflowConfiguration(value,origin:"sat_parameters_autosave")
        queueReflowSave(value,revision:revision,url:fileURL ?? configurationURL,delay:250_000_000)
    }
    private func queueReflowSave(_ value:CaptionReflowConfiguration,revision:UInt64,url:URL,delay:UInt64=0) {
        reflowSettingsSave?.cancel()
        reflowSettingsSave=Task {
            do {
                if delay>0 { try await Task.sleep(nanoseconds:delay) }
                guard revision == reflowSettingsRevision,!Task.isCancelled else { return }
                try await persistReflowConfiguration(value,revision:revision,url:url)
            } catch is CancellationError { return }
            catch {
                guard revision == reflowSettingsRevision else { return }
                if !verificationInProgress,let date=try? url.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate {
                    fileDate=date;preferences.set(date,forKey:"last-config-date");savePreferences()
                }
                errorMessage="SaT 设置已生效，但自动保存失败："+config.redacted(error.localizedDescription)
            }
        }
    }
    @discardableResult private func applyReflowConfiguration(_ value:CaptionReflowConfiguration,origin:String)->UInt64 {
        let previous=config.captionReflow,hadPending=captionReflow.pending
        reflowSettingsRevision += 1
        config.captionReflow=value
        if previous != value || !value.enabled { captionReflow.cancel() }
        if !running && !verificationInProgress {
            reflowStatus=value.enabled ? "SaT 已开启，开始记录后整理":"未启用 · 按服务器语段显示"
        } else if let (transcript,epoch,pipeline)=lastCaptionSnapshot { displayTranscript(transcript,epoch:epoch,pipeline:pipeline) }
        else { captionReflow.update([],configuration:value,context:"settings:\(runID)") }
        savePreferences()
        let revision=reflowSettingsRevision,log=running ? logger:nil,snapshot=config
        Task {
            do {
                try await log?.changeConfiguration(snapshot,eventType:"caption.reflow.configuration_changed")
                try await log?.reflowTrace(CaptionReflowTrace("caption.reflow.control",[
                    "origin":origin,"revision":revision,"previous_enabled":previous.enabled,"enabled":value.enabled,
                    "engine":value.engine.rawValue,"sat_model":value.sat.model,"sat_threshold":value.sat.paragraphThreshold,"sat_minimum_characters":value.sat.minimumCharacters,"pending_work_cancelled":hadPending,"runtime_applied_immediately":true]))
            } catch { errorMessage="整理设置已生效，但行为日志写入失败。" }
        }
        feedback=value.enabled ? "后台整理已开启，正在自动保存。":"后台整理已关闭；原文、译文与日志继续。"
        return revision
    }
    private func persistReflowConfiguration(_ value:CaptionReflowConfiguration,revision:UInt64,url:URL) async throws {
        let date=try await reflowSettingsWriter.save(value,revision:revision,url:url)
        guard revision == reflowSettingsRevision,let date else { return }
        fileDate=date
        if !verificationInProgress { preferences.set(date,forKey:"last-config-date") }
        savePreferences()
        feedback=value.enabled ? "后台整理已开启并保存。":"后台整理已关闭并保存；原文、译文与日志继续。"
        if running {
            do { try await logger?.reflowTrace(CaptionReflowTrace("caption.reflow.configuration_saved",[
                "revision":revision,"enabled":value.enabled,"engine":value.engine.rawValue])) }
            catch { errorMessage="整理设置已保存，但行为日志写入失败。" }
        }
    }
    func saveReflowConfiguration(_ value:CaptionReflowConfiguration,fileURL:URL?=nil) async throws {
        if value.enabled { try value.validate() }
        let revision=applyReflowConfiguration(value,origin:"save_model_parameters")
        try await persistReflowConfiguration(value,revision:revision,url:fileURL ?? configurationURL)
    }
}

// MARK: - 线路与音源切换
extension AppSession {
    func changePipeline(_ pipeline: Pipeline) async {
        guard !busy && !stopping && pipeline != config.pipeline else { return }
        let previous = config; let previousEpoch = epoch; config.pipeline = pipeline; savePreferences()
        guard running else { return }
        hardware.clearPlayback(); hardware.playbackEnabled = false; resumeHandle = nil
        busy = true; status = "切换线路中"
        do {
            try await openConnection(config: config, resuming: nil, change: true)
            hardware.playbackEnabled = pipeline == .translate && config.translationMode == .speech
            status = pipeline == .transcribe ? "转写中" : "翻译中"; try await logger?.setState(status)
        } catch {
            config = previous; savePreferences(); errorMessage = "线路切换失败："+redacted(error.localizedDescription)
            if connection != nil && running && !stopping {
                epoch = previousEpoch; resumeHandle = handles[epoch]
                try? await logger?.activateEpoch(epoch,configuration:previous)
                status = previous.pipeline == .transcribe ? "转写中（切换未成功）" : "翻译中（切换未成功）"
                hardware.playbackEnabled = previous.pipeline == .translate && previous.translationMode == .speech
                try? await logger?.setState(status)
            } else { await stop() }
        }
        busy = false
    }
    func changeMode(_ mode: OutputMode) async {
        guard !busy && !stopping && config.translationMode != mode else { return }
        let previous = config; let previousEpoch = epoch
        config.translationMode = mode
        guard running else { savePreferences(); return }
        busy = true; status = "切换输出中"
        hardware.clearPlayback(); hardware.playbackEnabled = false
        do {
            // Qwen modalities are configured server-side, so subtitle-only must open a text-only session.
            try await openConnection(config:config,resuming:nil,change:true)
            savePreferences(); status = config.pipeline == .translate ? "翻译中" : "转写中"
            try await logger?.setState(status)
        } catch {
            config = previous; epoch = previousEpoch
            try? await logger?.activateEpoch(previousEpoch,configuration:previous)
            errorMessage = "输出切换失败："+redacted(error.localizedDescription)
            status = previous.pipeline == .translate ? "翻译中（切换未成功）" : "转写中"
        }
        hardware.playbackEnabled = config.pipeline == .translate && config.translationMode == .speech
        busy = false
    }
    func setAudioOption(_ keyPath:WritableKeyPath<Configuration,Bool>,_ value:Bool) {
        guard !busy,!stopping,config[keyPath:keyPath] != value else { return }
        config[keyPath:keyPath]=value
        savePreferences() // Persist synchronously, before another click can start a reload.
        Task { await changeInput() }
    }
    private func audioConfigurationChanged(_ engine:AVAudioEngine) {
        guard running,!busy,!stopping,!resumeWanted,engine === hardware.engine else { return }
        routeRecoveryTask?.cancel()
        routeRecoveryTask=Task { [weak self] in
            do { try await Task.sleep(nanoseconds:500_000_000) } catch { return }
            guard let self,!Task.isCancelled,self.running,!self.busy,!self.stopping,!self.resumeWanted,
                  engine === self.hardware.engine else { return }
            self.routeRecoveryTask=nil
            let needsRestart = !engine.isRunning
            if needsRestart {
                do {
                    // A route notification does not require recreating process taps.
                    // Resume the existing graph first; rebuild only if its format is invalid.
                    try self.hardware.resumeEngineAfterRouteChange()
                    self.audioEngineResumeCount += 1
                    try? await self.logger?.record("audio.route.settled",fields:["action":"resume_existing_engine",
                        "engine_running":engine.isRunning,"resume_count":self.audioEngineResumeCount])
                } catch { await self.changeInput(origin:"audio_route_format_changed") }
            } else {
                try? await self.logger?.record("audio.route.settled",fields:["action":"keep_running","engine_running":true])
            }
        }
    }
    func changeInput(origin:String="user") async {
        if origin == "user" { savePreferences() }
        guard running && !busy && !stopping else { return }
        routeRecoveryTask?.cancel();routeRecoveryTask=nil
        audioInputRestartCount += 1
        busy = true; frontend?.stop(); frontend = nil
        let packets = packetTask; packetTask = nil; packets?.cancel()
        try? await logger?.record("audio.input_rebuild.started",fields:["origin":origin,"restart_count":audioInputRestartCount])
        await hardware.stop(); await packets?.value
        do { try await logger?.changeConfiguration(config, eventType: "input.changed"); try await logger?.record("gap", fields: ["message": "音源配置变化，重建采集；该时间段可能有缺口"]); try await startAudio() }
        catch { errorMessage = redacted(error.localizedDescription); await stop() }
        busy = false
    }
}

// MARK: - 连接恢复与健康检查
extension AppSession {
    private func rotate() async {
        guard running && !busy && !stopping else { return }
        busy = true; status = "轮换连接中"
        do { try await openConnection(config: config, resuming: resumeHandle, change: true); status = config.pipeline == .transcribe ? "转写中" : "翻译中"; try await logger?.setState(status) }
        catch { requestRecovery(redacted: "连接轮换失败，正在重试") }
        if !reconnecting { busy = false }
    }
    private func requestRecovery(redacted message: String) {
        guard running && !stopping && recoveryTask == nil else { return }
        if config.provider == .whisperKit {
            tailIncomplete=true;errorMessage=message;busy=true
            Task { [weak self] in
                try? await self?.logger?.record("gap",fields:["message":message,"reason":"local_recognition_failed"])
                await self?.stop()
            }
            return
        }
        let recoveryRunID=runID
        busy=true;status = "正在重连"; errorMessage = message
        pendingRecoverySummary=(epoch,discardedInputSamples)
        invalidatedEpochs.insert(epoch);hardware.clearPlayback()
        resumeHandle=nil
        let old = connection; connection = nil
        recoveryTask = Task { [weak self] in
            await self?.recordDiscarded(self?.inputQueue?.discard(before:Date().timeIntervalSince1970) ?? [],reason:"connection_invalidated")
            if let old { self?.tailIncomplete = true; try? await self?.logger?.closeEpoch(self?.epoch ?? 0); await old.close() }
            guard let self else { return }
            try? await self.logger?.record("gap", fields: ["message": message])
            if self.verificationInProgress,self.testOnlyReconnectDelay>0 {
                try? await Task.sleep(nanoseconds:UInt64(self.testOnlyReconnectDelay*1e9))
            }
            var delay: UInt64 = 1
            while self.running && !self.stopping && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: delay*1_000_000_000)
                guard !Task.isCancelled else { break }
                do {
                    do { try await self.openConnection(config: self.config, resuming: self.resumeHandle, change: true) }
                    catch { self.resumeHandle = nil; throw error }
                    self.status = self.config.pipeline == .transcribe ? "转写中" : "翻译中"; self.errorMessage = nil
                    try await self.logger?.setState(self.status); break
                } catch {
                    let text = self.redacted(error.localizedDescription)
                    if ["API key", "PERMISSION", "permission", "not found", "not supported", "401", "403", "429", "quota", "Quota", "RESOURCE_EXHAUSTED", "INVALID_ARGUMENT", "UNAUTHENTICATED"].contains(where: text.contains) {
                        self.errorMessage = text; await self.stop(); break
                    }
                    delay = min(delay*2,15)
                }
            }
            if self.runID == recoveryRunID { self.recoveryTask = nil;self.busy=false }
        }
    }
    private func startHealthCheck() {
        healthTask?.cancel()
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled, let self else { return }
                do { try await self.logger?.checkHealth(); try await self.logger?.flush() } catch { await self.failLog(); return }
            }
        }
    }
    private func failLog() async { errorMessage = "日志写入失败，采集已停止；请检查目录权限与磁盘空间。"; await stop() }
}

// MARK: - 收尾与日志入口
extension AppSession {
    func stop() async {
        routeRecoveryTask?.cancel();routeRecoveryTask=nil
        guard !stopping else { return }
        stopping = true; busy = true; status = "正在收尾"
        verificationFault?.cancel();verificationFault=nil
        fileReplayProducer?.cancel(); fileReplayProducer=nil
        resumeWanted = false
        rotationTask?.cancel(); rotationTask = nil; healthTask?.cancel(); healthTask = nil
        recoveryTask?.cancel(); recoveryTask = nil
        frontend?.stop(); frontend = nil
        let packets = packetTask; packetTask = nil
        let drainTimeout=Task { [weak self] in
            try? await Task.sleep(nanoseconds:8_000_000_000)
            guard !Task.isCancelled,let self,self.stopping else { return }
            self.tailIncomplete=true;packets?.cancel()
            await self.recordDiscarded(self.inputQueue?.discard(before:.greatestFiniteMagnitude) ?? [],reason:"stop_drain_timeout")
            await self.connection?.close()
        }
        await hardware.stop(); await packets?.value
        drainTimeout.cancel();inputQueue=nil
        if let connection {
            let complete = await connection.finish(); await connection.close()
            try? await logger?.record("connection.final_finish",fields:["connection_epoch":epoch,"confirmed":complete])
            if !complete { tailIncomplete = true; try? await logger?.record("gap",fields:["message":"未收到完整收尾确认，末段可能不完整"]) }
        }
        connection = nil
        let pendingDrains = Array(drainTasks.values)
        for task in pendingDrains { if !(await task.value) { tailIncomplete = true } }
        drainTasks.removeAll()
        await captionReflow.finish()
        var finishedDirectory:URL?
        do { try await logger?.finish(tailIncomplete: tailIncomplete);finishedDirectory=logger?.directory } catch { errorMessage = "日志或录音收尾失败；已有文件保留在会话目录" }
        logger = nil; sessionEndedAt = Date(); running = false; busy = false; stopping = false; runID = UUID(); status = "已停止"
        logScopeURL?.stopAccessingSecurityScopedResource(); logScopeURL = nil
        systemLevel = 0; microphoneLevel = 0
        if let finishedDirectory { aiRecords.finished(directory:finishedDirectory) }
    }
    func chooseLogDirectory() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        config.logDirectory = url.path; savePreferences()
        if let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) { preferences.set(bookmark, forKey: "log-directory-bookmark") }
    }
    func copyCatchUpPrompt() {
        let root = currentDirectory?.deletingLastPathComponent().deletingLastPathComponent().path ?? config.logDirectory
        let prompt = "读取 \(root)/latest.json 指向的会话记录，先看 live.md，必要时查 transcript.md。告诉我刚才讲了什么、关键术语和当前正在讨论的问题，帮我接上当前讨论。标注记录更新时间、识别中的文字及缺失部分。"
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(prompt, forType: .string)
        announce("已复制 AI 接续提示")
    }
    func openRecord() { if let currentDirectory { NSWorkspace.shared.open(currentDirectory.appendingPathComponent("live.md")) } }
    private func redacted(_ text: String) -> String { config.redacted(text) }
}
