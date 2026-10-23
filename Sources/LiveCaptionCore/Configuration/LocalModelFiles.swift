import Foundation
import WhisperKit

/// Downloaded assets belong to the user, never inside a signed App or source checkout.
public enum LocalModelFiles {
    private struct FileReceipt:Codable { let path:String;let bytes:Int }
    private struct WhisperReceipt:Codable { let model:String;let files:[FileReceipt] }
    public static var root:URL {
        if let path=ProcessInfo.processInfo.environment["LIVECAPTION_MODEL_HOME"] { return URL(fileURLWithPath:path) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/LiveCaption",isDirectory:true)
    }
    public static func satFolder(_ model:String)->URL { root.appendingPathComponent("SaT/models/"+model,isDirectory:true) }
    public static func satPython(_ config:SaTReflowConfiguration)->String {
        let legacy=SaTReflowConfiguration().pythonExecutable
        if config.pythonExecutable == legacy,let receipt=satReceipt(config.model),let runtime=receipt["runtime"] as? String {
            return runtime+"/bin/python3"
        }
        return (config.pythonExecutable as NSString).expandingTildeInPath
    }
    private static func satReceipt(_ model:String)->[String:Any]? {
        guard SaTReflowConfiguration.models.contains(model),
              let data=try? Data(contentsOf:satFolder(model).appendingPathComponent("ready.json")),
              let receipt=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
              receipt["model"] as? String == model,
              let runtime=receipt["runtime"] as? String,
              FileManager.default.isExecutableFile(atPath:runtime+"/bin/python3"),
              FileManager.default.fileExists(atPath:runtime+"/.dependencies.json"),
              ["config.json","model_optimized.onnx"].allSatisfy({ FileManager.default.fileExists(atPath:satFolder(model).appendingPathComponent($0).path) }),
              FileManager.default.fileExists(atPath:root.appendingPathComponent("SaT/tokenizer/tokenizer.json").path)
        else { return nil }
        return receipt
    }
    public static func satReady(_ model:String)->Bool { satReceipt(model) != nil }
    public static func whisperFolder(_ config:LocalWhisperConfiguration)->URL {
        if !config.modelDirectory.isEmpty { return URL(fileURLWithPath:(config.modelDirectory as NSString).expandingTildeInPath) }
        return config.cacheDirectory.appendingPathComponent("models/argmaxinc/whisperkit-coreml/"+config.model)
    }
    public static func whisperReady(_ config:LocalWhisperConfiguration)->Bool {
        let folder=whisperFolder(config)
        let models=["AudioEncoder.mlmodelc","TextDecoder.mlmodelc","MelSpectrogram.mlmodelc"]
        guard models.allSatisfy({ FileManager.default.fileExists(atPath:folder.appendingPathComponent($0).path) }) else { return false }
        guard let data=try? Data(contentsOf:folder.appendingPathComponent(".livecaption-prepared")),
              let receipt=try? JSONDecoder().decode(WhisperReceipt.self,from:data),receipt.model == config.model,!receipt.files.isEmpty else { return false }
        return receipt.files.allSatisfy { file in
            ((try? FileManager.default.attributesOfItem(atPath:file.path)[.size]) as? NSNumber)?.intValue == file.bytes
        }
    }
    public static func prepareWhisper(_ config:LocalWhisperConfiguration,progress:@escaping @Sendable (Double?,String)->Void) async throws {
        try config.validate()
        let folder:URL
        if config.modelDirectory.isEmpty {
            progress(0,"正在下载 Whisper 模型…")
            folder=try await WhisperKit.download(variant:config.model,downloadBase:config.cacheDirectory,progressCallback:{ value in
                progress(value.fractionCompleted,"正在下载 Whisper 模型…")
            })
        } else { folder=whisperFolder(config) }
        try Task.checkCancellation()
        progress(nil,"正在准备分词器并验证本地 GPU 识别…")
        let compute=ModelComputeOptions(melCompute:.cpuAndGPU,audioEncoderCompute:.cpuAndGPU,textDecoderCompute:.cpuAndGPU)
        let kit=try await WhisperKit(WhisperKitConfig(modelFolder:folder.path,tokenizerFolder:config.cacheDirectory,
            computeOptions:compute,verbose:false,logLevel:.error,prewarm:false,load:true,download:false))
        do {
            _ = try await kit.transcribe(audioArray:[Float](repeating:0,count:16000),decodeOptions:
                DecodingOptions(task:.transcribe,language:config.language.isEmpty ? "en":config.language,
                    temperatureFallbackCount:0,sampleLength:32,skipSpecialTokens:true,wordTimestamps:true,
                    windowClipTime:0,suppressBlank:true,concurrentWorkerCount:1))
            try Task.checkCancellation()
            let tokenizer=config.cacheDirectory.appendingPathComponent("models/openai/whisper-"+kit.modelVariant.description)
            guard [folder,tokenizer].contains(where:{ FileManager.default.fileExists(atPath:$0.appendingPathComponent("tokenizer.json").path) }) else {
                throw CaptionError.message("Whisper 分词器未完整下载，请重试。")
            }
            var files:[FileReceipt]=[]
            for directory in [folder,tokenizer] {
                let entries=FileManager.default.enumerator(at:directory,includingPropertiesForKeys:[.isRegularFileKey,.fileSizeKey],options:.skipsHiddenFiles)
                while let url=entries?.nextObject() as? URL {
                    let values=try url.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey])
                    if values.isRegularFile == true { files.append(FileReceipt(path:url.path,bytes:values.fileSize ?? 0)) }
                }
            }
            try JSONEncoder().encode(WhisperReceipt(model:config.model,files:files)).write(to:folder.appendingPathComponent(".livecaption-prepared"),options:.atomic)
        } catch { await kit.unloadModels();throw error }
        await kit.unloadModels()
        progress(1,"Whisper 已下载并通过本机识别验证")
    }
}
