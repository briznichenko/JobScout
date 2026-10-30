//
//  MacCredentialStore.swift
//  JobScout
//
//  Created by Andrii Bryzhnychenko on 10/29/26.
//

import Foundation
import Security

enum MacCredentialStore {
    private static func query(server: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "ua.andrii.JobScout.server",
         kSecAttrAccount as String: server]
    }

    static func load(server: String) -> String {
        var request = query(server: server)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func save(_ token: String, server: String) throws {
        let request = query(server: server)
        let value = [kSecValueData as String: Data(token.utf8)]
        let status = SecItemUpdate(request as CFDictionary, value as CFDictionary)
        if status == errSecItemNotFound {
            var item = request.merging(value) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw BackendError.failed("Could not save the server token in Keychain (\(added)).") }
        } else if status != errSecSuccess {
            throw BackendError.failed("Could not update the server token in Keychain (\(status)).")
        }
    }
}
