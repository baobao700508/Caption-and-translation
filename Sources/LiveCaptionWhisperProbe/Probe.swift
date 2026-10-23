import Foundation
import LiveCaptionCore

actor ProbeEvidence {
    var transcript=Transcript()
    var events:[[String:Any]]=[]
    var failure:String?
    var origin:TimeInterval=0
    func setOrigin(_ time:TimeInterval) { origin=time }
    func receive(_ event:ProviderEvent,log:SessionLog) async {
        do {
            let time=Date().timeIntervalSince1970
            switch event {
            case .text(let update):
                transcript=try await log.text(update,epoch:1)
                events.append(["time":time,"since_input_start":time-origin,"text":update.text,"provider_id":update.providerID ?? "","finality":update.finality.rawValue,
                    "audio_start_ms":update.start as Any? ?? NSNull(),"audio_end_ms":update.end as Any? ?? NSNull()])
                print(String(format:"TEXT %.2f %@ %@",time-origin,update.finality.rawValue,String(update.text.suffix(140))))
                fflush(stdout)
            case .diagnostic(let type,let fields):
                try await log.record(type,fields:fields)
                if type == "local.whisper.model_preparing" { print(fields["message"] ?? type);fflush(stdout) }
                if type == "local.whisper.ready" { print("MODEL READY",fields["load_seconds"] ?? "",fields["gpu_device"] ?? "");fflush(stdout) }
            case .error(let message): failure=message;try await log.record("provider.error",fields:["message":message])
            default: break
            }
        } catch { failure=error.localizedDescription }
    }
    func result()->[String:Any] {
        ["source":transcript.segments.map(\.text).joined(separator:"\n"),"text_events":events,"failure":failure as Any? ?? NSNull()]
    }
}

@main struct WhisperProbe {
    static func main() async {
        do {
            let args=CommandLine.arguments
            guard args.count>=4 else { print("LiveCaptionWhisperProbe input.wav whisperKit|google output-directory [limit-seconds]");exit(2) }
            let root=URL(fileURLWithPath:args[3]);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            var config=args[2] == "google" ? try Configuration.load():Configuration()
            config.pipeline = .transcribe;config.transcribeProvider=args[2] == "google" ? .google:.whisperKit
            config.captionReflow.enabled=false
            if let model=ProcessInfo.processInfo.environment["LIVECAPTION_WHISPER_MODEL"] { config.localWhisper.model=model }
            if let folder=ProcessInfo.processInfo.environment["LIVECAPTION_WHISPER_MODEL_DIRECTORY"] { config.localWhisper.modelDirectory=folder }
            let bytes=[UInt8](try Data(contentsOf:URL(fileURLWithPath:args[1])))
            guard bytes.count>=44,String(bytes:bytes[0..<4],encoding:.ascii)=="RIFF" else { throw CaptionError.message("需要 WAV") }
            func u32(_ i:Int)->Int { Int(bytes[i])|Int(bytes[i+1])<<8|Int(bytes[i+2])<<16|Int(bytes[i+3])<<24 }
            var position=12,pcm=Data(),valid=false
            while position+8<=bytes.count {
                let n=u32(position+4),start=position+8
                guard n<=bytes.count-start else { throw CaptionError.message("无效 WAV") }
                let kind=String(bytes:bytes[position..<position+4],encoding:.ascii)
                if kind == "fmt ",n>=16 { valid=bytes[start]==1 && bytes[start+2]==1 && u32(start+4)==16000 && bytes[start+14]==16 }
                if kind == "data" { pcm=Data(bytes[start..<start+n]) }
                position=start+n+n%2
            }
            guard valid,!pcm.isEmpty else { throw CaptionError.message("需要 16kHz 单声道 PCM16 WAV") }
            if ProcessInfo.processInfo.environment["LIVECAPTION_WHISPER_SNAPSHOT"] == "1" {
                try await SnapshotDiagnostics.run(pcm:pcm,configuration:config,output:root);return
            }
            if args.count>4,let seconds=Double(args[4]) { pcm=Data(pcm.prefix(Int(seconds*16000)*2)) }
            let log=try SessionLog(configuration:config,rootOverride:root.appendingPathComponent("logs"))
            try await log.begin();try await log.beginEpoch(1,configuration:config)
            let evidence=ProbeEvidence()
            let connection=Connections.make(configuration:config,audioArchive:log.audioArchive,epoch:1) { await evidence.receive($0,log:log) }
            var success=false,errorText:String?
            let setupStart=Date()
            var setupSeconds:Double=0,maxSendSeconds:Double=0,inputStart:Double=0,finishSeconds:Double=0
            do {
                try await connection.connect(handle:nil);setupSeconds=Date().timeIntervalSince(setupStart)
                inputStart=Date().timeIntervalSince1970;await evidence.setOrigin(inputStart)
                try await log.record("verification.file_input_started",fields:["input_started_at":SessionLog.timestamp(Date(timeIntervalSince1970:inputStart)),"samples":pcm.count/2])
                for offset in stride(from:0,to:pcm.count,by:3200) {
                    let end=min(offset+3200,pcm.count),target=inputStart+Double(end)/32000
                    let delay=target-Date().timeIntervalSince1970
                    if delay>0 { try await Task.sleep(nanoseconds:UInt64(delay*1e9)) }
                    let now=Date().timeIntervalSince1970
                    try await connection.sendAudio(pcm.subdata(in:offset..<end),timing:AudioTiming(captureStartedAt:inputStart+Double(offset)/32000,captureEndedAt:target,preparedAt:now))
                    maxSendSeconds=max(maxSendSeconds,Date().timeIntervalSince1970-now)
                }
                let finishStart=Date();success=await connection.finish();finishSeconds=Date().timeIntervalSince(finishStart)
            } catch { errorText=config.redacted(error.localizedDescription) }
            await connection.close()
            var restartSeconds:Double? = nil
            if config.provider == .whisperKit,success {
                let restart=Connections.make(configuration:config) { event in
                    if case .diagnostic(let name,let fields)=event { try? await log.record("verification.restart."+name,fields:fields) }
                }
                let began=Date();try await restart.connect(handle:nil);restartSeconds=Date().timeIntervalSince(began)
                success=await restart.finish();await restart.close()
            }
            try await log.finish(tailIncomplete:!success)
            var result=await evidence.result()
            result.merge(["success":success && errorText == nil && result["failure"] is NSNull,"error":errorText as Any? ?? NSNull(),"provider":config.provider.rawValue,"model":config.model,
                "input":args[1],"input_seconds":Double(pcm.count)/32000,"input_started_at_unix":inputStart,"setup_seconds":setupSeconds,"same_process_restart_seconds":restartSeconds as Any? ?? NSNull(),"finish_seconds":finishSeconds,"max_send_seconds":maxSendSeconds,"log_path":log.directory.path,
                "scope":"Real-time file playback into the actual provider adapter and journal. No physical microphone, display, or speaker measurement."]) { _,new in new }
            try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("result.json"),options:.atomic)
            print("RESULT",root.appendingPathComponent("result.json").path,"success",result["success"]!)
            exit(result["success"] as? Bool == true ? 0:1)
        } catch { print("ERROR",error.localizedDescription);exit(2) }
    }
}
