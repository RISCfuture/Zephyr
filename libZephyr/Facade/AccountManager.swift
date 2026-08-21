import Foundation
import os

/**
 The entry point into libZephyr: links and unlinks Dropbox accounts and vends
 ``AccountSession``s for linked ones.

 Construct with the token store matching the calling process: the CLI passes
 ``LoginKeychainTokenStore``, the app and extensions pass
 ``GroupKeychainTokenStore``.
 */
public actor AccountManager {
  /// Every keychain a Zephyr process may have written a refresh token into.
  private static let everyTokenStore: [any TokenStore] = [
    LoginKeychainTokenStore(),
    GroupKeychainTokenStore()
  ]

  private let environment: ZephyrEnvironment
  private let tokenStore: any TokenStore
  private let registry: AccountRegistry

  /**
   Creates a manager over an environment's shared container.

   - Parameters:
     - environment: Where the account registry and per-account state live. Tests
       point this at a temporary directory; everything else takes the default.
     - tokenStore: Where refresh tokens are read and written. Pass the store
       matching the calling process — the keychain a sandboxed extension can
       reach is not the one the CLI uses.
   */
  public init(
    environment: ZephyrEnvironment = .standard,
    tokenStore: any TokenStore
  ) {
    self.environment = environment
    self.tokenStore = tokenStore
    registry = AccountRegistry(environment: environment)
  }

  /// The identifiers of all linked accounts.
  public func linkedAccounts() async throws -> [AccountIdentifier] {
    try await registry.linkedAccounts()
  }

  /**
   The linked accounts whose refresh token this manager's token store holds.

   - Throws: The keychain failure when the store could not be read. A read
     that fails is not an account without a token, and must not be reported as
     one: every list of accounts the app builds starts here, and the domain
     reconcile takes a list that has grown shorter as licence to remove the
     missing account's domain — and with it the local replica of everything
     the user had materialized.
   */
  public func authenticatableAccounts() async throws -> [AccountIdentifier] {
    try await linkedAccounts().filter { try tokenStore.refreshToken(for: $0) != nil }
  }

  /**
   Accounts this manager's token store still holds a refresh token for, but which
   the registry no longer lists.

   A refresh token outliving its account is a credential the user believes they
   revoked. ``unlink(_:)`` clears both, so an orphan means an unlink that did not
   finish -- the process died between the two deletions, or the token was written
   by a build whose registry has since been removed. Reported rather than cleaned
   up silently, because the remedy is to revoke it at
   dropbox.com/account/connected_apps, which only the user can do.
   */
  public func orphanedTokenAccounts() async throws -> [AccountIdentifier] {
    let linked = Set(try await linkedAccounts())
    return try tokenStore.storedAccounts().filter { !linked.contains($0) }
  }

  /// Loads a linked account's configuration.
  public func configuration(for account: AccountIdentifier) async throws -> AccountConfiguration {
    try await registry.configuration(for: account)
  }

  /**
   Begins linking an account. Open ``LinkFlow/authorizationURL`` in a
   browser, then complete with the pasted code or the callback URL.

   - Parameters:
     - redirect: How Dropbox hands the authorization back: to a URL scheme the
       app registers, or as a code for the user to paste.
     - intent: Which account may complete the link. The default accepts
       whichever one approves, which is what a caller with no account in mind
       wants; anything offering the user a particular outcome — a second
       account, a repair of one that broke — names it, so that an approval by
       some other account is refused rather than acted on.
   */
  public func beginLink(
    redirect: DropboxOAuthFlow.RedirectStyle = .outOfBand,
    for intent: LinkIntent = .anyAccount
  ) -> LinkFlow {
    LinkFlow(
      oauth: DropboxOAuthFlow(redirect: redirect),
      manager: self,
      intent: intent
    )
  }

  /**
   Unlinks an account: revokes the token server-side, deletes the stored
   refresh token from both keychains, and removes the account's local state.

   - Throws: The revocation failure when Dropbox could not be reached or
     refused to revoke. The local state is torn down regardless, so a caller
     that sees this should tell the user to remove Zephyr at
     <https://www.dropbox.com/account/connected_apps>.
   */
  public func unlink(_ account: AccountIdentifier) async throws {
    let revocationFailure = await revokeTokenRemotely(for: account)
    try deleteRefreshTokenEverywhere(for: account)
    try await registry.unregister(account)
    if let revocationFailure {
      throw revocationFailure
    }
  }

  /// Asks Dropbox to invalidate the account's tokens, returning why it could not.
  private func revokeTokenRemotely(for account: AccountIdentifier) async -> (any Error)? {
    do {
      try await session(for: account).client.revokeToken()
      return nil
    } catch EngineFailure.notLinked {
      return nil
    } catch {
      ZephyrLog.auth.error(
        "Revoking \(account.rawValue, privacy: .public) failed: \(error.localizedDescription)"
      )
      return error
    }
  }

  /**
   Removes the account's refresh token from both token stores.

   Dropbox issues a refresh token per authorization, so the CLI may hold one of
   its own alongside the app's: deleting only from this manager's store would
   leave that credential live. Reaching into the store this process does not
   itself use is best effort — a sandboxed process is refused the CLI's login
   keychain item, and the CLI is refused the shared access group — so only the
   manager's own store is allowed to fail the unlink.
   */
  private func deleteRefreshTokenEverywhere(for account: AccountIdentifier) throws {
    try tokenStore.deleteRefreshToken(for: account)
    for store in Self.everyTokenStore {
      try? store.deleteRefreshToken(for: account)
    }
  }

  /// Opens a session for a linked account.
  public func session(for account: AccountIdentifier) async throws -> AccountSession {
    guard let refreshToken = try tokenStore.refreshToken(for: account) else {
      throw EngineFailure.notLinked
    }
    let configuration = try await registry.configuration(for: account)
    return AccountSession(
      configuration: configuration,
      refreshToken: refreshToken,
      environment: environment,
      registry: registry
    )
  }

  /// Completes a link: persists the token and account state, returns a session.
  func finishLink(
    result: DropboxOAuthFlow.LinkResult,
    for intent: LinkIntent
  ) async throws -> AccountSession {
    let provider = AccessTokenProvider(refreshToken: result.refreshToken)
    await provider.seed(accessToken: result.accessToken, expiry: result.accessTokenExpiry)
    let baseClient = DropboxClient(tokenProvider: provider)
    let account = try await baseClient.currentAccount()
    // Before anything is written: a link the user did not ask for must not
    // overwrite the token, or the link date, of the account that approved it.
    try await confirm(account, satisfies: intent)

    try tokenStore.store(refreshToken: result.refreshToken, for: account.accountID)
    let configuration = AccountConfiguration(
      accountID: account.accountID,
      email: account.email,
      displayName: account.displayName,
      root: account.rootInfo
    )
    try await registry.register(configuration)
    return AccountSession(
      configuration: configuration,
      refreshToken: result.refreshToken,
      environment: environment,
      registry: registry
    )
  }

  /**
   Refuses an authorization that is not the one the link was started for.

   Zephyr cannot say in advance which account should approve: the
   authorization page belongs to Dropbox, and it approves as whoever the
   browser is signed in as. So the check happens here, on the way back, where
   the account is known for the first time.
   */
  func confirm(_ account: FullAccount, satisfies intent: LinkIntent) async throws {
    switch intent {
      case .anyAccount:
        return
      case .newAccount:
        guard try await !isAlreadyLinked(account.accountID) else {
          throw LinkRefusal.alreadyLinked(email: account.email)
        }
      case let .repairing(expected):
        guard account.accountID != expected else { return }
        throw LinkRefusal.notTheAccountBeingRepaired(
          approved: account.email,
          repairing: await emailOfRecord(for: expected)
        )
    }
  }

  /**
   Whether this process could already act as `account`.

   Both halves matter. The registry alone would refuse `zephyr auth link` an
   authorization of an account the app linked — which is not a duplicate but
   the CLI earning its own credential, since the two keep their tokens in
   different keychains.
   */
  private func isAlreadyLinked(_ account: AccountIdentifier) async throws -> Bool {
    guard try await registry.linkedAccounts().contains(account) else { return false }
    return try tokenStore.refreshToken(for: account) != nil
  }

  /// How to name the account a repair was for. Its configuration is the very
  /// thing a relink repairs, so an unreadable one falls back to the identifier.
  private func emailOfRecord(for account: AccountIdentifier) async -> String {
    (try? await registry.configuration(for: account))?.email ?? account.rawValue
  }
}

