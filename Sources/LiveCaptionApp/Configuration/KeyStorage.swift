import AppKit
import SwiftUI
import Security
import LocalAuthentication
import AVFoundation
import LiveCaptionCore

enum KeyStorage {
    static func load(provider: TranslationProvider = .google) -> String? {
        load(service:"local.livecaption."+provider.rawValue)
    }
    static func load(service:String) -> String? {
        var result: CFTypeRef?
        let context = LAContext(); context.interactionNotAllowed = true
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: "apiKey", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context]
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let d = result as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    @discardableResult static func save(_ key: String, provider: TranslationProvider = .google) -> Bool {
        save(key,service:"local.livecaption."+provider.rawValue)
    }
    @discardableResult static func save(_ key:String, service:String) -> Bool {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "apiKey"]
        let update = [kSecValueData as String: Data(key.utf8)]
        let status=SecItemUpdate(q as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var value = q; value.merge(update) { _, n in n };return SecItemAdd(value as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }
}
