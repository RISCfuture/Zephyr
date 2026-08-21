import Foundation
import Security

/**
 Persists per-account Dropbox refresh tokens.

 Two implementations exist because Zephyr's processes live in different
 security contexts: sandboxed app and extensions share a keychain access group,
 while the unsandboxed CLI (which cannot carry that entitlement) keeps its own
 item in the login keychain. Each client of the account may hold its own
 refresh token — Dropbox issues one per authorization.
 */
public protocol TokenStore: Sendable {
  /// Returns the stored refresh token for `account`, or `nil` when absent.
  func refreshToken(for account: AccountIdentifier) throws -> String?

  /// Stores (or replaces) the refresh token for `account`.
  func store(refreshToken: String, for account: AccountIdentifier) throws

  /// Removes the refresh token for `account`; succeeds when none exists.
  func deleteRefreshToken(for account: AccountIdentifier) throws

  /**
   The accounts this store holds a refresh token for.

   The inverse of asking whether a known account is authenticated: this reads
   the keychain itself, so it finds tokens for accounts the registry no longer
   lists -- what an interrupted unlink leaves behind.
   */
  func storedAccounts() throws -> [AccountIdentifier]
}

/// Shared keychain-item constants for both stores.
enum TokenKeychainItem {
  static let service = "codes.tim.Zephyr", accountPrefix = "dropbox-refresh-token:"

  /**
   When a stored token becomes readable again after a restart.

   The File Provider extension syncs while the screen is locked, so anything
   stricter than `AfterFirstUnlock` would deny it the refresh token.
   */
  static let accessibility = kSecAttrAccessibleAfterFirstUnlock as String

  static func account(for account: AccountIdentifier) -> String {
    accountPrefix + account.rawValue
  }
}

/**
 The CLI's token store: a generic-password item in the user's login keychain,
 requiring no entitlements (Maestral's storage model).
 */
public struct LoginKeychainTokenStore: TokenStore {
  public init() {}

  public func refreshToken(for account: AccountIdentifier) throws -> String? {
    try KeychainOperations.copyToken(query: baseQuery(for: account))
  }

  public func store(refreshToken: String, for account: AccountIdentifier) throws {
    try KeychainOperations.upsertToken(refreshToken, query: baseQuery(for: account))
  }

  public func deleteRefreshToken(for account: AccountIdentifier) throws {
    try KeychainOperations.deleteToken(query: baseQuery(for: account))
  }

  public func storedAccounts() throws -> [AccountIdentifier] {
    try KeychainOperations.listAccounts(query: [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: TokenKeychainItem.service
    ])
  }

  private func baseQuery(for account: AccountIdentifier) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: TokenKeychainItem.service,
      kSecAttrAccount as String: TokenKeychainItem.account(for: account)
    ]
  }
}

/**
 The app and extension token store: a data-protection keychain item in the
 team's shared keychain access group, readable by every sandboxed Zephyr
 process that carries the group entitlement.
 */
public struct GroupKeychainTokenStore: TokenStore {
  /// The keychain access group shared by the app and its extensions.
  public static let defaultAccessGroup = teamPrefix + accessGroupSuffix

  /// The group name every target's `keychain-access-groups` entitlement carries.
  private static let accessGroupSuffix = "codes.tim.Zephyr"

  /**
   The signing team's identifier prefix, trailing dot included.

   `Config/Zephyr.xcconfig` fills this from `$(AppIdentifierPrefix)`, which the
   build system substitutes only when a provisioning profile is applied; an
   unsigned, ad-hoc, or teamless build leaves it empty. Such a process carries
   no `keychain-access-groups` entitlement and so cannot reach this group under
   any name, so Zephyr's own team stands in rather than a group with no prefix
   at all.
   */
  private static let teamPrefix: String = {
    let injected = #bundle.object(forInfoDictionaryKey: "ZephyrKeychainTeamPrefix") as? String
    guard let injected, !injected.isEmpty else { return "2NFSK2WB24." }
    return injected
  }()

  private let accessGroup: String

  public init(accessGroup: String = Self.defaultAccessGroup) {
    self.accessGroup = accessGroup
  }

  public func refreshToken(for account: AccountIdentifier) throws -> String? {
    try KeychainOperations.copyToken(query: baseQuery(for: account))
  }

  public func store(refreshToken: String, for account: AccountIdentifier) throws {
    try KeychainOperations.upsertToken(refreshToken, query: baseQuery(for: account))
  }

  public func deleteRefreshToken(for account: AccountIdentifier) throws {
    try KeychainOperations.deleteToken(query: baseQuery(for: account))
  }

  public func storedAccounts() throws -> [AccountIdentifier] {
    try KeychainOperations.listAccounts(query: [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: TokenKeychainItem.service,
      kSecUseDataProtectionKeychain as String: true,
      kSecAttrAccessGroup as String: accessGroup
    ])
  }

  private func baseQuery(for account: AccountIdentifier) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: TokenKeychainItem.service,
      kSecAttrAccount as String: TokenKeychainItem.account(for: account),
      kSecUseDataProtectionKeychain as String: true,
      kSecAttrAccessGroup as String: accessGroup
    ]
  }
}

/// The Security-framework calls shared by both token stores.
private enum KeychainOperations {
  static func copyToken(query: [String: Any]) throws -> String? {
    var query = query
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    switch status {
      case errSecSuccess:
        guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
          throw AuthenticationFailure.keychain(status: errSecDecode)
        }
        return token
      case errSecItemNotFound:
        return nil
      default:
        throw AuthenticationFailure.keychain(status: status)
    }
  }

  /**
   Writes `token` into the item `query` identifies, adding it when absent.

   `query` must carry only search keys. Accessibility is an attribute, not a
   search key: including it would keep the update from matching an item stored
   under a different one, so it travels with the value instead.
   */
  static func upsertToken(_ token: String, query: [String: Any]) throws {
    let attributes: [String: Any] = [
      kSecValueData as String: Data(token.utf8),
      kSecAttrAccessible as String: TokenKeychainItem.accessibility
    ]
    let addStatus = SecItemAdd(
      query.merging(attributes) { _, attribute in attribute } as CFDictionary,
      nil
    )
    switch addStatus {
      case errSecSuccess:
        return
      case errSecDuplicateItem:
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard updateStatus == errSecSuccess else {
          throw AuthenticationFailure.keychain(status: updateStatus)
        }
      default:
        throw AuthenticationFailure.keychain(status: addStatus)
    }
  }

  static func deleteToken(query: [String: Any]) throws {
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw AuthenticationFailure.keychain(status: status)
    }
  }

  static func listAccounts(query: [String: Any]) throws -> [AccountIdentifier] {
    var query = query
    query[kSecReturnAttributes as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitAll
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    switch status {
      case errSecSuccess:
        let items = result as? [[String: Any]] ?? []
        return items.compactMap { item in
          guard let account = item[kSecAttrAccount as String] as? String,
            account.hasPrefix(TokenKeychainItem.accountPrefix)
          else { return nil }
          return try? AccountIdentifier(
            validating: String(account.dropFirst(TokenKeychainItem.accountPrefix.count))
          )
        }
      case errSecItemNotFound:
        return []
      default:
        throw AuthenticationFailure.keychain(status: status)
    }
  }
}
