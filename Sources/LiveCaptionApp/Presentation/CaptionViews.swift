import SwiftUI
import AppKit
import LiveCaptionCore

/// The menu bar is a quick control surface; detailed preferences live in their own window.
struct QuickControlsView: View {
    @ObservedObject var session: AppSession
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {
                Label("LiveCaption",systemImage:"captions.bubble.fill").font(.headline)
                Spacer(); Button { session.showSettings() } label: { Image(systemName:"gearshape") }.help("打开设置（⌘,）").accessibilityLabel("打开设置")
            }
            HStack { StatusIndicator(session:session); Spacer(); if session.sessionStartedAt != nil { SessionDuration(session:session) } }
            ModeSelector(session:session).labelsHidden()
            Text(session.recordingMode.detail).font(.caption).foregroundStyle(.secondary)
            HStack { Label(session.sourceSummary,systemImage:"waveform"); Spacer(); Button("更改…") { session.showSettings(.session) } }.font(.caption)
            if session.config.pipeline == .translate { LayoutSelector(session:session).labelsHidden() }
            SessionNotice(session:session)
            HStack {
                RecordingButton(session:session)
                Spacer()
                Button(session.presentation == .expanded ? "收起字幕" : "展开字幕") {
                    if session.presentation == .expanded { session.collapseSubtitles() } else { session.showSubtitles() }
                }.help("仅改变窗口大小，不影响记录")
            }
            if session.passthrough {
                Button("关闭鼠标穿透，恢复浮窗操作") { session.passthrough = false; session.showSubtitles() }.font(.caption)
            }
            Divider()
            HStack {
                Button("打开记录") { session.revealLogs() }
                Button("回听录音") { session.showSettings(.records) }
                Button("AI 接续",action:session.copyCatchUpPrompt).disabled(session.currentDirectory == nil)
                Spacer(); Button("设置…") { session.showSettings() }
            }.font(.caption)
            if let feedback = session.feedback { Text(feedback).font(.caption).foregroundStyle(.teal) }
            HStack { Text(session.connectionSummary).font(.caption2).foregroundStyle(.secondary); Spacer(); Button("退出") { NSApp.terminate(nil) }.font(.caption) }
        }.padding(18).frame(width:380).background(Color(nsColor:.windowBackgroundColor)).environment(\.controlActiveState,.active)
    }
}

