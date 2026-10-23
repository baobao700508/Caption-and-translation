import SwiftUI
import AppKit

// 三个候选共用字幕正文、字体和操作，只比较浮窗布局。
enum Proposal: String, CaseIterable, Identifiable {
    case a = "A", b = "B", c = "C"
    var id: String { rawValue }
    var title: String {
        switch self { case .a: return "单行顶栏"; case .b: return "侧边控制"; case .c: return "沉浸阅读" }
    }
    var detail: String {
        switch self {
        case .a: return "保留熟悉的操作位置，底栏全部收起"
        case .b: return "上下不留工具栏，操作移到右侧"
        case .c: return "平时只看字幕，悬停或右键呼出操作"
        }
    }
    var metric: String {
        switch self { case .a: return "顶栏 28 pt"; case .b: return "侧栏 32 pt"; case .c: return "无常驻工具栏" }
    }
}

enum TextLayout: String, CaseIterable, Identifiable {
    case bilingual = "双语", translation = "译文", source = "原文"
    var id: String { rawValue }
}

enum SampleScene: String, CaseIterable, Identifiable {
    case lecture = "课堂讲解", long = "长句与长段", empty = "未开始", reconnecting = "连接恢复"
    var id: String { rawValue }
}

struct DemoParagraph: Identifiable {
    let id: Int
    let source: String
    let translation: String
}

@MainActor final class DemoSession: ObservableObject {
    @Published var layout: TextLayout = .bilingual
    @Published var scene: SampleScene = .lecture
    @Published var fontSize: Double = 22
    @Published var running = true
    @Published var latestOnly = false
    @Published var stream = false
    @Published var showCTools = false
    @Published var progress = 0
    @Published var feedback = ""
    private var timer: Timer?
    static let lecture = [
        DemoParagraph(id: 0,
            source: "A pause does not always mean that a complete idea has ended.",
            translation: "讲话中的停顿，不一定意味着一个完整的意思已经结束。"),
        DemoParagraph(id: 1,
            source: "What matters is whether the next sentence completes the explanation.",
            translation: "关键在于，后面的一句话是否还在补充同一个解释。"),
        DemoParagraph(id: 2,
            source: "Keep related ideas together, and give the reader room to follow.",
            translation: "把相互关联的内容放在一起，让阅读自然地跟上讲解。")
    ]
    static let long = [
        DemoParagraph(id: 0,
            source: "Although the two languages may use different sentence structures, the translation should preserve the relationships between the condition, the explanation, and the conclusion, rather than pairing sentences solely by their order of arrival.",
            translation: "即使两种语言采用不同的句式，翻译也应该保留条件、解释与结论之间的关系，而不是仅仅按照句子到达的先后顺序，把它们机械地配在一起。"),
        DemoParagraph(id: 1,
            source: "For example, the English speaker may state the conclusion first and explain the reason afterward; the Chinese translation may place that reason before the conclusion. The whole idea should still be easy to read as one connected passage.",
            translation: "比如，英语可能先给出结论，再补充原因；中文却可能先交代原因，最后才落到结论。尽管语序不同，读者仍应当能够把这一整段理解为连贯的意思。")
    ]
    var paragraphs: [DemoParagraph] {
        guard scene != .empty else { return [] }
        var result = scene == .long ? Self.long : Array(Self.lecture.suffix(2))
        if stream {
            let last = Self.lecture[2]
            let s = String(last.source.prefix(min(last.source.count, progress * 2)))
            let t = String(last.translation.prefix(min(last.translation.count, progress)))
            result = [Self.lecture[1], DemoParagraph(id: 2, source: s, translation: t)]
        }
        return latestOnly ? Array(result.suffix(1)) : result
    }
    var status: String {
        if scene == .empty { return "准备就绪" }
        if scene == .reconnecting { return "恢复连接" }
        return running ? "同译" : "已结束"
    }
    var statusColor: Color { scene == .reconnecting ? .orange : (running && scene != .empty ? .teal : .gray) }
    var actionTitle: String { running && scene != .empty ? "结束记录" : "开始记录" }
    var actionSymbol: String { running && scene != .empty ? "stop.fill" : "play.fill" }
    func toggleRecording() {
        if scene == .empty { scene = .lecture; running = true }
        else { running.toggle() }
        if !running { stream = false }
    }
    func changeFont(_ delta: Double) { fontSize = min(32, max(16, fontSize + delta)) }
    func setScene(_ value: SampleScene) {
        stream = false; scene = value; running = value != .empty
    }
    func startClock() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.stream, self.running else { return }
                self.progress += 1
                if self.progress > Self.lecture[2].translation.count + 18 { self.progress = 0 }
            }
        }
    }
    func toggleStream() {
        scene = .lecture; running = true; progress = 0; stream.toggle()
    }
    func copyTranslation() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paragraphs.map(\.translation).joined(separator: "\n\n"), forType: .string)
        feedback = "已复制译文"
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.8)); self?.feedback = ""
        }
    }
}

