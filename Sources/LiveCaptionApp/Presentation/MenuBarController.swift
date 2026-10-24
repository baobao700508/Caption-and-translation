import AppKit
import SwiftUI
import Combine

/// Own the popover lifecycle so opening settings always dismisses the menu-bar panel first.
@MainActor final class MenuBarController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
    private let popover = NSPopover()
    private var detachedPanel:NSPanel?
    private weak var session: AppSession?
    private var observation: AnyCancellable?
    init(session: AppSession) {
        self.session = session
        super.init()
        popover.behavior = .transient; popover.animates = false
        popover.contentViewController = NSHostingController(rootView:QuickControlsView(session:session))
        if let button = item.button {
            button.target = self; button.action = #selector(togglePopover)
            button.sendAction(on:[.leftMouseUp,.rightMouseUp])
            button.setAccessibilityLabel("LiveCaption 菜单栏")
            button.setAccessibilityIdentifier("livecaption-menu-bar")
        }
        updateIcon()
        observation = session.$running.combineLatest(session.$status).sink { [weak self] _,_ in
            Task { @MainActor in self?.updateIcon() }
        }
    }
    private func updateIcon() {
        guard let session else { return }
        item.button?.image = NSImage(systemSymbolName:session.running ? "waveform.circle.fill" : "captions.bubble",accessibilityDescription:"LiveCaption")
        item.button?.image?.isTemplate = true
        item.button?.toolTip = "LiveCaption · \(session.status) · 点击打开控制面板，右键打开快捷菜单"
    }
    @objc private func togglePopover() {
        if NSApp.currentEvent?.type == .rightMouseUp { showContextMenu(); return }
        if popover.isShown { close() } else { show() }
    }
    func show() {
        detachedPanel?.orderOut(nil)
        guard let button = item.button else { return }
        popover.show(relativeTo:button.bounds,of:button,preferredEdge:.minY)
        popover.contentViewController?.view.window?.makeKey()
    }
    // 从字幕窗打开时不锚定 NSStatusItem，避免刘海屏挤出图标后无法操作。
    func showDetached() {
        close()
        guard let session else { return }
        if detachedPanel == nil {
            let panel=NSPanel(contentRect:NSRect(x:0,y:0,width:380,height:300),styleMask:[.titled,.closable,.nonactivatingPanel],backing:.buffered,defer:false)
            panel.title="LiveCaption 控制面板";panel.isReleasedWhenClosed=false
            panel.level = .floating;panel.hidesOnDeactivate=false
            panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
            panel.contentView=NSHostingView(rootView:QuickControlsView(session:session))
            panel.center();detachedPanel=panel
        }
        guard let panel=detachedPanel else { return }
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }) { panel.center() }
        panel.makeKeyAndOrderFront(nil)
    }
    func close() { popover.performClose(nil);detachedPanel?.orderOut(nil) }
    var isShown:Bool { popover.isShown || detachedPanel?.isVisible == true }
    var detachedIsVisible:Bool { detachedPanel?.isVisible == true }
    var diagnostics:[String:Any] {
        ["item_visible":item.isVisible,"button_present":item.button != nil,
         "button_frame":item.button.map { NSStringFromRect($0.frame) } ?? "none",
         "window_visible":item.button?.window?.isVisible ?? false,
         "window_frame":item.button?.window.map { NSStringFromRect($0.frame) } ?? "none"]
    }
    private func showContextMenu() {
        close()
        let menu = NSMenu()
        for (title,action) in [("展开字幕",#selector(expand)),("收起为迷你条",#selector(compact)),("设置…",#selector(settings))] {
            let entry = menu.addItem(withTitle:title,action:action,keyEquivalent:""); entry.target = self
        }
        menu.addItem(.separator())
        let update=menu.addItem(withTitle:"检查更新…",action:#selector(AppUpdater.checkForUpdates(_:)),keyEquivalent:""); update.target=AppUpdater.shared
        if session?.passthrough == true {
            let entry = menu.addItem(withTitle:"关闭鼠标穿透",action:#selector(recoverMouse),keyEquivalent:""); entry.target = self
        }
        let quit = menu.addItem(withTitle:"退出 LiveCaption",action:#selector(quitApp),keyEquivalent:""); quit.target = self
        item.menu = menu; item.button?.performClick(nil); item.menu = nil
    }
    @objc private func expand() { session?.showSubtitles() }
    @objc private func compact() { session?.collapseSubtitles() }
    @objc private func settings() { session?.showSettings() }
    @objc private func recoverMouse() { session?.passthrough = false; session?.showSubtitles() }
    @objc private func quitApp() { NSApp.terminate(nil) }
}
