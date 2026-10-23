import Foundation
import AudioBridge
import LiveCaptionCore

actor AudioEvidence {
    var packets = 0
    var frames = 0
    var energy = 0.0
    var peak = 0.0
    func add(_ data: Data) {
        packets += 1; frames += data.count/2
        data.withUnsafeBytes { bytes in
            for i in stride(from: 0,to: data.count-1,by: 2) {
                let x = Double(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset:i,as:Int16.self)))/32768
                energy += x*x; peak = max(peak,abs(x))
            }
        }
    }
    func result() -> [String: Any] {
        let rms = frames == 0 ? 0 : sqrt(energy/Double(frames))
        return ["packets":packets,"frames":frames,"rms":rms,"peak":peak,"success":packets>20 && rms>0.002 && peak<1]
    }
}

@MainActor enum AudioSmoke {
    static func run(fixture: String, output: String, session: AppSession) async {
        let ring = lc_ring_create()!
        let capture = SystemCapture(ring:ring)
        let process = Process(); process.executableURL = URL(fileURLWithPath:"/usr/bin/afplay"); process.arguments = [fixture]
        var front: AudioFrontend?
        var worker: Task<Void,Never>?
        let evidence = AudioEvidence()
        var result: [String: Any] = ["scope":"真实afplay进程→CoreAudio tap→WebRTC NS→重采样→PCM16；不调用Google、不保存采集音频","tested_at":SessionLog.timestamp()]
        session.status = "本机音频验证中"; session.sourceText = "正在验证测试音频的系统采集与自动降噪，不上传麦克风或环境声音。"
        do {
            try process.run(); try await Task.sleep(nanoseconds:800_000_000)
            try await capture.start(bundleID:"",onlyPID:process.processIdentifier)
            var config = Configuration(); config.systemAudioEnabled = true; config.microphoneEnabled = false
            let mic = lc_ring_create()!; defer { lc_ring_destroy(mic) }
            let frontend = AudioFrontend(systemRing:ring,microphoneRing:mic,config:config,nativeMic:false,notice:{ _ in },meter:{ _,_ in })
            front = frontend; try frontend.start()
            worker = Task { for await _ in frontend.packets.signals { while let packet = frontend.packets.takeBatch() { await evidence.add(packet.data) } } }
            try await Task.sleep(nanoseconds:8_000_000_000)
            await capture.stop(); frontend.stop(); await worker?.value
            result.merge(await evidence.result()) { _, n in n }
            session.status = result["success"] as? Bool == true ? "本机音频验证通过" : "本机音频验证失败"
        } catch {
            await capture.stop(); front?.stop(); worker?.cancel()
            result["success"] = false; result["error"] = error.localizedDescription
            session.status = "本机音频验证失败"; session.errorMessage = error.localizedDescription
        }
        if process.isRunning { process.terminate() }
        lc_ring_destroy(ring)
        do { let url = URL(fileURLWithPath:output); try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true); try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.atomic) }
        catch { session.errorMessage = "验证结果写入失败" }
    }
}
