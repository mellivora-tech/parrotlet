import Foundation
import Security

/// API Key 的唯一落盘点：macOS Keychain（generic password，service 固定、account = provider id）。
/// config.json 里 apiKey 常态为 null；Keychain 读写失败一律记日志、当无 key 处理，不抛穿业务层。
///
/// 签名注意：Keychain 按代码签名身份认 app——ad-hoc 签名每次重建都是"新 app"，
/// 重建后首次访问会弹一次授权框；换稳定签名身份后免弹（见 Makefile codesign）。
enum KeychainHelper {
    private static let service = "mellivora.parrotlet.api-keys"
    /// 改名迁移（LanguageAgent → Parrotlet，2026-09）：老条目的 service 串。
    /// 读时兜底——读得到就够用，下次 ConfigStore.save 自动写进新 service；
    /// 确认存量装机全部迁移后可删除（含 read 里的 fallback 分支）
    private static let legacyService = "mellivora.languageagent.api-keys"

    private static func query(_ account: String, service: String = service) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read(account: String) -> String? {
        read(account: account, service: service) ?? read(account: account, service: legacyService)
    }

    private static func read(account: String, service: String) -> String? {
        var q = query(account, service: service)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            AppLog.log(.error, "keychain.readFailed", ["account": account, "status": "\(status)"])
            return nil
        }
    }

    static func save(account: String, value: String) {
        let data = Data(value.utf8)
        var probe = query(account)
        probe[kSecReturnData as String] = true
        var existing: CFTypeRef?
        let status: OSStatus
        if SecItemCopyMatching(probe as CFDictionary, &existing) == errSecSuccess {
            status = SecItemUpdate(query(account) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        } else {
            var item = query(account)
            item[kSecValueData as String] = data
            status = SecItemAdd(item as CFDictionary, nil)
        }
        if status != errSecSuccess {
            AppLog.log(.error, "keychain.saveFailed", ["account": account, "status": "\(status)"])
        }
    }

    static func delete(account: String) {
        let status = SecItemDelete(query(account) as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            AppLog.log(.error, "keychain.deleteFailed", ["account": account, "status": "\(status)"])
        }
    }
}

/// API Key 的读写通道：生产走 Keychain，测试注入内存替身（绝不碰真钥匙串）。
/// ConfigStore 只经它读写密钥——可替换性是单测不污染用户钥匙串的关键。
struct SecretStore: Sendable {
    let read: @Sendable (String) -> String?
    let save: @Sendable (String, String) -> Void
    let remove: @Sendable (String) -> Void

    static let keychain = SecretStore(
        read: { KeychainHelper.read(account: $0) },
        save: { KeychainHelper.save(account: $0, value: $1) },
        remove: { KeychainHelper.delete(account: $0) })

    /// 内存替身（测试专用）：NSLock 保护的字典
    static func inMemory() -> SecretStore {
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var dict: [String: String] = [:]
            func get(_ k: String) -> String? { lock.lock(); defer { lock.unlock() }; return dict[k] }
            func set(_ k: String, _ v: String) { lock.lock(); defer { lock.unlock() }; dict[k] = v }
            func remove(_ k: String) { lock.lock(); defer { lock.unlock() }; dict[k] = nil }
        }
        let box = Box()
        return SecretStore(
            read: { box.get($0) },
            save: { box.set($0, $1) },
            remove: { box.remove($0) })
    }
}