private struct FloatingIconButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    var body: some View {
        Button(action:action) { Image(systemName:symbol).frame(width:30,height:30).contentShape(Rectangle()) }
            .buttonStyle(.plain).background(.white.opacity(0.08),in:RoundedRectangle(cornerRadius:7))
            .help(title).accessibilityLabel(title)
    }
}
struct CaptionView: View {
    @ObservedObject var session: AppSession
    @State private var hovering = false
    @State private var confirmingStop = false
    private var controlsVisible:Bool { hovering || session.sessionStartedAt == nil }
    private var statusColor:Color { session.errorMessage != nil ? .orange : (session.running ? .teal : .gray) }
    var body: some View {
        Group {
            if session.sessionStartedAt == nil {
                VStack(alignment:.leading,spacing:10) {
                    Text(session.configurationLoading ? "正在准备 LiveCaption" : "准备好开始记录").font(.title3.weight(.semibold))
                    Text("\(session.recordingMode.title) · \(session.sourceSummary)").font(.callout).foregroundStyle(.secondary)
                    Text("字幕可收起为迷你条，会话文字会持续写入本机日志。").font(.caption).foregroundStyle(.secondary)
                    if let problem = session.configurationProblem { Text(problem).font(.caption).foregroundStyle(.orange).lineLimit(2) }
                }.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.leading).padding(18)
            } else {
                CaptionTranscriptView(session:session)
            }
        }.padding(.trailing,34)
            .frame(maxWidth:.infinity,maxHeight:.infinity)
            .background(Color.black.opacity(session.overlayOpacity),in:RoundedRectangle(cornerRadius:11))
            .overlay(alignment:.leading) {
                Capsule().fill(statusColor.opacity(0.8)).frame(width:2,height:20).padding(.leading,5)
                    .accessibilityLabel(session.status)
            }
            .overlay(alignment:.trailing) {
                VStack(spacing:5) {
                    VStack(spacing:5) {
                        RecordingButton(session:session,iconOnly:true)
                        Menu { moreActions } label: { Image(systemName:"ellipsis").frame(width:24,height:24) }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                            .help("更多字幕操作").accessibilityLabel("更多字幕操作")
                    }.opacity(controlsVisible ? 1:0).allowsHitTesting(controlsVisible).accessibilityHidden(!controlsVisible)
                    Button { session.showSettings() } label: { Image(systemName:"gearshape").frame(width:24,height:24) }
                        .buttonStyle(.plain).help("打开设置（⌘,）").accessibilityLabel("打开设置")
                }.padding(3).background(.white.opacity(controlsVisible ? 0.055:0),in:RoundedRectangle(cornerRadius:9))
                    .padding(.trailing,6)
            }
            .overlay(alignment:.bottomLeading) {
                if let feedback=session.feedback {
                    Text(feedback).font(.caption2).padding(.horizontal,9).padding(.vertical,5)
                        .background(.black.opacity(0.88),in:Capsule()).padding(8).allowsHitTesting(false)
                }
            }
            .overlay(RoundedRectangle(cornerRadius:11).stroke(.white.opacity(0.14),lineWidth:0.7))
            .clipShape(RoundedRectangle(cornerRadius:11))
            .contentShape(Rectangle())
            .onHover { hovering=$0 }
            .onTapGesture { hovering=true }
            .contextMenu { moreActions }
            .modifier(RecordingConfirmation(session:session,isPresented:$confirmingStop))
            .foregroundStyle(.white.opacity(0.8)).preferredColorScheme(.dark)
    }
    @ViewBuilder private var moreActions:some View {
        if session.config.pipeline == .translate {
            Picker("字幕内容",selection:Binding(get:{session.config.subtitleLayout},set:{ session.config.subtitleLayout=$0;session.preferencesChanged() })) {
                Text("原文").tag(SubtitleLayout.source); Text("译文").tag(SubtitleLayout.translation); Text("双语").tag(SubtitleLayout.bilingual)
            }
        }
        Button("打开菜单栏控制面板…") { session.menuBar?.showDetached() }
        Button("打开设置…") { session.showSettings() }
        Divider()
        Button("收起为迷你控制条（记录继续）") { session.collapseSubtitles() }
        Button("打开会话记录") { session.revealLogs() }
        Button("回听录音…") { session.showSettings(.records) }
        Button("AI 接续",action:session.copyCatchUpPrompt).disabled(session.currentDirectory == nil)
        Button("重置字幕位置") { session.overlay?.resetPosition() }
        Toggle("字幕鼠标穿透",isOn:$session.passthrough)
        Divider()
        Button(session.primaryActionTitle) {
            if session.running { confirmingStop=true } else { session.toggleRecording() }
        }.disabled(!session.canToggleRecording)
        Button("隐藏到菜单栏（记录继续）") { session.overlay?.hide() }
    }
}
struct PassthroughControlsView: View {
    @ObservedObject var session:AppSession
    var body:some View {
        HStack(spacing:12) {
            Label("字幕穿透中",systemImage:"cursorarrow.rays").font(.caption)
            Button("恢复字幕操作") { session.passthrough = false }.controlSize(.small)
            Button("收起字幕") { session.collapseSubtitles() }.controlSize(.small)
            Button { session.showSettings() } label: { Image(systemName:"gearshape") }.accessibilityLabel("打开设置")
        }.padding(.horizontal,12).frame(height:40).background(.black.opacity(0.94),in:RoundedRectangle(cornerRadius:10)).preferredColorScheme(.dark)
    }
}
struct MiniCaptionView: View {
    @ObservedObject var session: AppSession
    var body: some View {
        HStack(spacing:12) {
            Image(systemName:"captions.bubble.fill").foregroundStyle(.teal).help("拖动空白处移动控制条")
            VStack(alignment:.leading,spacing:2) {
                StatusIndicator(session:session)
                Text(session.recordingMode.title + (session.running ? " · 后台记录中" : " · 未采集声音")).font(.caption2).foregroundStyle(.secondary)
            }.frame(minWidth:112,alignment:.leading)
            Spacer(minLength:0)
            Button("展开字幕") { session.showSubtitles() }.controlSize(.small).accessibilityIdentifier("expand-captions")
            RecordingButton(session:session).controlSize(.small)
            FloatingIconButton(title:"打开设置",symbol:"gearshape") { session.showSettings() }
        }.padding(.horizontal,14).frame(maxWidth:.infinity,maxHeight:.infinity)
            .background(Color.black.opacity(0.92),in:RoundedRectangle(cornerRadius:13))
            .overlay(RoundedRectangle(cornerRadius:13).stroke(.white.opacity(0.14)))
            .preferredColorScheme(.dark)
    }
}
struct OverlayRootView: View {
    @ObservedObject var session: AppSession
    var body: some View {
        Group {
            if session.presentation == .compact { MiniCaptionView(session:session).frame(minWidth:510,minHeight:64) }
            else { CaptionView(session:session).frame(minWidth:560,minHeight:140) }
        }.environment(\.controlActiveState,.active)
    }
}
