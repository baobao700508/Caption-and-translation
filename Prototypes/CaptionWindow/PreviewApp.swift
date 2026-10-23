import AppKit
import SwiftUI

@MainActor final class PrototypePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor final class PreviewDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let session = DemoSession()
    private var gallery: NSWindow?
    private var panels: [Proposal: NSPanel] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let index = CommandLine.arguments.firstIndex(of: "--render-only"), CommandLine.arguments.count > index + 1 {
            do { try render(to: URL(fileURLWithPath: CommandLine.arguments[index + 1])); NSApp.terminate(nil) }
            catch { fputs("预览导出失败：\(error)\n", stderr); exit(1) }
            return
        }
        createMenu()
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: min(820, screen.height - 50)),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "字幕浮窗 · A / B / C 原型"
        window.acceptsMouseMovedEvents = true
        window.minSize = NSSize(width: 900, height: 770)
        window.contentView = NSHostingView(rootView: ProposalGallery(session: session) { [weak self] in self?.show($0) })
        window.center(); window.delegate = self; gallery = window
        window.makeKeyAndOrderFront(nil)
        session.startClock()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func show(_ proposal: Proposal) {
        if let panel = panels[proposal] { panel.makeKeyAndOrderFront(nil); return }
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let panel = PrototypePanel(contentRect: NSRect(x: screen.midX - 410, y: screen.minY + 80, width: 820, height: 180),
                                   styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        panel.title = "\(proposal.rawValue) · \(proposal.title) · 字幕原型"
        panel.acceptsMouseMovedEvents = true
        panel.level = .floating; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = true; panel.isMovableByWindowBackground = true; panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: 560, height: 140)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: CaptionProposal(proposal: proposal, session: session) { [weak self, weak panel] in
            panel?.orderOut(nil); self?.panels.removeValue(forKey: proposal)
        })
        panels[proposal] = panel; panel.makeKeyAndOrderFront(nil)
    }

    private func createMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu()
        let quit = NSMenuItem(title: "退出字幕原型", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenu.addItem(quit); appItem.submenu = appMenu; menu.addItem(appItem)
        let preview = NSMenuItem(); let options = NSMenu(title: "预览")
        for (i, proposal) in Proposal.allCases.enumerated() {
            let item = NSMenuItem(title: "打开 \(proposal.rawValue) · \(proposal.title)", action: #selector(openMenu(_:)), keyEquivalent: String(i + 1))
            item.target = self; item.representedObject = proposal.rawValue; options.addItem(item)
        }
        preview.submenu = options; menu.addItem(preview); NSApp.mainMenu = menu
    }
    @objc private func openMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let proposal = Proposal(rawValue: raw) else { return }
        show(proposal)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func render(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func save<V: View>(_ view: V, name: String, width: Double, height: Double) throws {
            // 原生菜单与 ScrollView 必须挂载 NSHostingView，不能用 ImageRenderer 的占位图。
            let frame = NSRect(x: 0, y: 0, width: width, height: height)
            let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: view.frame(width: width, height: height))
            window.contentView = host; window.orderBack(nil)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.12))
            host.displayIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                throw NSError(domain: "CaptionPreview", code: 1, userInfo: [NSLocalizedDescriptionKey: name])
            }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "CaptionPreview", code: 2) }
            try png.write(to: directory.appendingPathComponent(name + ".png"))
            window.orderOut(nil)
        }
        for proposal in Proposal.allCases {
            try save(CaptionProposal(proposal: proposal, session: session), name: proposal.rawValue, width: 820, height: 180)
        }
        try save(ProposalGallery(session: session, open: { _ in }), name: "comparison", width: 1000, height: 820)
        session.showCTools = true
        try save(CaptionProposal(proposal: .c, session: session), name: "C-controls", width: 820, height: 180)
        session.setScene(.long)
        for proposal in Proposal.allCases {
            try save(CaptionProposal(proposal: proposal, session: session), name: proposal.rawValue + "-narrow-long", width: 560, height: 180)
        }
        session.setScene(.empty)
        try save(CaptionProposal(proposal: .a, session: session), name: "empty", width: 560, height: 180)
        session.setScene(.reconnecting)
        try save(CaptionProposal(proposal: .b, session: session), name: "reconnecting", width: 820, height: 230)
        print("已导出 A、B、C、对照图与窄窗／长句／空状态／连接恢复预览。")
    }
}

@main struct PrototypeMain {
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(CommandLine.arguments.contains("--render-only") ? .prohibited : .regular)
        let delegate = PreviewDelegate(); application.delegate = delegate
        application.run(); withExtendedLifetime(delegate) {}
    }
}
