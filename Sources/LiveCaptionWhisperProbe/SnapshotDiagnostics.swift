import Foundation
import WhisperKit
import LiveCaptionCore

/// Exact audio snapshots from the delayed sentence, independent of real-time pacing.
enum SnapshotDiagnostics {
    static func run(pcm:Data,configuration:Configuration,output:URL) async throws {
        let local=configuration.localWhisper
        let folder=local.cacheDirectory.appendingPathComponent("models/argmaxinc/whisperkit-coreml/"+local.model)
        let kit=try await WhisperKit(WhisperKitConfig(modelFolder:folder.path,tokenizerFolder:local.cacheDirectory,
            computeOptions:ModelComputeOptions(melCompute:.cpuAndGPU,audioEncoderCompute:.cpuAndGPU,textDecoderCompute:.cpuAndGPU),
            verbose:false,logLevel:.error,prewarm:false,load:true,download:false))
        let bytes=[UInt8](pcm)
        let samples=stride(from:0,to:bytes.count,by:2).map { Float(Int16(bitPattern:UInt16(bytes[$0])|UInt16(bytes[$0+1])<<8))/32768 }
        var records:[[String:Any]]=[]
        for end in [54.3,55.9] {
            for variant in ["normal","no_word_alignment","no_silence_filter","no_first_token_abort"] {
                let began=Date()
                let result=try await kit.transcribe(audioArray:Array(samples[Int(47.14*16000)..<Int(end*16000)]),decodeOptions:
                    DecodingOptions(task:.transcribe,language:"en",temperature:0,temperatureFallbackCount:0,sampleLength:224,
                        skipSpecialTokens:true,wordTimestamps:variant != "no_word_alignment",windowClipTime:0,suppressBlank:true,
                        firstTokenLogProbThreshold:variant == "no_first_token_abort" ? nil : -1.5,
                        noSpeechThreshold:variant == "no_silence_filter" ? nil:0.6,concurrentWorkerCount:1))
                let segments=result.flatMap(\.segments)
                let record:[String:Any]=["start":47.14,"end":end,"variant":variant,"seconds":Date().timeIntervalSince(began),
                    "text":result.map(\.text).joined(),"segments":segments.map { ["text":$0.text,"start":$0.start,"end":$0.end,"no_speech_probability":$0.noSpeechProb,"average_log_probability":$0.avgLogprob] as [String:Any] }]
                records.append(record);print(record)
            }
        }
        try JSONSerialization.data(withJSONObject:records,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("snapshot-diagnostics.json"))
        await kit.unloadModels()
    }
}