enum CaptionStyle {
    static let background = Color(red: 0.095, green: 0.105, blue: 0.12)
    static let secondary = Color.white.opacity(0.55)
    static let accent = Color(red: 0.35, green: 0.82, blue: 0.78)
    static let border = Color.white.opacity(0.13)
}

private struct CaptionIcon: View {
    let title: String
    let symbol: String
    var tint: Color = .white.opacity(0.8)
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint).frame(width: 24, height: 24).contentShape(Rectangle())
        }.buttonStyle(.plain).help(title).accessibilityLabel(title)
    }
}

private struct CaptionMenuItems: View {
    @ObservedObject var session: DemoSession
    var onClose: (() -> Void)?
    var body: some View {
        Picker("字幕内容", selection: $session.layout) {
            ForEach(TextLayout.allCases) { Text($0.rawValue).tag($0) }
        }
        Divider()
        Button("增大字号") { session.changeFont(1) }
        Button("减小字号") { session.changeFont(-1) }
        Toggle("只看最新一段", isOn: $session.latestOnly)
        Button("复制当前译文") { session.copyTranslation() }.disabled(session.paragraphs.isEmpty)
        Divider()
        Button(session.actionTitle) { session.toggleRecording() }
        if let onClose { Divider(); Button("关闭此预览", action: onClose) }
    }
}

private struct CaptionMore: View {
    @ObservedObject var session: DemoSession
    var onClose: (() -> Void)?
    var body: some View {
        Menu { CaptionMenuItems(session: session, onClose: onClose) } label: {
            Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.82))
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("字幕内容、字号与更多操作").accessibilityLabel("更多字幕操作")
    }
}

private struct QuietScrollChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            var ancestor: NSView? = view
            while let current = ancestor {
                if let scroll = current as? NSScrollView {
                    scroll.hasVerticalScroller = false; scroll.hasHorizontalScroller = false
                    scroll.drawsBackground = false
                    scroll.appearance = NSAppearance(named: .darkAqua)
                    return
                }
                ancestor = current.superview
            }
        }
    }
}

private struct ReadingBody: View {
    @ObservedObject var session: DemoSession
    var rightInset: CGFloat = 16
    var body: some View {
        Group {
            if session.scene == .empty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("准备开始").font(.system(size: 21, weight: .medium)).foregroundStyle(.white.opacity(0.9))
                    Text("开始记录后，字幕会显示在这里。")
                        .font(.system(size: 13)).foregroundStyle(CaptionStyle.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .padding(.leading, 20).padding(.trailing, rightInset)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            if session.scene == .reconnecting {
                                Label("正在恢复连接，已有字幕保留", systemImage: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 12)).foregroundStyle(.orange.opacity(0.9))
                            }
                            ForEach(session.paragraphs) { paragraph in
                                VStack(alignment: .leading, spacing: 7) {
                                    if session.layout != .translation && !paragraph.source.isEmpty {
                                        Text(paragraph.source)
                                            .font(.system(size: session.layout == .source ? session.fontSize : session.fontSize * 0.73, weight: .regular))
                                            .foregroundStyle(session.layout == .source ? Color.white.opacity(0.94) : CaptionStyle.secondary)
                                            .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    if session.layout != .source && !paragraph.translation.isEmpty {
                                        Text(paragraph.translation).font(.system(size: session.fontSize, weight: .medium))
                                            .foregroundStyle(.white.opacity(0.95)).lineSpacing(5)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                            Color.clear.frame(height: 1).id("latest")
                        }.padding(.leading, 18).padding(.trailing, rightInset).padding(.vertical, 12)
                            .background(QuietScrollChrome())
                    }.scrollIndicators(.hidden).defaultScrollAnchor(.bottom)
                        .onChange(of: session.progress) { _, _ in
                            if session.stream { proxy.scrollTo("latest", anchor: .bottom) }
                        }
                        .onChange(of: session.scene) { _, _ in proxy.scrollTo("latest", anchor: .bottom) }
                        .onChange(of: session.layout) { _, _ in proxy.scrollTo("latest", anchor: .bottom) }
                }
            }
        }
    }
}

