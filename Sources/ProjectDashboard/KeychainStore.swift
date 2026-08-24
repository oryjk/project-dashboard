import Foundation
import Security

/// API key 的存取接口（Task 5 的 UsageModel 依赖此协议注入测试替身）
protocol UsageKeyStore: Sendable {
    func readKey(for id: UsageProviderID) -> String?
    func saveKey(_ key: String, for id: UsageProviderID)
    func deleteKey(for id: UsageProviderID)
}

/// key 只存 Keychain，不落 UserDefaults、不写日志
struct KeychainStore: UsageKeyStore {
    private let service: String

    init(service: String = "com.carlwang.ProjectDashboard.usage") {
        self.service = service
    }

    func readKey(for id: UsageProviderID) -> String? {
        var query = baseQuery(for: id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else {
            return nil
        }
        return key
    }

    func saveKey(_ key: String, for id: UsageProviderID) {
        let data = Data(key.utf8)
        let query = baseQuery(for: id)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    func deleteKey(for id: UsageProviderID) {
        SecItemDelete(baseQuery(for: id) as CFDictionary)
    }

    private func baseQuery(for id: UsageProviderID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.rawValue,
        ]
    }
}
