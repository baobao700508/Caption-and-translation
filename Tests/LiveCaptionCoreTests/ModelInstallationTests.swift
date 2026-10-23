import Foundation
@testable import LiveCaptionCore

extension PipelineChecks {
    func testModelReadinessRejectsIncompleteDownloads() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let previous=ProcessInfo.processInfo.environment["LIVECAPTION_MODEL_HOME"]
        setenv("LIVECAPTION_MODEL_HOME",root.path,1)
        defer {
            if let previous { setenv("LIVECAPTION_MODEL_HOME",previous,1) } else { unsetenv("LIVECAPTION_MODEL_HOME") }
            try? FileManager.default.removeItem(at:root)
        }
        let sat=SaTReflowConfiguration()
        XCTAssertFalse(LocalModelFiles.satReady(sat.model))
        XCTAssertFalse(LocalModelFiles.whisperReady(LocalWhisperConfiguration()))
        let folder=LocalModelFiles.satFolder(sat.model)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        try Data(#"{"model":"sat-3l","runtime":"/does/not/exist"}"#.utf8).write(to:folder.appendingPathComponent("ready.json"))
        XCTAssertFalse(LocalModelFiles.satReady(sat.model))
        var custom=sat;custom.pythonExecutable="/custom/python3"
        XCTAssertEqual(LocalModelFiles.satPython(custom),"/custom/python3")
        var whisper=LocalWhisperConfiguration();whisper.modelDirectory=folder.path
        for name in ["AudioEncoder.mlmodelc","TextDecoder.mlmodelc","MelSpectrogram.mlmodelc"] {
            try FileManager.default.createDirectory(at:folder.appendingPathComponent(name),withIntermediateDirectories:true)
        }
        XCTAssertFalse(LocalModelFiles.whisperReady(whisper))
    }
    func testSaTPreparationCancellationStopsWorker() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let script=root.appendingPathComponent("install.sh"),finished=root.appendingPathComponent("incorrectly-finished")
        try Data("#!/bin/bash\ntrap 'kill $child 2>/dev/null; exit 130' TERM\nsleep 10 & child=$!\nwait $child\ntouch '\(finished.path)'\n".utf8).write(to:script)
        let preparation=SaTModelPreparation()
        let task=Task { try await preparation.run(script:script,model:"sat-3l",log:root.appendingPathComponent("install.log")) { _,_ in } }
        try await Task.sleep(nanoseconds:200_000_000)
        task.cancel()
        var cancelled=false
        do { try await task.value } catch is CancellationError { cancelled=true }
        XCTAssertTrue(cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath:finished.path))
    }
}
