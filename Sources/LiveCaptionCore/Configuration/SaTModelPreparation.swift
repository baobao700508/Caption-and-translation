import Foundation

/// The App and CLI run the same bootstrap; pipe reads never run on the main actor.
public final class SaTModelPreparation:@unchecked Sendable {
    private let lock=NSLock()
    private var process:Process?
    private var cancelled=false
    public init() {}
    public func cancel() {
        lock.lock()
        if cancelled { lock.unlock();return }
        cancelled=true;let worker=process;lock.unlock()
        if let worker,worker.isRunning { worker.terminate() }
    }
    public func run(script:URL,model:String,log:URL,progress:@escaping @Sendable (Double?,String)->Void) async throws {
        try await withTaskCancellationHandler(operation:{
            try await Task.detached(priority:.utility) { try self.execute(script:script,model:model,log:log,progress:progress) }.value
        },onCancel:{ self.cancel() })
    }
    private func execute(script:URL,model:String,log:URL,progress:@escaping @Sendable (Double?,String)->Void) throws {
        guard SaTReflowConfiguration.models.contains(model) else { throw CaptionError.message("不支持的 SaT 模型") }
        try FileManager.default.createDirectory(at:log.deletingLastPathComponent(),withIntermediateDirectories:true)
        FileManager.default.createFile(atPath:log.path,contents:nil)
        let logFile=try FileHandle(forWritingTo:log);defer { try? logFile.close() }
        let worker=Process(),output=Pipe()
        worker.executableURL=URL(fileURLWithPath:"/bin/bash");worker.arguments=[script.path,model]
        worker.environment=ProcessInfo.processInfo.environment.merging(["LIVECAPTION_MODEL_HOME":LocalModelFiles.root.path]) { _,new in new }
        worker.standardOutput=output;worker.standardError=logFile
        lock.lock()
        if cancelled { lock.unlock();throw CancellationError() }
        do { try worker.run();process=worker;lock.unlock() } catch { lock.unlock();throw error }
        defer { lock.lock();process=nil;lock.unlock() }
        var pending=Data(),lastError=""
        while true {
            let chunk=output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            try logFile.write(contentsOf:chunk)
            pending.append(chunk)
            while let index=pending.firstIndex(of:10) {
                let line=Data(pending[..<index]);pending.removeSubrange(...index)
                guard let event=(try? JSONSerialization.jsonObject(with:line)) as? [String:Any],let message=event["message"] as? String else { continue }
                let total=event["total"] as? Double ?? 0,received=event["received"] as? Double ?? 0
                progress(total>0 ? min(1,received/total):nil,message)
                if event["phase"] as? String == "error" { lastError=message }
            }
        }
        worker.waitUntilExit()
        lock.lock();let stopped=cancelled;lock.unlock()
        if stopped { throw CancellationError() }
        guard worker.terminationStatus == 0,LocalModelFiles.satReady(model) else {
            throw CaptionError.message(lastError.isEmpty ? "SaT 准备失败；可重试或打开安装日志。":lastError)
        }
    }
}
