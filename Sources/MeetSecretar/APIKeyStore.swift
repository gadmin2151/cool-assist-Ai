import Foundation
import LocalAuthentication
import MeetingCore
import Security

protocol APIKeyStore: Sendable {
  func exists() -> Bool
  func read() throws -> String
  func save(_ key: String) throws
  func remove() throws
}

struct KeychainAPIKeyStore: APIKeyStore {
  let service: String
  init(service: String = (Bundle.main.bundleIdentifier ?? "cc.idomus.meet-secretar") + ".openai") {
    self.service = service
  }
  private var query: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service, kSecAttrAccount as String: "api-key",
    ]
  }
  func exists() -> Bool {
    var query = query
    query[kSecReturnAttributes as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    let context = LAContext()
    context.interactionNotAllowed = true
    query[kSecUseAuthenticationContext as String] = context
    let status = SecItemCopyMatching(query as CFDictionary, nil)
    return status == errSecSuccess || status == errSecInteractionNotAllowed
  }
  func read() throws -> String {
    var query = query
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess, let data = result as? Data,
      let key = String(data: data, encoding: .utf8), !key.isEmpty
    else {
      throw MeetingError.message(
        "API-ключ недоступен. Откройте настройки резюме и сохраните ключ в Связке ключей macOS.")
    }
    return key
  }
  func save(_ key: String) throws {
    let data = Data(key.utf8)
    var status = SecItemUpdate(
      query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
      var item = query
      item[kSecValueData as String] = data
      item[kSecAttrLabel as String] = "Meet Protocol — OpenAI API"
      item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
      status = SecItemAdd(item as CFDictionary, nil)
    }
    guard status == errSecSuccess else {
      throw MeetingError.message("Не удалось сохранить API-ключ в Связке ключей macOS (\(status)).")
    }
  }
  func remove() throws {
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw MeetingError.message("Не удалось удалить API-ключ из Связки ключей macOS (\(status)).")
    }
  }
}
