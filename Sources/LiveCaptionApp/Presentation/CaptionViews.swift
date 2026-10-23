import SwiftUI
import AppKit
import LiveCaptionCore

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
                Button("AI 追课",action:session.copyCatchUpPrompt).disabled(session.currentDirectory == nil)
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
    var body: some View {
        VStack(spacing:0) {
            HStack(spacing:9) {
                Image(systemName:"captions.bubble").foregroundStyle(.teal)
                Text(session.recordingMode.title).font(.caption.weight(.semibold))
                if session.config.pipeline == .translate {
                    Picker("字幕显示",selection:$session.config.subtitleLayout) {
                        Text("仅原文").tag(SubtitleLayout.source)
                        Text("译文").tag(SubtitleLayout.translation)
                        Text("双语").tag(SubtitleLayout.bilingual)
                    }.labelsHidden().frame(width:86)
                        .onChange(of:session.config.subtitleLayout) { _,_ in session.preferencesChanged() }
                        .help("选择原文、译文或双语；立即生效")
                }
                StatusIndicator(session:session)
                if session.sessionStartedAt != nil { SessionDuration(session:session) }
                Spacer(minLength:8)
                FloatingIconButton(title:"打开设置",symbol:"gearshape") { session.showSettings() }
                FloatingIconButton(title:"收起为迷你控制条（记录继续）",symbol:"rectangle.compress.vertical") { session.collapseSubtitles() }
                Menu {
                    Button("回听录音…") { session.showSettings(.records) }
                    Button("打开设置…") { session.showSettings() }
                    Button("重置字幕位置") { session.overlay?.resetPosition() }
                    Toggle("字幕鼠标穿透",isOn:$session.passthrough)
                    Divider()
                    Button("隐藏到菜单栏（记录继续）") { session.overlay?.hide() }
                } label: { Image(systemName:"ellipsis").frame(width:26,height:30) }.menuStyle(.borderlessButton).fixedSize().help("更多字幕操作").accessibilityLabel("更多字幕操作")
            }.padding(.horizontal,14).padding(.vertical,8)
            Divider().overlay(.white.opacity(0.08))
            if session.sessionStartedAt == nil {
                VStack(alignment:.leading,spacing:10) {
                    Text(session.configurationLoading ? "正在准备 LiveCaption" : "准备好开始记录").font(.title3.weight(.semibold))
                    Text("\(session.recordingMode.title) · \(session.sourceSummary)").font(.callout).foregroundStyle(.secondary)
                    Text("字幕可收起为迷你条，课堂文字会持续写入本机日志。").font(.caption).foregroundStyle(.secondary)
                    if let problem = session.configurationProblem { Text(problem).font(.caption).foregroundStyle(.orange).lineLimit(2) }
                }.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.leading).padding(18)
            } else {
                CaptionTranscriptView(session:session)
            }
            Divider().overlay(.white.opacity(0.08))
            HStack(spacing:12) {
                RecordingButton(session:session).controlSize(.small)
                Text(session.feedback ?? (session.running ? "文字持续写入本机" : "收起字幕不会结束记录")).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength:4)
                Button("记录") { session.revealLogs() }.help("打开课堂日志目录")
                Button("AI 追课",action:session.copyCatchUpPrompt).disabled(session.currentDirectory == nil).help("复制供 AI 读取课堂日志的提示")
            }.font(.caption).buttonStyle(.borderless).padding(.horizontal,14).padding(.vertical,9)
        }.background(Color.black.opacity(session.overlayOpacity),in:RoundedRectangle(cornerRadius:14))
            .overlay(RoundedRectangle(cornerRadius:14).stroke(.white.opacity(0.14),lineWidth:1))
            .preferredColorScheme(.dark)
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
            if session.presentation == .compact { MiniCaptionView(session:session) }
            else { CaptionView(session:session) }
        }.environment(\.controlActiveState,.active)
    }
}

