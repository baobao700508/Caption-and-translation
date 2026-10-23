import SwiftUI
import AppKit
import LiveCaptionCore

@main enum LiveCaptionApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = ApplicationDelegate()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
@MainActor final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    let session = AppSession.shared
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMenus()
        session.menuBar = MenuBarController(session:session)
        session.overlay = OverlayController(session: session); session.overlay?.show()
        let args = CommandLine.arguments
        if args.contains("--verify-onboarding") {
            // Interactive verification uses LIVECAPTION_MODEL_HOME for isolation.
            session.verificationInProgress=true;session.config=Configuration();session.configurationReady=false
            session.showSettings(.session)
        } else if let index = args.firstIndex(of:"--verify-caption-reflow"),args.count>index+3 {
            session.overlay?.hide()
            Task {
                await CaptionReflowSmoke.run(output:args[index+1],configurationPath:args[index+2],fixturePath:args[index+3],session:session)
                if args.contains("--verification-exit") { NSApp.terminate(nil) }
            }
        } else if let index = args.firstIndex(of:"--verify-caption-layout"),args.count>index+1 {
            session.overlay?.hide()
            Task {
                await CaptionLayoutSmoke.run(output:args[index+1],session:session)
                if args.contains("--verification-exit") { NSApp.terminate(nil) }
            }
        } else if let index = args.firstIndex(of:"--verify-file"),args.count>index+3 {
            session.overlay?.hide()
            Task {
                await FileReplaySmoke.run(fixture:args[index+1],output:args[index+2],configurationPath:args[index+3],speech:args.contains("--file-speech"),session:session)
                if args.contains("--verification-exit") { NSApp.terminate(nil) }
            }
        } else if let index = args.firstIndex(of:"--verify-interface"), args.count > index+1 {
            Task {
                await InterfaceSmoke.run(output:args[index+1],session:session)
                if args.contains("--verification-exit") { NSApp.terminate(nil) }
            }
        } else if let index = args.firstIndex(of:"--verify-microphone"), args.count > index+1 {
            Task {
                await MicrophoneSmoke.run(output:args[index+1],rawComparison:args.contains("--compare-raw-microphone"),session:session)
                if args.contains("--verification-exit") { NSApp.terminate(nil) }
            }
        } else if let index = args.firstIndex(of:"--verify-latency"), args.count > index+3 {
            Task {
                await LatencySmoke.run(fixture:args[index+1],output:args[index+2],configurationPath:args[index+3],speech:args.contains("--latency-speech"),session:session)
                if args.contains("--verification-exit") { NSApp.terminate(nil) }
            }
        } else if let index = args.firstIndex(of:"--verify-classroom"), args.count > index+3 {
            Task {
                let configIndex = args.firstIndex(of:"--verification-config")
                let configPath = configIndex.flatMap { args.count > $0+1 ? args[$0+1] : nil }
                await ClassroomSmoke.run(fixture:args[index+1],output:args[index+2],pipeline:Pipeline(rawValue:args[index+3]) ?? .transcribe,configurationPath:configPath,exerciseSwitches:args.contains("--verify-switches"),session:session)
                if args.contains("--verification-exit") { NSApp.terminate(nil) }
            }
        } else { Task {
            await session.reloadConfiguration(preservePreferences: true)
            if !session.configurationReady { session.showSettings() }
        } }
        if let index = args.firstIndex(of: "--verify-launch"), args.count > index+1 {
            let path = args[index+1]
            DispatchQueue.main.asyncAfter(deadline: .now()+1) { [self] in
                let panels = NSApp.windows.filter { $0 is NSPanel && $0.isVisible }
                let evidence: [String: Any] = ["event_loop_responsive": true, "visible_panels": panels.count,"configuration_ready":session.configurationReady,"recording_active":session.running,"provider":session.config.provider.rawValue,"model":session.config.model,"pipeline":session.config.pipeline.rawValue,"status":session.status,"default_transport":session.config.provider == .whisperKit ? "local_coreml_gpu":(session.config.provider == .bailian ? "native_webrtc_opus":"websocket"), "scope": "应用内部启动和窗口状态；不等同于视觉与交互验收"]
                if let data = try? JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted,.sortedKeys]) { try? data.write(to:URL(fileURLWithPath:path),options:.atomic) }
            }
        }
        if let index = args.firstIndex(of: "--verify-audio"), args.count > index+2 {
            Task { await AudioSmoke.run(fixture: args[index+1], output: args[index+2], session: session) }
        }
    }
    private func installMenus() {
        let root = NSMenu()
        let appMenu = NSMenu(title:"LiveCaption")
        appMenu.addItem(withTitle:"关于 LiveCaption",action:#selector(NSApplication.orderFrontStandardAboutPanel(_:)),keyEquivalent:"")
        appMenu.addItem(.separator())
        let preferences = appMenu.addItem(withTitle:"设置…",action:#selector(openSettings),keyEquivalent:","); preferences.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle:"隐藏 LiveCaption",action:#selector(NSApplication.hide(_:)),keyEquivalent:"h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle:"退出 LiveCaption",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        root.addItem(withTitle:"LiveCaption",action:nil,keyEquivalent:"").submenu = appMenu
        let edit = NSMenu(title:"编辑")
        for (title,action,key) in [("撤销","undo:","z"),("剪切","cut:","x"),("复制","copy:","c"),("粘贴","paste:","v"),("全选","selectAll:","a")] {
            edit.addItem(withTitle:title,action:Selector(action),keyEquivalent:key)
        }
        root.addItem(withTitle:"编辑",action:nil,keyEquivalent:"").submenu = edit
        let captions = NSMenu(title:"字幕")
        let expand = captions.addItem(withTitle:"展开字幕",action:#selector(expandCaptions),keyEquivalent:"s"); expand.target = self; expand.keyEquivalentModifierMask = [.command,.shift]
        let compact = captions.addItem(withTitle:"收起为迷你控制条",action:#selector(compactCaptions),keyEquivalent:"m"); compact.target = self; compact.keyEquivalentModifierMask = [.command,.shift]
        let records = captions.addItem(withTitle:"打开课堂记录",action:#selector(openRecords),keyEquivalent:""); records.target = self
        root.addItem(withTitle:"字幕",action:nil,keyEquivalent:"").submenu = captions
        let windows = NSMenu(title:"窗口")
        windows.addItem(withTitle:"最小化",action:#selector(NSWindow.performMiniaturize(_:)),keyEquivalent:"m")
        windows.addItem(withTitle:"缩放",action:#selector(NSWindow.performZoom(_:)),keyEquivalent:"")
        root.addItem(withTitle:"窗口",action:nil,keyEquivalent:"").submenu = windows
        NSApp.mainMenu = root; NSApp.windowsMenu = windows
    }
    @objc private func openSettings() { session.showSettings() }
    @objc private func expandCaptions() { session.showSubtitles() }
    @objc private func compactCaptions() { session.collapseSubtitles() }
    @objc private func openRecords() { session.revealLogs() }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool) -> Bool {
        session.showSettings(); return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        session.localModels.cancelAll()
        guard session.running else { return .terminateNow }
        Task { await session.stop(); NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
