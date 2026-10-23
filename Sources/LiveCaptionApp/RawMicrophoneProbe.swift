import Foundation
import AVFoundation
import AudioBridge
import LiveCaptionCore

/// Local diagnostic peer of Voice Processing: a separate unprocessed input tap.
@MainActor final class RawMicrophoneProbe {
    private let engine = AVAudioEngine()
    private let ring = lc_ring_create()!
    private let emptySystem = lc_ring_create()!
    private var recorder:AudioArchive?
    private var front:AudioFrontend?
    private var worker:Task<Void,Never>?
    private var tapped = false
    var isRunning:Bool { engine.isRunning }
    func startDevice(config:Configuration) throws -> [String:Any] {
        let input = engine.inputNode
        try selectAudioDevice(uid:config.microphoneDeviceUID,input:true,node:input)
        let format = input.outputFormat(forBus:0)
        let ring = self.ring
        input.installTap(onBus:0,bufferSize:1024,format:format) { buffer,time in
            var description = buffer.format.streamDescription.pointee
            _ = lc_ring_write(ring,buffer.audioBufferList,&description,buffer.frameLength,time.hostTime)
        }
        tapped = true; engine.prepare(); try engine.start()
        return ["sample_rate":format.sampleRate,"channels":format.channelCount,"voice_processing":input.isVoiceProcessingEnabled]
    }
    func startRecording(config:Configuration,root:URL) throws {
        guard engine.isRunning else { throw CaptionError.message("原始麦克风并行采集被系统中止，不能进行对照") }
        // Discard setup-time input using the SPSC reader, never resetting a live producer.
        var buffer = [Float](repeating:0,count:8192);var rate=0.0;var host:UInt64=0
        for _ in 0..<128 {
            if buffer.withUnsafeMutableBufferPointer({ lc_ring_read(ring,$0.baseAddress,8192,&rate,&host) }) == 0 { break }
        }
        var raw = config;raw.systemAudioEnabled = false;raw.microphoneEnabled = true;raw.microphoneVoiceProcessing = false
        let archive = try AudioArchive(sessionDirectory:root);recorder = archive
        let frontend = AudioFrontend(systemRing:emptySystem,microphoneRing:ring,config:raw,nativeMic:false,archive:archive,notice:{ _ in },meter:{ _,_ in })
        front = frontend;try frontend.start()
        worker = Task {
            for await _ in frontend.packets.signals {
                while let packet = frontend.packets.takeBatch() { try? archive.localProcessed(packet.data) }
            }
        }
    }
    func stop() async throws -> URL? {
        let wasRunning = engine.isRunning
        if tapped { engine.inputNode.removeTap(onBus:0);tapped=false }
        engine.stop();front?.stop();front=nil;await worker?.value;worker=nil
        try recorder?.finish()
        if recorder != nil && !wasRunning { throw CaptionError.message("原始麦克风采集中途停止，对照结果不完整") }
        return recorder?.directory
    }
    deinit { lc_ring_destroy(ring);lc_ring_destroy(emptySystem) }
}
