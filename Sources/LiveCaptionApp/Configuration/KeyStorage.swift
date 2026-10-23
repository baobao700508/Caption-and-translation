import AppKit
import SwiftUI
import Security
import LocalAuthentication
import AVFoundation
import LiveCaptionCore

enum KeyStorage {
    private static let accessLock=NSLock()
    static func load(provider: TranslationProvider = .google) -> String? {
        load(service:"local.livecaption."+provider.rawValue)
    }
    static func load(service:String) -> String? {
        // The legacy macOS login keychain can ignore LAContext/UI query flags.
        // Background reads must fail silently instead of asking for the login password.
        accessLock.lock();defer { accessLock.unlock() }
        var interactionAllowed:DarwinBoolean=false
        SecKeychainGetUserInteractionAllowed(&interactionAllowed)
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(interactionAllowed.boolValue) }
        var result: CFTypeRef?
        let context = LAContext(); context.interactionNotAllowed = true
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: "apiKey", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
            kSecUseAuthenticationContext as String: context]
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let d = result as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    @discardableResult static func save(_ key: String, provider: TranslationProvider = .google) -> Bool {
        save(key,service:"local.livecaption."+provider.rawValue)
    }
    @discardableResult static func save(_ key:String, service:String) -> Bool {
        accessLock.lock();defer { accessLock.unlock() }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "apiKey"]
        let update = [kSecValueData as String: Data(key.utf8)]
        let status=SecItemUpdate(q as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var value = q; value.merge(update) { _, n in n };return SecItemAdd(value as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }
}
