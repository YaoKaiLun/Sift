import Foundation
import os
import Security

public protocol KeychainStore: Sendable {
    func get(_ account: String) throws -> String?
    func set(_ value: String, account: String) throws
    func delete(_ account: String) throws
}

public enum KeychainError: Error, Sendable, Equatable {
    case unexpectedStatus(OSStatus)
}

/// 测试用内存实现；拷贝共享同一份存储。
public struct MemoryKeychain: KeychainStore {
    private let storage = OSAllocatedUnfairLock(initialState: [String: String]())

    public init() {}

    public func get(_ account: String) throws -> String? {
        storage.withLock { $0[account] }
    }

    public func set(_ value: String, account: String) throws {
        storage.withLock { $0[account] = value }
    }

    public func delete(_ account: String) throws {
        storage.withLock { _ = $0.removeValue(forKey: account) }
    }
}

public struct SystemKeychain: KeychainStore {
    public static let service = "app.sift.explain"

    private let serviceName: String

    public init(service: String = SystemKeychain.service) {
        self.serviceName = service
    }

    public func get(_ account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.unexpectedStatus(errSecDecode)
        }
        return value
    }

    public func set(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery(account: account)
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return }
        if updated == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError.unexpectedStatus(added) }
            return
        }
        throw KeychainError.unexpectedStatus(updated)
    }

    public func delete(_ account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// 走数据保护钥匙串，不绑旧版 ACL。否则每次重编 Debug 包签名一变，
    /// 启动读 API Key 就会弹出「允许使用钥匙串」对话框。
    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}
