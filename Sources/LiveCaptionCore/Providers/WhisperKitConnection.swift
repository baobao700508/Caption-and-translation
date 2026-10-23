import Foundation
import CoreML
import Metal
import WhisperKit

/// Consumes the app's existing PCM16/16k stream. Never opens a microphone.
/// Exactly one decoder runs; new audio is coalesced, never queued as inference jobs.
public actor WhisperKitConnection: ProviderConnection {
    private let configuration: Configuration
    private let onEvent: (ProviderEvent) async -> Void
    private var engine: WhisperKit?
    private var worker: Task<Void,Never>?
    private var samples: [Float] = []
    private var baseSample = 0
    private var totalSamples = 0
    private var decodedThrough = 0
    private var lastVoiceSample = 0
    private var hasVoice = false
    private var inputOrigin: TimeInterval?
    private var item = 0
    private var previousText = ""
    private var ready = false
    private var closing = false
    private var finishing = false
    private var failed: String?
    private var generation = UUID()
    private var decodeCount = 0
    private var cacheKey:String { configuration.localWhisper.model+"|"+configuration.localWhisper.modelDirectory+"|cpuAndGPU" }

    public init(configuration:Configuration,onEvent:@escaping (ProviderEvent) async -> Void) {
        self.configuration=configuration;self.onEvent=onEvent
    }
    private func diagnostic(_ type:String,_ fields:[String:Any]) async { await onEvent(.diagnostic("local.whisper."+type,fields)) }
    public func connect(handle:String?) async throws {
        try configuration.validate()
        guard let device=MTLCreateSystemDefaultDevice() else { throw CaptionError.message("本地 Whisper 需要支持 Metal 的苹果 GPU") }
        let config=configuration.localWhisper
        let started=Date()
        if let cached=await WhisperModelCache.shared.take(key:cacheKey) {
            engine=cached;ready=true
            await diagnostic("ready",["model":config.model,"gpu_device":device.name,"reused_loaded_model":true,
                "feature_compute":"cpuAndGPU","encoder_compute":"cpuAndGPU","decoder_compute":"cpuAndGPU",
                "load_seconds":Date().timeIntervalSince(started),"language":config.language,"first_token_early_abort":false,"temperature_fallback_count":0])
            await onEvent(.ready);return
        }
        let folder:URL
        if !config.modelDirectory.isEmpty {
            folder=URL(fileURLWithPath:(config.modelDirectory as NSString).expandingTildeInPath)
        } else {
            let cached=config.cacheDirectory.appendingPathComponent("models/argmaxinc/whisperkit-coreml/"+config.model)
            let marker=cached.appendingPathComponent(".livecaption-download-complete")
            if FileManager.default.fileExists(atPath:marker.path) { folder=cached }
            else {
                await diagnostic("model_preparing",["phase":"download","message":"首次使用正在下载本地识别模型…","model":config.model])
                folder=try await WhisperKit.download(variant:config.model,downloadBase:config.cacheDirectory)
                try Data().write(to:folder.appendingPathComponent(".livecaption-download-complete"),options:.atomic)
            }
        }
        try Task.checkCancellation()
        await diagnostic("model_preparing",["phase":"load","message":"正在载入本地模型并准备 GPU…","model":config.model])
        let compute=ModelComputeOptions(melCompute:.cpuAndGPU,audioEncoderCompute:.cpuAndGPU,textDecoderCompute:.cpuAndGPU)
        let kit=try await WhisperKit(WhisperKitConfig(modelFolder:folder.path,tokenizerFolder:config.cacheDirectory,
            computeOptions:compute,verbose:false,logLevel:.error,prewarm:false,load:true,download:false))
        guard !closing else { await kit.unloadModels();throw CancellationError() }
        if #available(macOS 14.4, *), ProcessInfo.processInfo.environment["LIVECAPTION_WHISPER_VERIFY_GPU"] == "1" {
            for component in ["MelSpectrogram","AudioEncoder","TextDecoder"] {
                let options=MLModelConfiguration();options.computeUnits = .cpuAndGPU
                let plan=try await MLComputePlan.load(contentsOf:folder.appendingPathComponent(component+".mlmodelc"),configuration:options)
                let counts=WhisperGPUPlan.count(plan)
                await diagnostic("gpu_plan",["component":component,"gpu_preferred_operations":counts.gpu,"cpu_preferred_operations":counts.cpu,
                    "evidence":"Core ML anticipated execution plan with cpuAndGPU; not a hardware utilization trace"])
                if component != "MelSpectrogram",counts.gpu == 0 { throw CaptionError.message("Whisper \(component) 的执行计划没有启用 GPU") }
            }
        }
        await diagnostic("model_preparing",["phase":"warmup","message":"正在预热 GPU，完成后开始采音…","model":config.model])
        _ = try await kit.transcribe(audioArray:[Float](repeating:0,count:16000),decodeOptions:
            DecodingOptions(task:.transcribe,language:config.language.isEmpty ? "en":config.language,
                temperatureFallbackCount:0,sampleLength:32,skipSpecialTokens:true,wordTimestamps:true,
                windowClipTime:0,suppressBlank:true,concurrentWorkerCount:1))
        guard !closing else { await kit.unloadModels();throw CancellationError() }
        engine=kit;ready=true
        await diagnostic("ready",["model":config.model,"model_directory":folder.path,"gpu_device":device.name,
            "feature_compute":"cpuAndGPU","encoder_compute":"cpuAndGPU","decoder_compute":"cpuAndGPU",
            "load_seconds":Date().timeIntervalSince(started),"language":config.language,
            "update_interval_seconds":config.updateIntervalSeconds,"max_window_seconds":24,"max_buffer_seconds":32,
            "first_token_early_abort":false,"temperature_fallback_count":0,
            "compute_evidence":"Core ML is configured to allow CPU and GPU; not a per-operation hardware trace"])
        await onEvent(.ready)
    }
    public func sendAudio(_ data:Data) async throws { try await accept(data,timing:nil) }
    public func sendAudio(_ data:Data,timing:AudioTiming) async throws { try await accept(data,timing:timing) }
    private func accept(_ data:Data,timing:AudioTiming?) async throws {
        guard ready,!closing,!finishing,failed == nil else { throw CaptionError.message(failed ?? "本地识别尚未就绪或已结束") }
        guard data.count % 2 == 0 else { throw CaptionError.message("本地识别需要 PCM16 音频") }
        if inputOrigin == nil { inputOrigin=timing?.captureStartedAt ?? (Date().timeIntervalSince1970-Double(data.count)/32000) }
        // Stop explicitly on overload instead of silently accumulating minutes of stale speech.
        guard samples.count+data.count/2<=32*16000 else {
            failed="本地识别积压超过 32 秒，本次记录未完整识别；可结束后改选 Google 在线"
            await diagnostic("overload",["pending_audio_seconds":Double(samples.count)/16000])
            throw CaptionError.message(failed!)
        }
        let bytes=[UInt8](data)
        for start in stride(from:0,to:bytes.count,by:640) {
            let end=min(start+640,bytes.count)
            var energy:Float=0
            for i in stride(from:start,to:end,by:2) {
                let value=Float(Int16(bitPattern:UInt16(bytes[i])|UInt16(bytes[i+1])<<8))/32768
                samples.append(value);energy += value*value;totalSamples += 1
            }
            if sqrt(energy/Float(max(1,(end-start)/2)))>0.001 {
                lastVoiceSample=totalSamples;hasVoice=true
            }
        }
        launchWorker()
    }
    private func launchWorker() {
        guard worker == nil,!closing,failed == nil else { return }
        let token=generation
        worker=Task { [weak self] in await self?.decodeLoop(token:token) }
    }
    private func decodeLoop(token:UUID) async {
        defer { worker=nil }
        do {
            while !closing,!Task.isCancelled,token == generation,!samples.isEmpty {
                let newAudio=totalSamples-decodedThrough
                guard finishing || newAudio>=Int(configuration.localWhisper.updateIntervalSeconds*16000) else { return }
                if !hasVoice {
                    // Keep 200ms of leading silence, but never ask Whisper to invent text from it.
                    let cut=finishing ? samples.count : max(0,samples.count-3200)
                    samples.removeFirst(cut);baseSample += cut;decodedThrough=totalSamples
                    return
                }
                guard let engine else { return }
                let count=min(samples.count,24*16000),offset=baseSample,end=offset+count
                let snapshot=Array(samples.prefix(count)),duration=Double(count)/16000
                let quietTail=end-lastVoiceSample>=11200
                let complete=(finishing && end == totalSamples) || quietTail
                decodedThrough=end
                let start=Date()
                let language=configuration.localWhisper.language
                // With zero fallback retries, SDK first-token rejection aborts the only
                // attempt and returns empty text. Let that attempt decode the full phrase.
                let options=DecodingOptions(task:.transcribe,language:language.isEmpty ? nil:language,
                    temperature:0,temperatureFallbackCount:0,sampleLength:224,detectLanguage:language.isEmpty,
                    skipSpecialTokens:true,wordTimestamps:true,windowClipTime:0,
                    suppressBlank:true,firstTokenLogProbThreshold:nil,concurrentWorkerCount:1)
                let results=try await engine.transcribe(audioArray:snapshot,decodeOptions:options)
                guard !closing,!Task.isCancelled,token == generation else { return }
                let segments=results.flatMap(\.segments)
                let text=segments.map(\.text).joined().trimmingCharacters(in:.whitespacesAndNewlines)
                decodeCount += 1
                await diagnostic("decode",["decode_index":decodeCount,"audio_start_seconds":Double(offset)/16000,
                    "audio_end_seconds":Double(end)/16000,"window_seconds":duration,"compute_seconds":Date().timeIntervalSince(start),
                    "new_audio_during_compute_seconds":Double(totalSamples-end)/16000,
                    "snapshot_end_to_result_seconds":Date().timeIntervalSince1970-(inputOrigin ?? 0)-Double(end)/16000,
                    "buffer_seconds":Double(samples.count)/16000,"text":text,"finalizing":complete])
                if complete {
                    await emit(text,final:true,start:offset,end:end)
                    trim(count);item += 1;previousText=""
                } else if text.isEmpty {
                    await diagnostic("empty_hypothesis_held",["provider_id":"whisper-\(item)","audio_end_seconds":Double(end)/16000])
                    if duration>=24 {
                        // Continuous non-speech noise can pass the energy gate. Do not let it fill the buffer forever.
                        await emit("",final:true,start:offset,end:end)
                        trim(count);item += 1;previousText=""
                        await diagnostic("window_advanced",["cut_sample":baseSample,"reason":"empty_maximum_window"])
                    }
                } else if duration>=12,let cut=WhisperRollingCut.choose(segments:segments,duration:duration) {
                    await emit(cut.prefix,final:true,start:offset,end:offset+cut.samples)
                    trim(cut.samples);item += 1;previousText=""
                    await diagnostic("window_advanced",["cut_sample":baseSample,"reason":"timestamp_boundary","retained_seconds":Double(samples.count)/16000])
                    await emit(cut.suffix,final:false,start:baseSample,end:end)
                } else if duration>=24 {
                    // No usable timestamp means no safe split. Preserve text and expose the forced boundary.
                    await emit(text,final:true,start:offset,end:end)
                    trim(count);item += 1;previousText=""
                    await diagnostic("window_advanced",["cut_sample":baseSample,"reason":"maximum_window_no_safe_timestamp"])
                } else {
                    await emit(text,final:false,start:offset,end:end)
                }
            }
        } catch {
            if !closing,!Task.isCancelled {
                failed=configuration.redacted(error.localizedDescription)
                await diagnostic("failed",["message":failed!]);await onEvent(.error(failed!))
            }
        }
    }
    private func trim(_ count:Int) {
        let n=min(count,samples.count);samples.removeFirst(n);baseSample += n
        hasVoice=lastVoiceSample>baseSample
    }
    private func emit(_ text:String,final:Bool,start:Int,end:Int) async {
        guard final || text != previousText else { return }
        previousText=text
        await onEvent(.text(TextUpdate(track:"source",text:text,replace:true,finality:final ? .final:.interim,
            boundary:final,start:Double(start)/16,end:Double(end)/16,providerID:"whisper-\(item)")))
    }
    public func finish() async -> Bool {
        guard ready,!closing,failed == nil else { return false }
        finishing=true;launchWorker()
        await worker?.value
        let complete=samples.isEmpty && failed == nil && !closing
        await diagnostic("finished",["confirmed":complete,"input_samples":totalSamples,"remaining_samples":samples.count,"decode_count":decodeCount])
        if complete { await onEvent(.finished) }
        return complete
    }
    public func close() async {
        closing=true;ready=false;generation=UUID()
        worker?.cancel();await worker?.value;worker=nil
        if let engine {
            if failed == nil { await WhisperModelCache.shared.put(engine,key:cacheKey) }
            else { await engine.unloadModels() }
        }
        engine=nil;samples=[]
    }
}

