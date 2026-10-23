import SwiftUI
import AppKit
import LiveCaptionCore

struct CaptionTranscriptView: View {
    @ObservedObject var session:AppSession
    private var rows:[CaptionParagraph] {
        if !session.captionParagraphs.isEmpty {
            return session.captionParagraphs.filter {
                if session.config.pipeline == .transcribe || session.config.subtitleLayout == .source { return !$0.source.isEmpty }
                return true
            }
        }
        return [CaptionParagraph(id:"waiting",source:session.sourceText,translation:session.translatedText)]
    }
    var body:some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                VStack(spacing:0) {
                    ScrollView {
                        LazyVStack(alignment:.leading,spacing:16) {
                            ForEach(rows) { row in
                                let sourceVisible = session.config.pipeline == .transcribe || session.config.subtitleLayout != .translation
                                let translationVisible = session.config.pipeline == .translate && session.config.subtitleLayout != .source
                                CaptionParagraphView(row:row,fontSize:session.fontSize,
                                    showSource:sourceVisible,showTranslation:translationVisible).id(row.id)
                            }
                            if let error = session.errorMessage {
                                Text(error).font(.caption).foregroundStyle(.orange).contextMenu {
                                    Button("复制错误信息") { NSPasteboard.general.clearContents();NSPasteboard.general.setString(error,forType:.string) }
                                }
                            }
                            Color.clear.frame(height:1).id("caption-bottom")
                        }.padding(.horizontal,18).padding(.vertical,12)
                            .background(CaptionScrollObserver(onUserScroll:{ atBottom in session.followsLatestCaption=atBottom }))
                    }.scrollIndicators(.hidden).defaultScrollAnchor(.bottom)
                    if !session.followsLatestCaption {
                        HStack {
                            Text("正在查看前文").foregroundStyle(.secondary)
                            Spacer()
                            Button("回到最新 ↓") { session.followsLatestCaption=true; scrollToLatest(proxy) }
                                .accessibilityIdentifier("caption-follow-latest")
                        }.font(.caption).padding(.horizontal,18).padding(.vertical,6)
                    }
                }
                .onAppear { scrollToLatest(proxy) }
                .onChange(of:rows) { old,new in
                    // A correction inside a fixed block does not request a new bottom anchor.
                    let structural=old.map(\.id) != new.map(\.id)
                    let tailChanged=new.last?.isFinal == false && old.last != new.last
                    if !session.config.captionReflow.enabled || structural || tailChanged { scrollToLatest(proxy) }
                }
                .onChange(of:session.config.subtitleLayout) { _,_ in scrollToLatest(proxy) }
                .onChange(of:session.fontSize) { _,_ in scrollToLatest(proxy) }
                .onChange(of:geometry.size) { _,_ in scrollToLatest(proxy) }
                .onChange(of:session.followsLatestCaption) { _,following in if following { scrollToLatest(proxy) } }
            }
        }
    }
    private func scrollToLatest(_ proxy:ScrollViewProxy) {
        guard session.followsLatestCaption else { return }
        // Wait for the updated text's layout; scrolling before it produces a stale bottom offset.
        DispatchQueue.main.async { if session.followsLatestCaption { proxy.scrollTo("caption-bottom",anchor:.bottom) } }
    }
}

private struct CaptionParagraphView:View {
    let row:CaptionParagraph
    let fontSize:Double
    let showSource:Bool
    let showTranslation:Bool
    var body:some View {
        VStack(alignment:.leading,spacing:7) {
            if showSource && !row.source.isEmpty {
                Text(row.source).font(.system(size:showTranslation ? fontSize*0.73:fontSize,weight:.regular))
                    .foregroundStyle(.white.opacity(showTranslation ? 0.55:1))
                    .lineSpacing(3).fixedSize(horizontal:false,vertical:true)
                    .contextMenu { Button("复制本段原文") { copy(row.source) } }
                    .frame(maxWidth:.infinity,alignment:.leading).accessibilityIdentifier("source-caption")
            }
            if showTranslation {
                if !row.translation.isEmpty {
                    if row.unlinkedTranslation { Text("译文 · 暂无对应原文").font(.caption2).foregroundStyle(.secondary) }
                    Text(row.translation).font(.system(size:fontSize,weight:.medium)).foregroundStyle(.white).lineSpacing(5)
                        .fixedSize(horizontal:false,vertical:true)
                        .contextMenu { Button("复制本段译文") { copy(row.translation) } }
                        .frame(maxWidth:.infinity,alignment:.leading).accessibilityIdentifier("translation-caption")
                } else if !row.source.isEmpty { Text("等待本段译文…").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
    private func copy(_ text:String) {
        NSPasteboard.general.clearContents();NSPasteboard.general.setString(text,forType:.string)
    }
}

private struct CaptionScrollObserver:NSViewRepresentable {
    let onUserScroll:(Bool)->Void
    func makeNSView(context:Context)->Probe { Probe(onUserScroll:onUserScroll) }
    func updateNSView(_ view:Probe,context:Context) { view.onUserScroll=onUserScroll; view.attach() }
    final class Probe:NSView {
        var onUserScroll:(Bool)->Void
        private weak var observed:NSScrollView?
        private var tokens:[NSObjectProtocol]=[]
        init(onUserScroll:@escaping(Bool)->Void) { self.onUserScroll=onUserScroll; super.init(frame:.zero) }
        required init?(coder:NSCoder) { fatalError("init(coder:) is unsupported") }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attach() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); attach() }
        func attach() {
            guard let scroll=enclosingScrollView,scroll !== observed else { return }
            tokens.forEach(NotificationCenter.default.removeObserver); tokens=[]; observed=scroll
            for name in [NSScrollView.willStartLiveScrollNotification,NSScrollView.didLiveScrollNotification,NSScrollView.didEndLiveScrollNotification] {
                tokens.append(NotificationCenter.default.addObserver(forName:name,object:scroll,queue:.main) { [weak self,weak scroll] notification in
                    guard let self,let scroll else { return }
                    let bottom=(scroll.documentView?.bounds.maxY ?? 0)-scroll.contentView.bounds.maxY <= 24
                    self.onUserScroll(notification.name == NSScrollView.willStartLiveScrollNotification ? false:bottom)
                })
            }
        }
        deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
    }
}
