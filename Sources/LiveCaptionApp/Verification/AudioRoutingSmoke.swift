import Foundation
import AppKit
import AVFoundation
import LiveCaptionCore

/// Real capture/route rebuilds without a speech provider or any credential access.
@MainActor enum AudioRoutingSmoke {
    static func run(output:String,session:AppSession) async {
        session.verificationInProgress=true
        var config=Configuration();config.pipeline = .transcribe;config.transcribeProvider = .whisperKit
        config.captionReflow.enabled=false;config.systemAudioEnabled=false;config.microphoneEnabled=true
        session.config=config;session.configurationReady=true;session.running=true
        var stages:[[String:Any]]=[],checks:[String:Bool]=[:]
        let url=URL(fileURLWithPath:output)
        let heartbeat=url.deletingLastPathComponent().appendingPathComponent("audio-route-heartbeat.json")
        let pulse=Task { @MainActor in
            while !Task.isCancelled {
                let value:[String:Any]=["at":SessionLog.timestamp(),"restarts":session.audioInputRestartCount]
                try? JSONSerialization.data(withJSONObject:value).write(to:heartbeat,options:.atomic)
                try? await Task.sleep(nanoseconds:100_000_000)
            }
        }
        do {
            for mode in ["microphone","mixed","system","microphone"] {
                session.busy=true
                session.config.systemAudioEnabled=mode != "microphone"
                session.config.microphoneEnabled=mode != "system"
                let started=Date()
                _=try await session.hardware.start(session.config)
                session.busy=false
                let before=session.audioInputRestartCount
                // Duplicate notifications from a healthy engine must not rebuild capture.
                for _ in 0..<8 {
                    NotificationCenter.default.post(name:.AVAudioEngineConfigurationChange,object:session.hardware.engine)
                }
                try await Task.sleep(nanoseconds:4_000_000_000)
                let stable=session.hardware.engine.isRunning && session.audioInputRestartCount == before
                checks["stable_\(stages.count)_\(mode)"]=stable
                stages.append(["input":mode,"engine_running":session.hardware.engine.isRunning,
                    "restart_count":session.audioInputRestartCount,"running":session.running,"busy":session.busy,"error":session.errorMessage ?? "","elapsed_seconds":Date().timeIntervalSince(started)])
            }
            // An actually stopped engine still has to recover, exactly once.
            let before=session.audioInputRestartCount,resumes=session.audioEngineResumeCount
            let stoppedEngine=session.hardware.engine
            session.hardware.engine.stop()
            NotificationCenter.default.post(name:.AVAudioEngineConfigurationChange,object:session.hardware.engine)
            try await Task.sleep(nanoseconds:3_000_000_000)
            checks["stopped_engine_recovers_once"] = session.hardware.engine.isRunning && session.hardware.engine === stoppedEngine
                && session.audioInputRestartCount == before && session.audioEngineResumeCount == resumes+1
        } catch { checks["capture_completed"]=false }
        await session.stop();pulse.cancel();await pulse.value
        let report:[String:Any]=["success":checks.values.allSatisfy{$0},"checks":checks,"stages":stages,
            "scope":"Actual system/microphone capture, Apple voice processing and route recovery; no model, credentials or cloud connection."]
        try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.atomic)
    }
}
