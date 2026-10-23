import AppKit
import SwiftUI
import LiveCaptionCore

enum RecordingMode: String, CaseIterable, Identifiable {
    case transcribe, subtitles, interpretation
    var id: String { rawValue }
    var title: String { switch self { case .transcribe: "原文转写"; case .subtitles: "书面同译"; case .interpretation: "同声传译" } }
    var shortTitle: String { switch self { case .transcribe: "转写"; case .subtitles: "同译"; case .interpretation: "同传" } }
    var detail: String { switch self { case .transcribe: "只记录原文，不翻译、不播放声音"; case .subtitles: "只生成原文和译文字幕，不生成译音"; case .interpretation: "实时翻译成字幕，并播放译音" } }
}
enum CaptionPresentation: String { case expanded, compact, hidden }
enum SettingsSection: String, CaseIterable, Identifiable {
    case session, appearance, audio, records
    var id: String { rawValue }
    var title: String { switch self { case .session: "模式与音源"; case .appearance: "字幕与外观"; case .audio: "音频处理"; case .records: "记录与连接" } }
    var icon: String { switch self { case .session: "waveform"; case .appearance: "textformat.size"; case .audio: "slider.horizontal.3"; case .records: "folder" } }
}

@MainActor final class PreferencesWindowController {
    private let window: NSWindow
    init(session: AppSession) {
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:820,height:620),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title = "LiveCaption 设置"; window.isReleasedWhenClosed = false
        window.minSize = NSSize(width:740,height:540)
        window.contentView = NSHostingView(rootView:PreferencesView(session:session))
        window.setFrameAutosaveName("LiveCaptionPreferences")
        if !window.setFrameUsingName("LiveCaptionPreferences") { window.center() }
    }
    func show() {
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(window.frame) }) { window.center() }
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps:true); window.makeKeyAndOrderFront(nil)
    }
    func close() { window.close() }
    var isVisible: Bool { window.isVisible && !window.isMiniaturized }
}

extension AppSession {
    var recordingMode: RecordingMode { config.pipeline == .transcribe ? .transcribe : (config.translationMode == .speech ? .interpretation : .subtitles) }
    var configurationProblem: String? {
        if configurationLoading { return nil }
        guard configurationReady else { return "请先选择配置文件，完成服务连接设置。" }
        do { try config.validate(); return nil } catch { return config.redacted(error.localizedDescription) }
    }
    var canToggleRecording: Bool { (running && reconnecting) || (!busy && !configurationLoading && (running || (configurationReady && configurationProblem == nil))) }
    var primaryActionTitle: String { running && reconnecting ? "结束记录" : (busy ? (running ? "处理中…" : "正在准备…") : (running ? "结束记录" : "开始记录")) }
    var sourceSummary: String {
        if config.systemAudioEnabled && config.microphoneEnabled { return "电脑声音＋麦克风" }
        if config.systemAudioEnabled { return config.applicationBundleID.isEmpty ? "电脑播放声音" : "指定应用声音" }
        return config.microphoneEnabled ? "麦克风" : "未选择音源"
    }
    var connectionSummary: String {
        guard configurationReady else { return configurationLoading ? "正在读取配置…" : "配置未就绪" }
        let region = config.bailianRegion == .beijing ? "北京" : "新加坡"
        return config.providerName + (config.provider == .bailian ? " · "+region : "")
    }
    func selectMode(_ mode: RecordingMode) async {
        guard !busy else { return }
        if mode == .transcribe { await changePipeline(.transcribe) }
        else if config.pipeline == .translate { await changeMode(mode == .interpretation ? .speech : .subtitles) }
        else {
            let previous = config.translationMode
            config.translationMode = mode == .interpretation ? .speech : .subtitles
            await changePipeline(.translate)
            if config.pipeline != .translate { config.translationMode = previous; preferencesChanged() }
        }
    }
    func toggleRecording() { menuBar?.close(); Task { if running { await stop() } else { await start() } } }
    func showSettings(_ section: SettingsSection? = nil) {
        menuBar?.close()
        if let section { settingsSection = section }
        if preferencesWindow == nil { preferencesWindow = PreferencesWindowController(session:self) }
        preferencesWindow?.show()
    }
    func showSubtitles() {
        menuBar?.close()
        if overlay == nil { overlay = OverlayController(session:self) }
        overlay?.show()
    }
    func collapseSubtitles() {
        menuBar?.close()
        if overlay == nil { overlay = OverlayController(session:self) }
        overlay?.collapse()
    }
    func revealLogs() {
        let directory = currentDirectory ?? URL(fileURLWithPath:(config.logDirectory as NSString).expandingTildeInPath)
        if FileManager.default.fileExists(atPath:directory.path) { NSWorkspace.shared.open(directory) }
        else { showSettings(.records); announce("首次开始记录时，会自动创建日志目录。") }
    }
    func announce(_ message: String) {
        feedback = message
        Task { [weak self] in
            try? await Task.sleep(nanoseconds:3_000_000_000)
            if self?.feedback == message { self?.feedback = nil }
        }
    }
}
