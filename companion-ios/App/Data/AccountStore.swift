import Foundation
import Security
import UnifiedCore

/// Accounts and printers, saved as JSON in the keychain (this device only, readable after the
/// first unlock so background checks work). Tokens and access codes stay out of backups.
final class AccountStore {
    private let service = "app.unifiedslicer.monitor"
    private let item = "accounts"
    /// The saved list exists but couldn't be read; see `save`.
    private var unreadable = false

    init() {
        // The keychain outlives the app: start clean after a reinstall.
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "installed") {
            delete(item)
            defaults.set(true, forKey: "installed")
        }
    }

    func load() -> [Account] {
        switch read(item) {
        case .missing:
            return []
        case .failed:
            unreadable = true
            return []
        case .found(let data):
            if let list = try? JSONDecoder().decode([Account].self, from: data) { return list }
            unreadable = true
            return []
        }
    }

    func save(_ list: [Account]) {
        var all = list
        if unreadable {
            // The keychain may only have been locked for a moment: read it again and keep its
            // accounts. Still unreadable, it is kept aside rather than replaced.
            if case .found(let data) = read(item) {
                if let saved = try? JSONDecoder().decode([Account].self, from: data) {
                    let ids = Set(list.map(\.id))
                    all = saved.filter { !ids.contains($0.id) } + list
                } else if case .missing = read(item + ".unreadable") {
                    write(item + ".unreadable", data)
                }
            }
            unreadable = false
        }
        guard let data = try? JSONEncoder().encode(all) else { return }
        write(item, data)
    }

    private enum ReadResult {
        case found(Data)
        case missing
        case failed
    }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private func read(_ account: String) -> ReadResult {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess, let data = out as? Data else { return .failed }
        return .found(data)
    }

    private func write(_ account: String, _ data: Data) {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(account)
            add.merge(attributes) { _, new in new }
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    private func delete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}
