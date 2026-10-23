import Foundation

/// Bounded, ordered disk queue. Capture callbacks never wait for disk I/O.
public final class AudioArchive: @unchecked Sendable {
    public let directory: URL
    private let queue = DispatchQueue(label: "LiveCaption.audio.archive", qos: .utility)
    private let lock = NSLock()
    private var pendingBytes = 0
    private var failure: Error?
    private var accepting = true
    private var writers: [String: PCMRecording] = [:] // queue confined
    private var index: FileHandle
    private var uploadedFrames = 0
    private var packetCount = 0
    private var encoderSamples=0
    private var encoderEpochs:[Int:[String:Int]]=[:]
    private var finished = false
    private var probeIndexes:[String:FileHandle]=[:]
    private var probeOffsets:[String:Int]=[:]

    public init(sessionDirectory: URL) throws {
        directory = sessionDirectory.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("upload-index.jsonl")
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CaptionError.message("无法创建录音索引") }
        index = try FileHandle(forWritingTo: url)
        writers["uploaded"] = try PCMRecording(url: directory.appendingPathComponent("uploaded.wav"), rate: 16000)
        try manifest()
    }
    deinit { try? index.close() }

    private func enqueue(bytes: Int, _ work: @escaping @Sendable () throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        if let failure { throw failure }
        guard accepting else { throw CaptionError.message("录音文件已关闭") }
        guard pendingBytes + bytes <= 2_000_000 else { throw CaptionError.message("录音磁盘写入积压，已停止采集以免静默丢失录音") }
        pendingBytes += bytes
        queue.async { [self] in
            do { try work() } catch { lock.lock(); if failure == nil { failure = error }; lock.unlock() }
            lock.lock(); pendingBytes -= bytes; lock.unlock()
        }
    }
    /// System is before WebRTC NS; microphone is after Apple's hardware voice-processing stage.
    public func input(_ samples: [Float], microphone: Bool) throws {
        try input(samples, track:microphone ? "microphone-input" : "system-before-ns")
    }
    /// Direct microphone callbacks before alignment, to distinguish device processing from timeline loss.
    public func capturedMicrophone(_ samples: [Float]) throws {
        try input(samples, track:"microphone-captured")
    }
    private func input(_ samples: [Float], track: String) throws {
        var pcm = Data(capacity: samples.count * 2)
        for sample in samples {
            let finite = sample.isFinite ? sample : 0
            var word = Int16(max(-32768, min(32767, Int((max(-1,min(1,finite)) * 32767).rounded())))).littleEndian
            withUnsafeBytes(of: &word) { pcm.append(contentsOf: $0) }
        }
        let data = pcm
        let name = track
        try enqueue(bytes: data.count) { [self] in
            if writers[name] == nil { writers[name] = try PCMRecording(url: directory.appendingPathComponent(name + ".wav"), rate: 48000) }
            try writers[name]!.append(data)
        }
    }
    /// Call only after sendAudio succeeds. This is the identical PCM argument, never re-encoded.
    public func sent(_ pcm: Data, epoch: Int, submittedAt: String, timing: AudioTiming? = nil) throws {
        guard pcm.count % 2 == 0 else { throw CaptionError.message("上传录音 PCM16 长度异常") }
        let completedAt = SessionLog.timestamp()
        try enqueue(bytes: pcm.count) { [self] in
            try writers["uploaded"]!.append(pcm)
            var row: [String: Any] = ["connection_epoch": epoch, "sample_offset": uploadedFrames,
                "sample_count": pcm.count / 2, "submitted_at": submittedAt, "send_completed_at": completedAt,
                "status": "client_send_completed"]
            if let timing {
                row["capture_started_at"] = SessionLog.timestamp(Date(timeIntervalSince1970:timing.captureStartedAt))
                row["capture_ended_at"] = SessionLog.timestamp(Date(timeIntervalSince1970:timing.captureEndedAt))
                row["prepared_at"] = SessionLog.timestamp(Date(timeIntervalSince1970:timing.preparedAt))
            }
            var line = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]); line.append(10)
            try index.write(contentsOf: line)
            uploadedFrames += pcm.count / 2; packetCount += 1
        }
    }
    public func localProcessed(_ pcm: Data) throws {
        try enqueue(bytes:pcm.count) { [self] in
            if writers["processed-local"] == nil { writers["processed-local"] = try PCMRecording(url:directory.appendingPathComponent("processed-local.wav"),rate:16000) }
            try writers["processed-local"]!.append(pcm)
        }
    }
    public func publishedPCM(_ pcm:Data,rate:Int,generatedMute:Bool) throws {
        try enqueue(bytes:pcm.count) { [self] in
            if writers["aoq-published"] == nil { writers["aoq-published"] = try PCMRecording(url:directory.appendingPathComponent("aoq-published.wav"),rate:rate) }
            guard writers["aoq-published"]!.rate == rate else { throw CaptionError.message("AOQ 推流采样率发生变化") }
            try writers["aoq-published"]!.append(pcm)
            if !generatedMute {
                if writers["aoq-input-observed"] == nil { writers["aoq-input-observed"] = try PCMRecording(url:directory.appendingPathComponent("aoq-input-observed.wav"),rate:rate) }
                try writers["aoq-input-observed"]!.append(pcm)
            }
        }
    }
    /// PCM handed to the native WebRTC encoder; not a remote decoded recording.
    public func webRTCInput(_ pcm:Data,epoch:Int=0) throws {
        try enqueue(bytes:pcm.count) { [self] in
            if writers["webrtc-input-observed"] == nil { writers["webrtc-input-observed"] = try PCMRecording(url:directory.appendingPathComponent("webrtc-input-observed.wav"),rate:16000) }
            try writers["webrtc-input-observed"]!.append(pcm)
            if encoderEpochs[epoch] == nil { encoderEpochs[epoch]=["sample_offset":encoderSamples,"sample_count":0] }
            encoderEpochs[epoch]!["sample_count",default:0] += pcm.count/2;encoderSamples += pcm.count/2
        }
    }
    public func translated(_ pcm:Data,rate:Int) throws {
        try enqueue(bytes:pcm.count) { [self] in
            if writers["translated"] == nil { writers["translated"] = try PCMRecording(url:directory.appendingPathComponent("translated.wav"),rate:rate) }
            guard writers["translated"]!.rate == rate else { throw CaptionError.message("译音录音采样率发生变化") }
            try writers["translated"]!.append(pcm)
        }
    }
    /// Opt-in verification evidence. Output includes every decoded 10 ms block, including silence.
    /// Callback timestamps describe local native playout, not server generation or a physical speaker.
    public func probeTimeline(_ pcm:Data,rate:Int,track:String,epoch:Int,callbackAt:Double,callbackUptime:Double) throws {
        guard pcm.count%2 == 0, ["input","decoded-output"].contains(track) else { throw CaptionError.message("测试音频索引格式异常") }
        try enqueue(bytes:pcm.count) { [self] in
            if probeIndexes[track] == nil {
                let url=directory.appendingPathComponent("probe-\(track)-index.jsonl")
                guard FileManager.default.createFile(atPath:url.path,contents:nil,attributes:[.posixPermissions:0o600]) else { throw CaptionError.message("无法创建测试音频索引") }
                probeIndexes[track]=try FileHandle(forWritingTo:url)
            }
            let offset=probeOffsets[track,default:0]
            if track == "decoded-output" {
                if writers["probe-decoded-output"] == nil { writers["probe-decoded-output"]=try PCMRecording(url:directory.appendingPathComponent("probe-decoded-output.wav"),rate:rate) }
                try writers["probe-decoded-output"]!.append(pcm)
            }
            let row:[String:Any]=["connection_epoch":epoch,"sample_offset":offset,"sample_count":pcm.count/2,"sample_rate":rate,
                "callback_at_unix_seconds":callbackAt,"callback_uptime_seconds":callbackUptime]
            var line=try JSONSerialization.data(withJSONObject:row,options:[.sortedKeys]);line.append(10)
            try probeIndexes[track]!.write(contentsOf:line)
            probeOffsets[track]=offset+pcm.count/2
        }
    }
    public func flush() throws {
        try queue.sync {
            for writer in writers.values { try writer.flush() }
            for handle in probeIndexes.values { try handle.synchronize() }
            try index.synchronize(); try manifest()
        }
        lock.lock(); defer { lock.unlock() }; if let failure { throw failure }
    }
    public func finish() throws {
        lock.lock(); accepting = false; lock.unlock()
        try queue.sync {
            guard !finished else { return }
            for writer in writers.values { try writer.close() }
            for handle in probeIndexes.values { try handle.synchronize();try handle.close() }
            try index.synchronize(); try index.close(); finished = true; try manifest()
        }
        lock.lock(); defer { lock.unlock() }; if let failure { throw failure }
    }
    private func manifest() throws {
        let tracks = writers.mapValues { ["sample_rate": $0.rate, "samples": $0.frames, "duration_seconds": Double($0.frames)/Double($0.rate)] as [String: Any] }
        let object: [String: Any] = ["schema_version": 1, "finished": finished, "channels": 1, "encoding": "PCM16LE", "tracks": tracks, "upload_packets": packetCount,
            "encoder_epochs":encoderEpochs.map { key,value in value.merging(["connection_epoch":key]) { _,new in new } }.sorted { $0["connection_epoch"]! < $1["connection_epoch"]! },
            "uploaded_semantics": "PCM accepted by the client transport; WebRTC subsequently encodes Opus. Not a remote decoded recording or proof of server consumption. Failed sends are excluded and may have reached the server.",
            "input_semantics": "48kHz mono timeline before per-lane WebRTC NS, gain and final resampling; microphone may already include Apple Voice Processing. Missing input windows contain silence.",
            "timeline_semantics": "uploaded.wav concatenates successful sends without inserting reconnect/wall-clock gaps; use upload-index.jsonl and events.jsonl for boundaries."]
        let url = directory.appendingPathComponent("recording.json")
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted,.sortedKeys]).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Minimal incremental WAV writer; headers remain playable after each 100ms write and flush.
private final class PCMRecording {
    let rate: Int
    private let handle: FileHandle
    private var buffer = Data()
    private(set) var frames = 0
    init(url: URL, rate: Int) throws {
        self.rate = rate
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CaptionError.message("无法创建 WAV 录音") }
        handle = try FileHandle(forWritingTo: url)
        try header()
    }
    deinit { try? handle.close() }
    func append(_ data: Data) throws {
        guard data.count % 2 == 0 else { throw CaptionError.message("录音 PCM16 长度异常") }
        guard UInt64(frames) * 2 + UInt64(buffer.count) + UInt64(data.count) < UInt64(UInt32.max) - 36 else { throw CaptionError.message("单段 WAV 录音已达格式上限，请开始新会话") }
        buffer.append(data)
        if buffer.count >= rate / 5 { try writeBuffer() }
    }
    private func writeBuffer() throws {
        guard !buffer.isEmpty else { return }
        try handle.seekToEnd(); try handle.write(contentsOf: buffer)
        frames += buffer.count / 2; buffer.removeAll(keepingCapacity: true)
        try header()
    }
    private func header() throws {
        var data = Data("RIFF".utf8)
        func u32(_ value: Int) { var x = UInt32(value).littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        func u16(_ value: Int) { var x = UInt16(value).littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        u32(36 + frames * 2); data.append(Data("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
        u32(rate); u32(rate * 2); u16(2); u16(16); data.append(Data("data".utf8)); u32(frames * 2)
        try handle.seek(toOffset: 0); try handle.write(contentsOf: data)
    }
    func flush() throws { try writeBuffer(); try handle.synchronize() }
    func close() throws { try flush(); try handle.close() }
}