/// One idle, already-warmed model per app process. A new session takes exclusive ownership.
/// Avoids reloading GPU weights at every stop/start without sharing mutable decoding state.
private actor WhisperModelCache {
    static let shared=WhisperModelCache()
    private var idle:(String,WhisperKit)?
    func take(key:String)->WhisperKit? {
        guard let idle,idle.0 == key else { return nil }
        self.idle=nil;return idle.1
    }
    func put(_ model:WhisperKit,key:String) async {
        let previous=idle;idle=(key,model)
        await previous?.1.unloadModels()
    }
}

@available(macOS 14.4, *)
private enum WhisperGPUPlan {
    static func count(_ plan:MLComputePlan)->(gpu:Int,cpu:Int) {
        var gpu=0,cpu=0
        func countDevice(_ usage:MLComputePlan.DeviceUsage?) {
            guard let usage else { return }
            switch usage.preferred { case .gpu: gpu += 1;case .cpu: cpu += 1;default:break }
        }
        func walk(_ block:MLModelStructure.Program.Block) {
            for operation in block.operations {
                countDevice(plan.deviceUsage(for:operation))
                for child in operation.blocks { walk(child) }
            }
        }
        switch plan.modelStructure {
        case .program(let program): for function in program.functions.values { walk(function.block) }
        case .neuralNetwork(let network): for layer in network.layers { countDevice(plan.deviceUsage(for:layer)) }
        default: break
        }
        return (gpu,cpu)
    }
}

