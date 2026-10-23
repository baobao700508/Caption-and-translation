import SwiftUI
import AppKit
import LiveCaptionCore

struct LocalModelsSettings:View {
    @ObservedObject var session:AppSession
    @ObservedObject var models:LocalModelManager
    var body:some View {
        Group {
            Section("按需下载") {
                Text("App 不附带 SaT 和 Whisper 模型。不使用本地功能时无需下载；下载准备完成后可以离线运行，不会在使用中临时安装依赖。")
                    .font(.callout)
                Text("文件保存在用户资料目录，更新或移动 App 不会重复下载。SaT 的 Python 与依赖由 App 独立管理，不修改系统环境。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("SaT · 本机字幕整理") {
                Picker("模型",selection:CaptionReflowSettings.parameterBinding(session:session,\.model)) {
                    ForEach(SaTReflowConfiguration.models,id:\.self) { Text($0).tag($0) }
                }.disabled(models.sat.active || session.running)
                Text("首次下载同时准备 Python、依赖、模型和分词器。默认 sat-3l 的模型约 428 MB，分词器约 14 MB；另需运行环境空间，建议预留 2 GB。不同 SaT 模型共用运行环境。")
                    .font(.caption).foregroundStyle(.secondary)
                ModelDownloadControls(state:models.sat,id:"sat",install:{ models.installSaT(session.config.captionReflow.sat) },cancel:models.cancelSaT)
                    .disabled(session.running || session.busy)
                Text("下载不会自动开启字幕整理。准备完成后，在“字幕与外观”开启“后台整理字幕”。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Whisper · 本机原文转写") {
                LabeledContent("模型",value:session.config.localWhisper.model == LocalWhisperConfiguration().model ? "Whisper Turbo（large-v3）":session.config.localWhisper.model)
                Text("默认 Turbo 模型安装后约 1.5 GB，建议预留 3 GB；不需要 Python。下载包含分词器，完成后验证本机 GPU 识别。")
                    .font(.caption).foregroundStyle(.secondary)
                ModelDownloadControls(state:models.whisper,id:"whisper",install:{ models.installWhisper(session.config.localWhisper) },cancel:models.cancelWhisper)
                    .disabled(session.running || session.busy)
                Text("准备完成后，在“模式与音源”选择“原文转写 → Whisper 本地”。本地原文转写不需要云端 API Key。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("存储与安装记录") {
                Text(LocalModelFiles.root.path).font(.caption).textSelection(.enabled)
                Button("打开模型文件夹") {
                    try? FileManager.default.createDirectory(at:LocalModelFiles.root,withIntermediateDirectories:true)
                    NSWorkspace.shared.open(LocalModelFiles.root)
                }
                Text("下载失败时可以重试；只有文件完整且实际运行验证通过后，才显示为可用。云端翻译与 Google 在线转写不需要下载这些模型。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.onAppear { models.refresh(session.config) }
            .onChange(of:session.config.captionReflow.sat.model) { _,_ in models.refresh(session.config) }
    }
}

private struct ModelDownloadControls:View {
    let state:ModelDownloadState
    let id:String
    let install:()->Void
    let cancel:()->Void
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            Label(state.message,systemImage:state.ready ? "checkmark.circle.fill":(state.active ? "arrow.down.circle":"externaldrive"))
                .font(.callout).textSelection(.enabled).accessibilityIdentifier(id+"-download-status")
            if state.active {
                if let fraction=state.fraction { ProgressView(value:fraction) }
                else { ProgressView().controlSize(.small) }
            }
            HStack {
                if state.active { Button("取消",action:cancel).accessibilityIdentifier(id+"-download-cancel") }
                else { Button(state.ready ? "检查并修复":"下载并准备",action:install).accessibilityIdentifier(id+"-download") }
                if let log=state.log { Button("安装日志") { NSWorkspace.shared.open(log) } }
            }
        }
    }
}
