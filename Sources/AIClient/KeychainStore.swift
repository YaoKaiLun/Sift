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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return }
        if updated == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError.unexpectedStatus(added) }
            return
        }
        throw KeychainError.unexpectedStatus(updated)
    }

    public func delete(_ account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