/// Cut only at model timestamps and retain at least one second for revision.
enum WhisperRollingCut {
    struct Cut { let prefix:String;let suffix:String;let samples:Int }
    static func choose(segments:[TranscriptionSegment],duration:Double) -> Cut? {
        let punctuation=CharacterSet(charactersIn:".!?;。！？；")
        func endsPhrase(_ text:String)->Bool {
            text.trimmingCharacters(in:.whitespacesAndNewlines).unicodeScalars.last.map(punctuation.contains) == true
        }
        let eligible=segments.prefix(while:{ Double($0.end)<=duration-1 && $0.end>0 })
        if let index=eligible.lastIndex(where:{$0.end>=2 && endsPhrase($0.text)}),index+1<segments.count {
            return Cut(prefix:segments.prefix(index+1).map(\.text).joined(),suffix:segments.dropFirst(index+1).map(\.text).joined(),samples:Int(segments[index].end*16000))
        }
        let words=segments.flatMap { $0.words ?? [] }
        let prefix=words.prefix(while:{Double($0.end)<=duration-1 && $0.end>0})
        // Prefer a completed phrase over a mid-word timestamp, which can duplicate a word at the next window.
        guard let boundary=prefix.lastIndex(where:{ $0.end>=3 && endsPhrase($0.word) }),boundary+1<words.count else { return nil }
        let last=words[boundary],n=boundary+1
        return Cut(prefix:words.prefix(n).map(\.word).joined(),suffix:words.dropFirst(n).map(\.word).joined(),samples:Int(last.end*16000))
    }
}