struct CaptionProposal: View {
    let proposal: Proposal
    @ObservedObject var session: DemoSession
    var onClose: (() -> Void)?
    @State private var hovering = false
    private var reveal: Bool { hovering || session.showCTools || session.scene == .empty }
    var body: some View {
        Group {
            switch proposal {
            case .a:
                VStack(spacing: 0) {
                    HStack(spacing: 7) {
                        Circle().fill(session.statusColor).frame(width: 5, height: 5)
                        Text(session.status).font(.system(size: 11, weight: .medium))
                        Text(session.layout.rawValue).font(.system(size: 10)).foregroundStyle(CaptionStyle.secondary)
                        Spacer()
                        Text("12:36").font(.system(size: 10).monospacedDigit()).foregroundStyle(CaptionStyle.secondary)
                        CaptionIcon(title: session.actionTitle, symbol: session.actionSymbol) { session.toggleRecording() }
                        CaptionMore(session: session, onClose: onClose)
                    }.padding(.leading, 16).padding(.trailing, 6).frame(height: 28)
                    Rectangle().fill(.white.opacity(0.07)).frame(height: 0.5)
                    ReadingBody(session: session)
                }
            case .b:
                HStack(spacing: 0) {
                    ReadingBody(session: session)
                    Rectangle().fill(.white.opacity(0.07)).frame(width: 0.5)
                    VStack(spacing: 6) {
                        Capsule().fill(.white.opacity(0.16)).frame(width: 12, height: 2).padding(.top, 12)
                        Spacer(minLength: 4)
                        CaptionIcon(title: session.actionTitle, symbol: session.actionSymbol) { session.toggleRecording() }
                        CaptionMore(session: session, onClose: onClose)
                        Spacer(minLength: 4)
                        Circle().fill(session.statusColor).frame(width: 5, height: 5).padding(.bottom, 14)
                    }.frame(width: 32).background(.white.opacity(0.025))
                }
            case .c:
                ReadingBody(session: session, rightInset: 44)
                    .overlay(alignment: .leading) {
                        Capsule().fill(session.statusColor.opacity(0.8)).frame(width: 2, height: 20).padding(.leading, 5)
                    }
                    .overlay(alignment: .trailing) {
                        VStack(spacing: 5) {
                            CaptionIcon(title: session.actionTitle, symbol: session.actionSymbol) { session.toggleRecording() }
                            CaptionMore(session: session, onClose: onClose)
                        }.padding(3).background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
                            .padding(.trailing, 6).opacity(reveal ? 1 : 0)
                            .allowsHitTesting(reveal).accessibilityHidden(!reveal)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { hovering = true } }
                    .onHover { entered in withAnimation(.easeOut(duration: 0.15)) { hovering = entered } }
            }
        }
        .background(CaptionStyle.background, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(CaptionStyle.border, lineWidth: 0.7))
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .contextMenu { CaptionMenuItems(session: session, onClose: onClose) }
        .overlay(alignment: .bottomLeading) {
            if !session.feedback.isEmpty {
                Text(session.feedback).font(.system(size: 11)).padding(.horizontal, 9).padding(.vertical, 5)
                    .background(.black.opacity(0.88), in: Capsule()).padding(8)
            }
        }
        .foregroundStyle(.white.opacity(0.8)).preferredColorScheme(.dark).environment(\.colorScheme, .dark)
        .accessibilityIdentifier("caption-proposal-\(proposal.rawValue)")
    }
}

struct ProposalGallery: View {
    @ObservedObject var session: DemoSession
    let open: (Proposal) -> Void
    @State private var previewHeight: Double = 180
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("字幕浮窗，少一点框。").font(.system(size: 25, weight: .semibold))
                    Text("同样的内容与字号，比较三种操作位置。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Text("原生 Swift 原型").font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.primary.opacity(0.055), in: Capsule())
            }
            HStack(spacing: 14) {
                Picker("示例", selection: Binding(get: { session.scene }, set: { session.setScene($0) })) {
                    ForEach(SampleScene.allCases) { Text($0.rawValue).tag($0) }
                }.labelsHidden().frame(width: 132).accessibilityLabel("示例场景")
                Picker("字幕内容", selection: $session.layout) {
                    ForEach(TextLayout.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 166)
                HStack(spacing: 6) {
                    Text("字号").font(.system(size: 11)).foregroundStyle(.secondary)
                    Slider(value: $session.fontSize, in: 16...32, step: 1).frame(width: 72).accessibilityLabel("字幕字号")
                    Text("\(Int(session.fontSize))").font(.system(size: 11).monospacedDigit()).frame(width: 18)
                }
                Spacer(minLength: 0)
                Button { session.toggleStream() } label: {
                    Label(session.stream ? "停止演示" : "逐字演示", systemImage: session.stream ? "pause.fill" : "play.fill")
                }.font(.system(size: 11)).accessibilityLabel("切换逐字演示")
            }
            ForEach(Proposal.allCases) { proposal in
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 9) {
                        Text(proposal.rawValue).font(.system(size: 11, weight: .bold)).frame(width: 21, height: 21)
                            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
                        Text(proposal.title).font(.system(size: 13, weight: .semibold))
                        Text(proposal.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Text(proposal.metric).font(.system(size: 10)).foregroundStyle(.secondary)
                        Button("独立试用") { open(proposal) }.font(.system(size: 11))
                            .accessibilityIdentifier("open-proposal-\(proposal.rawValue)")
                    }
                    CaptionProposal(proposal: proposal, session: session).frame(height: previewHeight)
                }
            }
            HStack(spacing: 12) {
                Text("仅演示，不采集声音。三版的内容和状态同步。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Toggle("显示 C 的操作", isOn: $session.showCTools).font(.system(size: 11))
                    .toggleStyle(.checkbox)
            }
        }.padding(20).frame(minWidth: 860).background(Color(nsColor: .windowBackgroundColor))
            .preferredColorScheme(.light)
    }
}
