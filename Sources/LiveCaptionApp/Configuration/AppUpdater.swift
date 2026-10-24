import AppKit
import Combine
import Sparkle
import SwiftUI

@MainActor final class AppUpdater: NSObject, ObservableObject, NSMenuItemValidation {
    static let shared = AppUpdater()
    @Published private(set) var canCheckForUpdates = false
    private let controller = SPUStandardUpdaterController(startingUpdater:false,updaterDelegate:nil,userDriverDelegate:nil)
    private var observation:AnyCancellable?
    static var version:String {
        let info=Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "—")（build \(info["CFBundleVersion"] as? String ?? "—")）"
    }
    private override init() {
        super.init()
        observation=controller.updater.publisher(for:\.canCheckForUpdates)
            .receive(on:RunLoop.main).sink { [weak self] in self?.canCheckForUpdates=$0 }
    }
    func start() {
        // 验证程序不启动更新器，不访问发布源或修改更新偏好。
        guard !CommandLine.arguments.contains(where:{$0.hasPrefix("--verify-")}) else { return }
        controller.startUpdater()
    }
    @objc func checkForUpdates(_ sender:Any? = nil) {
        guard canCheckForUpdates, !AppSession.shared.running, !AppSession.shared.busy else { return }
        NSApp.activate(ignoringOtherApps:true)
        controller.checkForUpdates(sender)
    }
    func validateMenuItem(_ menuItem:NSMenuItem) -> Bool {
        canCheckForUpdates && !AppSession.shared.running && !AppSession.shared.busy
    }
}

struct UpdateControls:View {
    @ObservedObject var session:AppSession
    @ObservedObject var updater:AppUpdater
    var body:some View {
        VStack(alignment:.leading,spacing:6) {
            Text(AppUpdater.version).font(.caption2).foregroundStyle(.secondary)
                .accessibilityIdentifier("app-version")
            Button("检查更新…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates || session.running || session.busy)
                .accessibilityIdentifier("check-for-updates")
            if session.running { Text("结束记录后可更新").font(.caption2).foregroundStyle(.secondary) }
        }.padding(.horizontal,12).padding(.bottom,8)
    }
}
