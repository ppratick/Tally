import Foundation
import Security

/// Personal-device credential, separate from the Tally connection and financial caches.
enum OpenAIKeyStore {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.pratick.Tally.openai",
         kSecAttrAccount as String: "openai-api-key"]
    }
    static func read() throws -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw AppError.message("Couldn't read your OpenAI key. Unlock this iPhone and try again.")
        }
        return key
    }
    static func save(_ input: String) throws {
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.count <= 512, !key.contains(where: { $0.isWhitespace }), key.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 }) else {
            throw AppError.message("Enter an API key without spaces or line breaks.")
        }
        let values: [String: Any] = [kSecValueData as String: Data(key.utf8), kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil) == errSecSuccess else {
                throw AppError.message("Couldn't save your OpenAI key securely.")
            }
        } else if status != errSecSuccess { throw AppError.message("Couldn't replace your OpenAI key securely.") }
    }
    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AppError.message("Couldn't remove your OpenAI key.") }
    }
}
