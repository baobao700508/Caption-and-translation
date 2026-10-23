import Foundation
import AVFoundation
import LiveCaptionCore

/// Isolated preferences and generated configuration only; no keys, model calls or audio capture.
@MainActor enum SessionConfigurationSmoke {
    private static func notificationReturnedWithoutMain(_ completed:DispatchSemaphore)->Bool {
        completed.wait(timeout:.now()+0.25) == .success
    }
    static func run() async -> [String:Bool] {
        var checks:[String:Bool]=[:]
        let suite="LiveCaption-configuration-\(UUID())"
        let defaults=UserDefaults(suiteName:suite)!
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName:suite);try? FileManager.default.removeItem(at:root) }
        do {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            let url=root.appendingPathComponent("config.json")
            var file=Configuration();file.pipeline = .transcribe;file.transcribeProvider = .whisperKit
            file.captionReflow.enabled=false
            try JSONEncoder().encode(file).write(to:url)
            let session=AppSession(defaults:defaults,configurationURL:URL(fileURLWithPath:url.path))
            await session.reloadConfiguration(preservePreferences:true)
            checks["first_configuration_load_uses_file"] = session.config.systemAudioEnabled && !session.config.microphoneEnabled
            session.setAudioOption(\.microphoneEnabled,true)
            session.setAudioOption(\.systemAudioEnabled,false)
            let saved=try defaults.data(forKey:"runtime-settings").map(Configuration.decode)
            checks["audio_switch_persists_before_async_rebuild"] = saved?.systemAudioEnabled == false && saved?.microphoneEnabled == true
            let writer=CaptionReflowSettingsWriter()
            var reflow=file.captionReflow;reflow.sat.minimumCharacters=240
            _=try await writer.save(reflow,revision:1,url:url)
            // A settings write changes the file date but must not erase independent audio choices.
            try FileManager.default.setAttributes([.modificationDate:Date().addingTimeInterval(2)],ofItemAtPath:url.path)
            let reopened=AppSession(defaults:defaults,configurationURL:URL(fileURLWithPath:url.path))
            await reopened.reloadConfiguration(preservePreferences:true)
            checks["saved_microphone_survives_restart_and_other_settings_write"] = !reopened.config.systemAudioEnabled && reopened.config.microphoneEnabled
            await reopened.reloadConfiguration(preservePreferences:true)
            checks["start_reload_keeps_saved_audio_source"] = !reopened.config.systemAudioEnabled && reopened.config.microphoneEnabled
            await reopened.reloadConfiguration()
            checks["explicit_reload_imports_selected_file"] = reopened.config.systemAudioEnabled && !reopened.config.microphoneEnabled
            let imported=AppSession(defaults:defaults,configurationURL:URL(fileURLWithPath:url.path))
            await imported.reloadConfiguration(preservePreferences:true)
            checks["explicit_import_persists_for_next_launch"] = imported.config.systemAudioEnabled && !imported.config.microphoneEnabled

            let completed=DispatchSemaphore(value:0)
            DispatchQueue.global().async {
                NotificationCenter.default.post(name:.AVAudioEngineConfigurationChange,object:nil)
                completed.signal()
            }
            // Audio engine teardown can hold the main thread while its notification is posted.
            // Posting must return without synchronously requiring that same thread.
            checks["audio_route_notification_never_waits_for_main_thread"] = notificationReturnedWithoutMain(completed)
        } catch { checks["configuration_regression_completed"]=false }
        return checks
    }
}
