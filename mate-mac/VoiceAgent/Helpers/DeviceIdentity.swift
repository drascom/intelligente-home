import Foundation
import Security

/// Stabil cihaz kimliği + adı. İlk açılışta bir UUID üretip Keychain'de saklar;
/// sonraki açılışlarda okur. İleride sesle-login'in de temeli olacak.
///
/// Sandbox KAPALI olduğundan (bkz. entitlements) generic-password Keychain için
/// ek erişim grubu/entitlement gerekmez; varsayılan keychain kullanılır.
enum DeviceIdentity {
    nonisolated static let deviceIdKey = "mate.deviceId"
    nonisolated static let clientTokenKey = "mate.clientToken"

    nonisolated static var deviceId: String {
        if let existing = Keychain.read(deviceIdKey), !existing.isEmpty { return existing }
        let id = UUID().uuidString
        Keychain.write(deviceIdKey, id)
        return id
    }

    nonisolated static var deviceName: String {
        "Mac-" + ProcessInfo.processInfo.hostName
    }
}

/// Küçük Keychain (generic password) sarmalayıcı — thread-safe (nonisolated).
enum Keychain {
    nonisolated static let service = "drascom.mate.mac"

    nonisolated static func read(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, let s = String(data: data, encoding: .utf8)
        else { return nil }
        return s
    }

    @discardableResult
    nonisolated static func write(_ key: String, _ value: String) -> Bool {
        delete(key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    nonisolated static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
