import Foundation

/// One persistent local worker, serialized on its own queue. No pipe I/O runs on the main actor.
/// Cancellation/timeout kills that worker so a stale response cannot enter the next request.
public final class SaTLocalRuntime: @unchecked Sendable {
    public static let shared = SaTLocalRuntime()
    private let queue=DispatchQueue(label:"local.livecaption.sat",qos:.utility)
    private let lock=NSLock()
    private var process:Process?
    private var input:FileHandle?
    private var output:FileHandle?
    private var python=""
    private var active:UUID?
    private var cancelled=Set<UUID>()
    private init() {}
    public func infer(_ request:Data,configuration c:SaTReflowConfiguration) async throws -> Data {
        let id=UUID()
        return try await withTaskCancellationHandler(operation:{
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do { continuation.resume(returning:try self.exchange(request,configuration:c,id:id)) }
                    catch { continuation.resume(throwing:error) }
                }
            }
        },onCancel:{ self.cancel(id) })
    }
    private func cancel(_ id:UUID) {
        lock.lock();cancelled.insert(id);let worker=active == id ? process:nil;lock.unlock()
        if let worker,worker.isRunning { worker.terminate() }
    }
    private func exchange(_ request:Data,configuration c:SaTReflowConfiguration,id:UUID) throws -> Data {
        lock.lock();let wasCancelled=cancelled.contains(id);active=id;lock.unlock()
        defer { lock.lock();active=nil;cancelled.remove(id);lock.unlock() }
        if wasCancelled { throw CancellationError() }
        let executable=(c.pythonExecutable as NSString).expandingTildeInPath
        guard FileManager.default.isExecutableFile(atPath:executable) else {
            throw CaptionError.message("SaT 本地环境未准备，请先运行 scripts/setup-sat.sh")
        }
        if process?.isRunning != true || python != executable {
            if let process,process.isRunning { process.terminate() }
            let worker=Process(),stdin=Pipe(),stdout=Pipe()
            let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let script=Bundle.main.url(forResource:"sat-worker",withExtension:"py") ?? root.appendingPathComponent("scripts/sat-worker.py")
            guard FileManager.default.fileExists(atPath:script.path) else { throw CaptionError.message("缺少 SaT 本地推理脚本") }
            worker.executableURL=URL(fileURLWithPath:executable);worker.arguments=["-u",script.path]
            worker.standardInput=stdin;worker.standardOutput=stdout;worker.standardError=FileHandle.nullDevice
            try worker.run()
            lock.lock();process=worker;let stopped=cancelled.contains(id);lock.unlock()
            if stopped { worker.terminate();throw CancellationError() }
            input=stdin.fileHandleForWriting;output=stdout.fileHandleForReading;python=executable
        }
        guard let worker=process,let input,let output else { throw CaptionError.message("SaT 本地进程未启动") }
        let deadline=DispatchWorkItem { if worker.isRunning { worker.terminate() } }
        DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now()+c.timeoutSeconds,execute:deadline)
        defer { deadline.cancel() }
        do {
            try input.write(contentsOf:request+Data([10]))
            var result=Data()
            while !result.contains(10),result.count<=2_097_152 {
                let chunk=output.availableData
                guard !chunk.isEmpty else { throw CaptionError.message("SaT 进程退出或推理超时，完整字幕已保留") }
                result.append(chunk)
            }
            guard result.count<=2_097_152,let end=result.firstIndex(of:10),end == result.count-1 else {
                throw CaptionError.message("SaT 本地响应格式无效")
            }
            lock.lock();let stopped=cancelled.contains(id);lock.unlock()
            if stopped { throw CancellationError() }
            return result.prefix(upTo:end)
        } catch {
            if worker.isRunning { worker.terminate() }
            self.input=nil;self.output=nil
            throw error
        }
    }
}
