import SwiftUI
import AppKit
import LiveCaptionCore

@MainActor private final class CaptionPanel:NSPanel {
    override var canBecomeKey:Bool { true }
}

@MainActor final class OverlayController: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let passthroughControls:NSPanel
    private weak var session: AppSession?
    private var expandedFrame: NSRect
    init(session:AppSession) {
        self.session = session
        panel = CaptionPanel(contentRect:NSRect(x:0,y:0,width:820,height:180),styleMask:[.borderless,.nonactivatingPanel,.resizable],backing:.buffered,defer:false)
        panel.title = "LiveCaption 字幕"
        panel.acceptsMouseMovedEvents = true
        panel.level = .floating; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.stationary]
        panel.isMovableByWindowBackground = true; panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width:560,height:140)
        panel.contentView = NSHostingView(rootView:OverlayRootView(session:session))
        passthroughControls = NSPanel(contentRect:NSRect(x:0,y:0,width:430,height:40),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        passthroughControls.title = "LiveCaption 字幕控制"
        passthroughControls.level = NSWindow.Level(rawValue:NSWindow.Level.floating.rawValue+1)
        passthroughControls.isOpaque = false; passthroughControls.backgroundColor = .clear; passthroughControls.hasShadow = true
        passthroughControls.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        passthroughControls.hidesOnDeactivate = false; passthroughControls.ignoresMouseEvents = false
        passthroughControls.contentView = NSHostingView(rootView:PassthroughControlsView(session:session))
        expandedFrame = panel.frame
        super.init()
        panel.delegate = self
        let restored = panel.setFrameUsingName("LiveCaptionOverlayExpanded")
        if restored { keepOnScreen(); expandedFrame = panel.frame } else { resetPosition() }
    }
    private func keepOnScreen() {
        let screen = panel.screen ?? NSScreen.main
        guard let bounds = screen?.visibleFrame else { return }
        var frame = panel.frame
        frame.size.width = min(frame.width,bounds.width-24); frame.size.height = min(frame.height,bounds.height-24)
        frame.origin.x = min(max(bounds.minX+12,frame.minX),bounds.maxX-frame.width-12)
        frame.origin.y = min(max(bounds.minY+12,frame.minY),bounds.maxY-frame.height-12)
        panel.setFrame(frame,display:true)
    }
    func show() {
        guard let session else { return }
        if session.presentation == .compact {
            let current = panel.frame
            expandedFrame.origin = NSPoint(x:current.minX,y:current.maxY-expandedFrame.height)
        } else if session.presentation == .expanded && panel.isVisible { expandedFrame = panel.frame }
        session.presentation = .expanded; panel.styleMask.insert(.resizable)
        panel.minSize = NSSize(width:560,height:140)
        panel.setFrame(expandedFrame,display:true); keepOnScreen()
        panel.ignoresMouseEvents = session.passthrough; panel.orderFrontRegardless()
        syncPassthroughControls()
    }
    func collapse() {
        guard let session else { return }
        if session.presentation == .expanded { expandedFrame = panel.frame }
        session.presentation = .compact
        panel.styleMask.remove(.resizable); panel.minSize = NSSize(width:510,height:64)
        panel.setFrame(NSRect(x:panel.frame.minX,y:panel.frame.maxY-64,width:510,height:64),display:true)
        panel.ignoresMouseEvents = false; keepOnScreen(); panel.orderFrontRegardless()
        passthroughControls.orderOut(nil)
    }
    func hide() {
        if session?.presentation == .expanded { expandedFrame = panel.frame; if session?.verificationInProgress != true { panel.saveFrame(usingName:"LiveCaptionOverlayExpanded") } }
        else if session?.presentation == .compact { expandedFrame.origin = NSPoint(x:panel.frame.minX,y:panel.frame.maxY-expandedFrame.height) }
        session?.presentation = .hidden; panel.orderOut(nil)
        passthroughControls.orderOut(nil)
    }
    func setPassthrough(_ enabled:Bool) { panel.ignoresMouseEvents = enabled && session?.presentation == .expanded; syncPassthroughControls() }
    private func syncPassthroughControls() {
        guard session?.passthrough == true,session?.presentation == .expanded,panel.isVisible else { passthroughControls.orderOut(nil); return }
        let bounds = (panel.screen ?? NSScreen.main)?.visibleFrame ?? panel.frame
        let x = min(max(bounds.minX+8,panel.frame.maxX-430),bounds.maxX-438)
        let y = panel.frame.maxY+48 <= bounds.maxY ? panel.frame.maxY+8 : max(bounds.minY+8,panel.frame.minY-48)
        passthroughControls.setFrameOrigin(NSPoint(x:x,y:y)); passthroughControls.orderFrontRegardless()
    }
    func resetPosition() {
        guard let screen = NSScreen.main else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x:screen.visibleFrame.midX-size.width/2,y:screen.visibleFrame.minY+60))
        if session?.presentation != .compact { expandedFrame = panel.frame }
    }
    func windowDidResize(_ notification:Notification) { rememberExpandedFrame() }
    func windowDidMove(_ notification:Notification) { rememberExpandedFrame() }
    private func rememberExpandedFrame() {
        guard session?.presentation == .expanded else { return }
        expandedFrame = panel.frame; if session?.verificationInProgress != true { panel.saveFrame(usingName:"LiveCaptionOverlayExpanded") }
        syncPassthroughControls()
    }
    var frame:NSRect { panel.frame }
    var isVisible:Bool { panel.isVisible }
    var isInteractive:Bool { !panel.ignoresMouseEvents }
    var passthroughControlsVisible:Bool { passthroughControls.isVisible && !passthroughControls.ignoresMouseEvents }
}
