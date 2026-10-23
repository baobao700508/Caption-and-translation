import SwiftUI
import AppKit
import LiveCaptionCore

struct StatusIndicator: View {
    @ObservedObject var session: AppSession
    var body: some View {
        HStack(spacing:6) {
            if session.busy { ProgressView().controlSize(.small) }
            else { Circle().fill(session.errorMessage != nil ? Color.orange : (session.running ? Color.teal : Color.secondary)).frame(width:7,height:7).accessibilityHidden(true) }
            Text(session.configurationLoading && !session.running ? "正在读取配置…" : session.status).lineLimit(1)
        }.font(.caption).accessibilityElement(children:.combine)
    }
}
struct SessionDuration: View {
    @ObservedObject var session: AppSession
    var body: some View {
        TimelineView(.periodic(from:.now,by:1)) { context in
            let seconds = max(0,Int((session.running ? context.date : (session.sessionEndedAt ?? context.date)).timeIntervalSince(session.sessionStartedAt ?? context.date)))
            Text(String(format:"%02d:%02d:%02d",seconds/3600,seconds/60%60,seconds%60)).monospacedDigit().font(.caption).foregroundStyle(.secondary).accessibilityLabel("本次记录时长")
        }
    }
}
// 所有用户发起的结束按钮共用确认行为；后台收尾与重连不经过此弹窗。
struct RecordingConfirmation:ViewModifier {
    @ObservedObject var session:AppSession
    @Binding var isPresented:Bool
    func body(content:Content)->some View {
        content.alert("结束本次记录？",isPresented:$isPresented) {
            Button("继续记录",role:.cancel) {}
            Button("结束记录",role:.destructive) {
                guard session.running,session.canToggleRecording else { return }
                session.toggleRecording()
            }
        } message: {
            Text("结束后将停止收音、翻译和字幕更新，已有字幕与会话日志保留。")
        }
    }
}
struct RecordingButton: View {
    @ObservedObject var session: AppSession
    var iconOnly = false
    @State private var confirmingStop = false
    var body: some View {
        Group {
            if iconOnly {
                Button(action:requestAction) {
                    Image(systemName:session.running ? "stop.fill":"play.fill").frame(width:24,height:24)
                }.buttonStyle(.plain).help(session.primaryActionTitle)
            } else {
                Button(action:requestAction) {
                    Label(session.primaryActionTitle,systemImage:session.running ? "stop.fill":"record.circle")
                }.buttonStyle(.borderedProminent).tint(session.running ? .orange:.teal).fixedSize()
            }
        }.disabled(!session.canToggleRecording).accessibilityLabel(session.primaryActionTitle)
            .accessibilityIdentifier("recording-toggle")
            .modifier(RecordingConfirmation(session:session,isPresented:$confirmingStop))
    }
    private func requestAction() {
        if session.running { confirmingStop=true } else { session.toggleRecording() }
    }
}
struct ModeSelector: View {
    @ObservedObject var session: AppSession
    var body: some View {
        Picker("记录模式",selection:Binding(get:{session.recordingMode},set:{ mode in Task { await session.selectMode(mode) } })) {
            ForEach(RecordingMode.allCases) { mode in Text(mode.title).tag(mode) }
        }.pickerStyle(.segmented).disabled(session.busy || session.configurationLoading)
    }
}
struct LayoutSelector: View {
    @ObservedObject var session: AppSession
    var body: some View {
        Picker("字幕内容",selection:$session.config.subtitleLayout) {
            Text("原文").tag(SubtitleLayout.source); Text("译文").tag(SubtitleLayout.translation); Text("双语").tag(SubtitleLayout.bilingual)
        }.pickerStyle(.segmented).onChange(of:session.config.subtitleLayout) { _,_ in session.preferencesChanged() }
    }
}
struct SessionNotice: View {
    @ObservedObject var session: AppSession
    var body: some View {
        if let error = session.errorMessage ?? session.configurationProblem {
            VStack(alignment:.leading,spacing:8) {
                Label(error,systemImage:"exclamationmark.triangle").font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                if !session.running { Button("检查配置与连接…") { session.showSettings(.records) }.controlSize(.small) }
            }.frame(maxWidth:.infinity,alignment:.leading).padding(10).background(.orange.opacity(0.08),in:RoundedRectangle(cornerRadius:9))
        }
    }
}
