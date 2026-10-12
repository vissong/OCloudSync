import Foundation
import Security
import SyncCore

/// Session cookies are credentials: they are stored only in the macOS Keychain.
enum CookieVault {
  static let service = "dev.local.ocloudsync.oppo-session"
  static func allowed(_ domain: String) -> Bool {
    let host = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
    return ["oppo.com", "heytap.com", "heytapmobi.com", "nearme.com.cn", "oppomobile.com"].contains
    { host == $0 || host.hasSuffix("." + $0) }
  }
  private static var query: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: "official-web-session",
    ]
  }
  static func save(_ cookies: [HTTPCookie]) throws {
    let rows = cookies.filter { allowed($0.domain) }.compactMap { cookie -> [String: Any]? in
      guard let properties = cookie.properties else { return nil }
      return Dictionary(
        uniqueKeysWithValues: properties.map {
          ($0.key.rawValue, ($0.value as? URL)?.absoluteString ?? $0.value)
        })
    }
    let data = try PropertyListSerialization.data(
      fromPropertyList: ["savedAt": Date(), "cookies": rows], format: .binary, options: 0)
    let status = SecItemUpdate(
      query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
      var add = query
      add[kSecValueData as String] = data
      add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else {
        throw SyncFailure("无法将 OPPO 会话保存到钥匙串，重启后可能需要重新登录")
      }
    } else if status != errSecSuccess {
      throw SyncFailure("无法更新钥匙串中的 OPPO 会话")
    }
  }
  static func load() throws -> [HTTPCookie] {
    var q = query
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(q as CFDictionary, &result)
    if status == errSecItemNotFound { return [] }
    guard status == errSecSuccess, let data = result as? Data else {
      throw SyncFailure("无法读取钥匙串中的 OPPO 会话，请重新登录")
    }
    guard
      let envelope = try PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any],
      let date = envelope["savedAt"] as? Date, Date().timeIntervalSince(date) < 30 * 86400,
      let rows = envelope["cookies"] as? [[String: Any]]
    else { return [] }
    return rows.compactMap { row in
      let properties = Dictionary(
        uniqueKeysWithValues: row.map { (HTTPCookiePropertyKey($0.key), $0.value) })
      guard let cookie = HTTPCookie(properties: properties), allowed(cookie.domain),
        cookie.expiresDate.map({ $0 > Date() }) ?? true
      else { return nil }
      return cookie
    }
  }
}