/// What a link is for, and so which account may complete it.
public enum LinkIntent: Sendable, Equatable {
  /**
   Links whichever account approves, linked already or not.

   What `zephyr auth link` wants: an account the app linked is one the CLI
   has still to authorize for itself, and re-authorizing an account the CLI
   linked is how a broken credential is replaced.
   */
  case anyAccount

  /// Links an account that is not linked yet; one that is, is refused.
  case newAccount

  /// Re-authorizes one particular account; any other is refused.
  case repairing(AccountIdentifier)
}

/// An in-progress account link.
public struct LinkFlow: Sendable {
  private let oauth: DropboxOAuthFlow
  private let manager: AccountManager
  private let intent: LinkIntent

  /// The URL to open in a browser for the user to authorize Zephyr.
  public var authorizationURL: URL { oauth.authorizationURL }

  /// The scheme Dropbox redirects back to, which a web authentication session
  /// matches its callback against, or `nil` when this flow expects a pasted code.
  public var callbackScheme: String? { oauth.callbackScheme }

  init(oauth: DropboxOAuthFlow, manager: AccountManager, intent: LinkIntent) {
    self.oauth = oauth
    self.manager = manager
    self.intent = intent
  }

  /// Completes the link with the code the user pasted.
  public func complete(code: String) async throws -> AccountSession {
    try await manager.finishLink(result: try await oauth.exchange(code: code), for: intent)
  }

  /**
   Completes the link with a web-authentication-session callback URL.

   The counterpart to ``complete(code:)`` for
   ``DropboxOAuthFlow/RedirectStyle/customScheme``.
   */
  public func complete(callbackURL: URL) async throws -> AccountSession {
    try await manager.finishLink(
      result: try await oauth.exchange(callbackURL: callbackURL),
      for: intent
    )
  }
}
