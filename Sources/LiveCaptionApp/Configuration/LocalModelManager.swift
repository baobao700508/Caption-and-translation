import Foundation
import SwiftUI
import LiveCaptionCore

struct ModelDownloadState {
    var active=false
    var ready=false
    var fraction:Double?
    var message="尚未下载"
    var log:URL?
}

@MainActor final class LocalModelManager:ObservableObject {
    @Published var sat=ModelDownloadState()
    @Published var whisper=ModelDownloadState()
    private var satTask:Task<Void,Never>?
    private var whisperTask:Task<Void,Never>?
    private var satWorker:SaTModelPreparation?
    func refresh(_ config:Configuration) {
        if !sat.active {
            sat.ready=LocalModelFiles.satReady(config.captionReflow.sat.model)
            sat.message=sat.ready ? "已下载，可离线整理字幕":"尚未下载完整环境"
        }
        if !whisper.active {
            whisper.ready=LocalModelFiles.whisperReady(config.localWhisper)
            whisper.message=whisper.ready ? "已下载，可本机识别":"尚未完成下载与验证"
        }
    }
    func installSaT(_ config:SaTReflowConfiguration) {
        guard !sat.active else { return }
        let log=LocalModelFiles.root.appendingPathComponent("InstallLogs/sat-\(Int(Date().timeIntervalSince1970)).log")
        sat=ModelDownloadState(active:true,message:"正在准备下载…",log:log)
        let worker=SaTModelPreparation();satWorker=worker
        satTask=Task { [self] in
            do {
                guard let script=Bundle.main.url(forResource:"install-sat",withExtension:"sh") else { throw CaptionError.message("应用缺少安装脚本，请重新下载完整 App。") }
                try await worker.run(script:script,model:config.model,log:log) { [weak self] fraction,message in
                    Task { @MainActor in
                        guard let self,self.sat.active else { return }
                        self.sat.fraction=fraction;self.sat.message=message
                    }
                }
                try Task.checkCancellation()
                sat.ready=true;sat.message="已下载并通过离线分段验证"
            } catch is CancellationError { sat.message="已取消；可以重新下载" }
            catch { sat.message="准备失败："+error.localizedDescription }
            sat.active=false;sat.fraction=nil;satWorker=nil;satTask=nil
        }
    }
    func installWhisper(_ config:LocalWhisperConfiguration) {
        guard !whisper.active else { return }
        let log=LocalModelFiles.root.appendingPathComponent("InstallLogs/whisper-\(Int(Date().timeIntervalSince1970)).log")
        whisper=ModelDownloadState(active:true,message:"正在准备下载…",log:log)
        whisperTask=Task { [self] in
            do {
                try FileManager.default.createDirectory(at:log.deletingLastPathComponent(),withIntermediateDirectories:true)
                try Data("开始准备 Whisper：\(config.model)\n".utf8).write(to:log)
                try await LocalModelFiles.prepareWhisper(config) { [weak self] fraction,message in
                    Task { @MainActor in
                        guard let self,self.whisper.active else { return }
                        self.whisper.fraction=fraction;self.whisper.message=message
                    }
                }
                try Task.checkCancellation()
                whisper.ready=true;whisper.message="已下载并通过本机识别验证"
            } catch is CancellationError { whisper.message="已取消；可以重新下载" }
            catch { whisper.message="准备失败："+error.localizedDescription }
            if let handle=try? FileHandle(forWritingTo:log) {
                _ = try? handle.seekToEnd();try? handle.write(contentsOf:Data((whisper.message+"\n").utf8));try? handle.close()
            }
            whisper.active=false;whisper.fraction=nil;whisperTask=nil
        }
    }
    func cancelSaT() { if sat.active { sat.message="正在取消安装…" };satTask?.cancel();satWorker?.cancel() }
    func cancelWhisper() { if whisper.active { whisper.message="正在取消准备…" };whisperTask?.cancel() }
    func cancelAll() { cancelSaT();cancelWhisper() }
}
