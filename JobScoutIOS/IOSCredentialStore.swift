//
//  IOSCredentialStore.swift
//  JobScout
//
//  Created by Andrii Bryzhnychenko on 10/29/26.
//

import Foundation
import Security

enum IOSCredentialStore {
    static func read(server: String) -> String {
        var query = identity(server)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func save(_ token: String, server: String) throws {
        let query = identity(server)
        let data = Data(token.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData] = data
            item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let inserted = SecItemAdd(item as CFDictionary, nil)
            guard inserted == errSecSuccess else { throw CredentialError(status: inserted) }
        } else if status != errSecSuccess {
            throw CredentialError(status: status)
        }
    }

    private static func identity(_ server: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: "ua.andrii.JobScoutIOS.server", kSecAttrAccount: server]
    }

    private struct CredentialError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            "Could not save the server token in Keychain (\(status))."
        }
    }
}
