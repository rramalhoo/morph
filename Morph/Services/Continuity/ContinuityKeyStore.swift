import CryptoKit
import Foundation
import Security

struct PairedDevice: Identifiable, Codable, Equatable, Sendable {
    let id: String
    var name: String
    var pairedAt: Date
}

/// Device keys, which must never sit in plain text.
protocol ContinuityKeyStoring: Sendable {
    func load() -> [(device: PairedDevice, key: SymmetricKey)]
    func save(_ device: PairedDevice, key: SymmetricKey) -> Bool
    func delete(id: String)
}

/// One Keychain item per device: the key as the secret, the name and date as its label data.
/// Kept on this Mac only.
struct KeychainContinuityKeyStore: ContinuityKeyStoring {
    private static let service = "com.athene.morph.continuity"

    private struct Record: Codable {
        var device: PairedDevice
        var key: Data
    }

    func load() -> [(device: PairedDevice, key: SymmetricKey)] {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
                                    kSecMatchLimit as String: kSecMatchLimitAll, kSecReturnData as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let items = result as? [Data] else { return [] }
        return items.compactMap { data in
            guard let record = try? JSONDecoder().decode(Record.self, from: data), record.key.count == 32 else { return nil }
            return (record.device, SymmetricKey(data: record.key))
        }
    }

    func save(_ device: PairedDevice, key: SymmetricKey) -> Bool {
        delete(id: device.id)
        guard let data = try? JSONEncoder().encode(Record(device: device, key: key.withUnsafeBytes { Data($0) })) else { return false }
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
                                   kSecAttrAccount as String: device.id, kSecValueData as String: data,
                                   kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    func delete(id: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
                                    kSecAttrAccount as String: id]
        SecItemDelete(query as CFDictionary)
    }
}
