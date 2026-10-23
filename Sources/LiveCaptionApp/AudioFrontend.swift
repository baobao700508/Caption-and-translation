import Foundation
import AVFoundation
import Accelerate
import AudioBridge
import LiveCaptionCore

final class Resampler {
    private var converter: AVAudioConverter?
    private var sourceRate = 0.0
    func convert(_ samples: [Float], from rate: Double, to target: Double) throws -> [Float] {
        if rate == target { return samples }
        guard let source = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let output = AVAudioFormat(standardFormatWithSampleRate: target, channels: 1) else { throw CaptionError.message("无法建立重采样格式") }
        if sourceRate != rate || converter?.outputFormat.sampleRate != target { converter = AVAudioConverter(from: source, to: output); sourceRate = rate; converter?.sampleRateConverterQuality = AVAudioQuality.max.rawValue }
        guard let converter, let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count)),
              let result = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: AVAudioFrameCount(ceil(Double(samples.count)*target/rate)+64)) else { throw CaptionError.message("无法建立重采样缓冲") }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        var used = false; var error: NSError?
        let status = converter.convert(to: result, error: &error) { _, state in
            if used { state.pointee = .noDataNow; return nil }
            used = true; state.pointee = .haveData; return input
        }
        if let error { throw error }
        guard status != .error else { throw CaptionError.message("音频格式转换失败") }
        return Array(UnsafeBufferPointer(start: result.floatChannelData![0], count: Int(result.frameLength)))
    }
}

