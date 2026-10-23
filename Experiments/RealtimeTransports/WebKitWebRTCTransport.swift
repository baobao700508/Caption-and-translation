import AppKit
import Foundation
import LiveCaptionCore
import WebKit

/// File-test candidate: macOS WebKit's WebRTC stack; credentials stay in Swift.
public actor WebKitWebRTCTransport: RealtimeTransport {
    private var surface: WebRTCSurface?
    private var iterator: AsyncThrowingStream<Data, Error>.Iterator?
    public init() {}
    public func open(_ request: URLRequest) async throws {
        let surface = await WebRTCSurface(request: request)
        self.surface = surface
        iterator = surface.events.makeAsyncIterator()
        await surface.start()
    }
    public func send(_ data: Data) async throws {
        guard let surface else { throw CaptionError.message("WebRTC 未连接") }
        try await surface.send(data)
    }
    public func receive() async throws -> Data {
        guard var iterator else { throw CaptionError.message("WebRTC 未连接") }
        guard let data = try await iterator.next() else { throw CaptionError.message("WebRTC 已关闭") }
        self.iterator = iterator
        return data
    }
    public func close() async {
        await surface?.close(); surface = nil; iterator = nil
    }
}

@MainActor private final class WebRTCSurface: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    nonisolated let events: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let request: URLRequest
    private var webView: WKWebView?
    private var exchange: Task<Void, Never>?
    private var closed = false

    init(request: URLRequest) {
        self.request = request
        var c: AsyncThrowingStream<Data, Error>.Continuation!
        events = AsyncThrowingStream(bufferingPolicy: .bufferingOldest(256)) { c = $0 }
        continuation = c
        super.init()
    }
    func start() {
        _ = NSApplication.shared
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(self, name: "livecaption")
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 32, height: 32), configuration: config)
        view.navigationDelegate = self; webView = view
        view.loadHTMLString("<!doctype html><meta charset='utf-8'><script>" + Self.script + "</script>", baseURL: URL(string: "https://localhost"))
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !closed, let root = message.body as? [String: Any] else { return }
        if root["kind"] as? String == "offer", let sdp = root["sdp"] as? String {
            exchange = Task { [weak self] in await self?.exchangeOffer(sdp) }
        } else if root["kind"] as? String == "failure" {
            // Only locally defined categories cross this boundary, never SDP or authenticated URLs.
            let reason = root["category"] as? String ?? "unknown"
            continuation.finish(throwing: CaptionError.message("WebRTC 连接失败（\(reason)）"))
        } else if let data = try? JSONSerialization.data(withJSONObject: root) {
            if case .dropped = continuation.yield(data) {
                continuation.finish(throwing: CaptionError.message("WebRTC 接收积压"))
            }
        }
    }
    private func exchangeOffer(_ sdp: String) async {
        do {
            guard let url = request.url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw CaptionError.message("WebRTC 地址无效") }
            parts.scheme = "https"; parts.path = "/api/v1/webrtc/realtime"
            var offer = URLRequest(url: parts.url!); offer.httpMethod = "POST"; offer.httpBody = Data(sdp.utf8); offer.timeoutInterval = 20
            offer.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
            offer.setValue(request.value(forHTTPHeaderField: "Authorization"), forHTTPHeaderField: "Authorization")
            let session = URLSession(configuration: .ephemeral); defer { session.invalidateAndCancel() }
            let (data, response) = try await session.data(for: offer)
            guard (response as? HTTPURLResponse)?.statusCode == 200, let answer = String(data: data, encoding: .utf8) else { throw CaptionError.message("WebRTC SDP 交换失败（HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)）") }
            guard !closed, let webView else { return }
            _ = try await webView.callAsyncJavaScript("return await window.live.answer(sdp)", arguments: ["sdp": answer], in: nil, contentWorld: .page)
        } catch {
            if !closed { continuation.finish(throwing: CaptionError.message("WebRTC SDP 连接失败")) }
        }
    }
    func send(_ data: Data) async throws {
        guard !closed, let webView, let text = String(data: data, encoding: .utf8) else { throw CaptionError.message("WebRTC 已关闭") }
        do {
            _ = try await webView.callAsyncJavaScript("return await window.live.send(text)", arguments: ["text": text], in: nil, contentWorld: .page)
        } catch { throw CaptionError.message("WebRTC 音频或控制事件发送失败") }
    }
    func close() async {
        closed = true; exchange?.cancel(); exchange = nil
        if let webView {
            _ = try? await webView.callAsyncJavaScript("await window.live?.close()", arguments: [:], in: nil, contentWorld: .page)
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "livecaption")
            webView.stopLoading()
        }
        webView = nil; continuation.finish()
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation.finish(throwing: CaptionError.message("WebRTC 本地页面加载失败"))
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let data = try? JSONSerialization.data(withJSONObject: ["type":"_webrtc.stage","stage":"page.loaded"]) { continuation.yield(data) }
        Task { [weak self, weak webView] in
            do { _ = try await webView?.evaluateJavaScript("window.live.start(); true") }
            catch { self?.continuation.finish(throwing: CaptionError.message("WebRTC 音频上下文启动失败")) }
        }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        continuation.finish(throwing: CaptionError.message("WebRTC 音频进程已终止"))
    }

    private static let script = #"""
    (() => {
      const post = value => window.webkit.messageHandlers.livecaption.postMessage(value);
      const fail = category => post({kind:'failure', category});
      const stage = value => post({type:'_webrtc.stage',stage:value}); stage('script.started');
      let pc, ctx, destination, sender, localTrack, control, timer, cursor = 0, stopping = false;
      const outputNodes = [];
      const encodePCM = floats => {
        const bytes = new Uint8Array(floats.length * 2), view = new DataView(bytes.buffer);
        for (let i=0; i<floats.length; i++) view.setInt16(i*2, Math.max(-32768, Math.min(32767, Math.round(floats[i]*32768))), true);
        let text = ''; for (const byte of bytes) text += String.fromCharCode(byte);
        return btoa(text);
      };
      const hook = ch => {
        ch.onmessage = async e => {
          try {
            const event = JSON.parse(e.data);
            if (event.type === 'session.created') control = ch;
            if (event.type === 'session.updated') await sender.replaceTrack(localTrack);
            post(event);
          } catch (_) { fail('event'); }
        };
      };
      const start = async () => {
        try {
          stage('context.creating'); ctx = new AudioContext({sampleRate:24000}); await ctx.resume(); stage('context.running');
          if (ctx.state !== 'running' || ctx.sampleRate !== 24000) throw new Error('audio-context');
          destination = ctx.createMediaStreamDestination();
          localTrack = destination.stream.getAudioTracks()[0];
          pc = new RTCPeerConnection({iceServers:[]});
          sender = pc.addTrack(localTrack, destination.stream); await sender.replaceTrack(null);
          pc.ondatachannel = e => hook(e.channel); hook(pc.createDataChannel('oai-events'));
          pc.onconnectionstatechange = () => { if (!stopping && ['failed','closed'].includes(pc.connectionState)) fail('connection'); };
          pc.ontrack = e => {
            if (e.track.kind !== 'audio') return;
            const source = ctx.createMediaStreamSource(new MediaStream([e.track]));
            const tap = ctx.createScriptProcessor(1024, 1, 1), mute = ctx.createGain(); mute.gain.value = 0;
            tap.onaudioprocess = event => {
              const pcm = event.inputBuffer.getChannelData(0);
              // Omit all-zero idle callbacks; this graph never plays the remote track.
              if (pcm.some(value => Math.abs(value) > 1/32768)) post({type:'response.audio.delta',delta:encodePCM(pcm)});
            };
            source.connect(tap); tap.connect(mute); mute.connect(ctx.destination); outputNodes.push(source,tap,mute);
          };
          await pc.setLocalDescription(await pc.createOffer());
          if (pc.iceGatheringState !== 'complete') await new Promise((resolve,reject) => {
            const deadline = setTimeout(() => reject(new Error('ice')), 10000);
            pc.addEventListener('icegatheringstatechange', () => { if(pc.iceGatheringState === 'complete'){clearTimeout(deadline);resolve();} });
          });
          stage('offer.created'); post({kind:'offer',sdp:pc.localDescription.sdp});
          timer = setInterval(async () => {
            if (!pc || stopping) return;
            const report = await pc.getStats();
            for (const s of report.values()) if (['outbound-rtp','remote-inbound-rtp'].includes(s.type)) {
              const safe = {type:'_webrtc.stats',kind:s.type};
              for (const key of ['packetsSent','bytesSent','packetsLost','fractionLost','roundTripTime']) if (s[key] !== undefined) safe[key] = s[key];
              post(safe);
            }
          },1000);
        } catch (_) { fail('setup'); }
      };
      window.live = {
        start,
        answer: async sdp => { await pc.setRemoteDescription({type:'answer',sdp:sdp.trim().replace(/\r?\n/g,'\r\n')+'\r\n'}); return true; },
        send: async text => {
          const event = JSON.parse(text);
          if (event.type === 'input_audio_buffer.append') {
            const binary = atob(event.audio), bytes = new Uint8Array(binary.length);
            for(let i=0;i<bytes.length;i++)bytes[i]=binary.charCodeAt(i);
            const input = new DataView(bytes.buffer), buffer = ctx.createBuffer(1,bytes.length/2,16000), floats=buffer.getChannelData(0);
            for(let i=0;i<floats.length;i++)floats[i]=input.getInt16(i*2,true)/32768;
            const source = ctx.createBufferSource(); source.buffer=buffer; source.connect(destination);
            const now=ctx.currentTime, start=Math.max(cursor,now+0.1);
            if(cursor>0 && now>cursor+0.04)post({type:'_webrtc.input_gap',gap_ms:(now-cursor)*1000});
            source.start(start); cursor=start+buffer.duration; source.onended=()=>source.disconnect();
            return true;
          }
          if (event.type === 'session.finish') await new Promise(resolve => setTimeout(resolve,Math.max(0,(cursor-ctx.currentTime)*1000)+150));
          if (!control || control.readyState !== 'open') throw new Error('control');
          control.send(text); return true;
        },
        close: async () => {stopping=true;clearInterval(timer);pc?.close();localTrack?.stop();for(const node of outputNodes)node.disconnect();await ctx?.close();}
      };
    })();
    """#
}