final class AudioFrontend {
    let packets = AudioPacketQueue()
    private let queue = DispatchQueue(label: "LiveCaption.audio.frontend", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private let systemRing: OpaquePointer
    private let microphoneRing: OpaquePointer
    private let config: Configuration
    private let nativeMic: Bool
    private let archive: AudioArchive?
    private let notice: (String) -> Void
    private let meter: (Float, Float) -> Void
    private var system = AudioTimeline(), microphone = AudioTimeline()
    private let systemResampler = Resampler(), micResampler = Resampler(), finalResampler = Resampler()
    private var systemNS: OpaquePointer?, micNS: OpaquePointer?
    private var cursor: Double?
    private var pcm = Data()
    private var lastNotice = 0.0
    private var missing = 0
    private var lastDropped: UInt64 = 0
    private var ticks = 0
    init(systemRing: OpaquePointer, microphoneRing: OpaquePointer, config: Configuration, nativeMic: Bool, archive: AudioArchive? = nil,
         notice: @escaping (String) -> Void, meter: @escaping (Float, Float) -> Void) {
        self.systemRing = systemRing; self.microphoneRing = microphoneRing; self.config = config; self.nativeMic = nativeMic; self.archive = archive; self.notice = notice; self.meter = meter
    }
    func start() throws {
        if config.systemAudioEnabled && config.systemNoiseSuppression { systemNS = lc_noise_create(); guard systemNS != nil else { throw CaptionError.message("系统降噪引擎初始化失败") } }
        if config.microphoneEnabled && config.microphoneVoiceProcessing && !nativeMic { micNS = lc_noise_create(); guard micNS != nil else { throw CaptionError.message("麦克风降噪引擎初始化失败") } }
        let timer = DispatchSource.makeTimerSource(queue: queue); self.timer = timer
        timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.tick() }; timer.resume()
    }
    private func drain(_ ring: OpaquePointer, _ resampler: Resampler, lane: inout AudioTimeline, captureMicrophone: Bool = false) throws {
        var samples = [Float](repeating: 0, count: 8192)
        for _ in 0..<128 {
            var rate = 0.0; var host: UInt64 = 0
            let frames = samples.withUnsafeMutableBufferPointer { lc_ring_read(ring, $0.baseAddress, 8192, &rate, &host) }
            if frames == 0 { break }
            let data = try resampler.convert(Array(samples.prefix(Int(frames))), from: rate, to: 48000)
            if captureMicrophone { try archive?.capturedMicrophone(data) }
            let time = Double(host)/1e9
            lane.append(data, at: time, receivedAt:Double(lc_host_nanoseconds())/1e9)
            if cursor == nil { cursor = time }
        }
    }
    private func tick() {
        do {
            if config.systemAudioEnabled { try drain(systemRing, systemResampler, lane: &system) }
            if config.microphoneEnabled { try drain(microphoneRing, micResampler, lane: &microphone, captureMicrophone:true) }
            let now = Double(lc_host_nanoseconds())/1e9
            let dropped = lc_ring_dropped(systemRing)+lc_ring_dropped(microphoneRing)
            if dropped > lastDropped { notice("采集环形缓冲丢失 \(dropped-lastDropped) 个样本"); lastDropped = dropped }
            guard var time = cursor else { return }
            if now-time > 2 { notice("音频处理落后超过两秒，跳过过时输入"); time = now-0.05; pcm.removeAll(keepingCapacity: true) }
            var work = 0
            while time+0.01 <= now-0.04 && work < 20 {
                if config.systemAudioEnabled && !system.canRead(at:time,frames:480,now:now) { break }
                if config.microphoneEnabled && !microphone.canRead(at:time,frames:480,now:now) { break }
                var (s, sc) = system.read(at: time, frames: 480)
                var (m, mc) = microphone.read(at: time, frames: 480)
                if (config.systemAudioEnabled && sc < 400) || (config.microphoneEnabled && mc < 400) { missing += 1 }
                if config.systemAudioEnabled { try archive?.input(s, microphone: false) }
                if config.microphoneEnabled { try archive?.input(m, microphone: true) }
                if let systemNS { guard s.withUnsafeMutableBufferPointer({ lc_noise_process(systemNS, $0.baseAddress) }) == 0 else { throw CaptionError.message("系统降噪处理失败") } }
                if let micNS { guard m.withUnsafeMutableBufferPointer({ lc_noise_process(micNS, $0.baseAddress) }) == 0 else { throw CaptionError.message("麦克风降噪处理失败") } }
                var mixed = [Float](repeating: 0, count: 480)
                let gain: Float = config.systemAudioEnabled && config.microphoneEnabled ? 0.5 : 1
                for i in 0..<480 { mixed[i] = max(-0.999,min(0.999,((config.systemAudioEnabled ? s[i] : 0)+(config.microphoneEnabled ? m[i] : 0))*gain)) }
                let output = try finalResampler.convert(mixed, from: 48000, to: 16000)
                for value in output { var word = Int16(max(-32768,min(32767,Int((value*32767).rounded())))).littleEndian; withUnsafeBytes(of: &word) { pcm.append(contentsOf: $0) } }
                while pcm.count >= 3200 {
                    let packet = Data(pcm.prefix(3200)); pcm.removeFirst(3200)
                    let prepared = Date().timeIntervalSince1970
                    let end = prepared - (Double(lc_host_nanoseconds())/1e9 - (time+0.01))
                    let timing = AudioTiming(captureStartedAt:end-Double(packet.count)/32000,captureEndedAt:end,preparedAt:prepared)
                    if packets.append(CapturedAudio(data:packet,timing:timing)) > 0 { if now-lastNotice > 1 { notice("发送队列已满，丢弃过时音频（网络积压）"); lastNotice = now } }
                }
                ticks += 1
                if ticks % 10 == 0 {
                    func rms(_ a: [Float]) -> Float { var value: Float = 0; vDSP_rmsqv(a,1,&value,vDSP_Length(a.count)); return value }
                    meter(rms(s),rms(m))
                }
                time += 0.01; work += 1
            }
            cursor = time
            if missing > 0 && now-lastNotice > 5 { notice("音频时间轴缺失 \(missing) 个 10ms 输入窗口，已用静音维持时钟"); missing = 0; lastNotice = now }
        } catch { notice("前端异常：\(error.localizedDescription)") }
    }
    func stop() {
        timer?.setEventHandler {}; timer?.cancel(); timer = nil
        queue.sync {
            if !pcm.isEmpty {
                let now = Date().timeIntervalSince1970
                packets.append(CapturedAudio(data:pcm,timing:AudioTiming(captureStartedAt:now-Double(pcm.count)/32000,captureEndedAt:now,preparedAt:now)))
                pcm.removeAll()
            }
            packets.finish()
            if let systemNS { lc_noise_destroy(systemNS); self.systemNS = nil }
            if let micNS { lc_noise_destroy(micNS); self.micNS = nil }
        }
    }
    deinit { if let systemNS { lc_noise_destroy(systemNS) }; if let micNS { lc_noise_destroy(micNS) } }
}
