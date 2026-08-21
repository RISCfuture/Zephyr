@preconcurrency import FileProvider
import Foundation
import libZephyr
import os

/**
 Keeps the registered File Provider domains matching the linked accounts: one
 domain per account, identified by the account identifier's domain form
 (`AccountIdentifier.providerDomainIdentifier`, since domain identifiers
 forbid the `:` in the raw `dbid:` value).
 */
enum DomainManager {
  /**
   The failures the system latches onto a domain until the provider says they
   are resolved.

   `NSFileProviderErrorMapping` returns exactly these three for an account
   that can't authenticate, can't reach Dropbox, or has run out of room, and
   Apple documents each as requiring ``signalErrorsResolved(for:)`` once the
   condition clears — nothing else takes the error out of Finder.
   */
  private static let latchingErrorCodes: [NSFileProviderError.Code] = [
    .notAuthenticated, .serverUnreachable, .insufficientQuota
  ]

  /// Adds domains for newly linked accounts, removes domains whose account is
  /// gone, and re-registers domains an older build left settings on.
  static func reconcile(with configurations: [AccountConfiguration]) async throws {
    try await migrateDomainRegistrations(in: try await NSFileProviderManager.domains())
    let existing = try await NSFileProviderManager.domains()
    try await addMissingDomains(for: configurations, existing: existing)
    try await removeOrphanedDomains(in: existing, linked: configurations)
  }

  /// Removes the domain for one account, succeeding when none is registered.
  static func removeDomain(for account: AccountIdentifier) async throws {
    guard let domain = try await domain(for: account) else { return }
    try await NSFileProviderManager.remove(domain)
    forgetRegistrationVersion(of: account)
  }

  /// The registered domain for one account, or `nil` when none is registered.
  static func domain(for account: AccountIdentifier) async throws -> NSFileProviderDomain? {
    let identifier = NSFileProviderDomainIdentifier(rawValue: account.providerDomainIdentifier)
    return try await NSFileProviderManager.domains().first { $0.identifier == identifier }
  }

  /**
   Tells the system that whatever stopped the account has cleared.

   Call it whenever Zephyr proves the account works again — a fresh link, a
   longpoll that came back, a credential check that passed. Until then the
   system keeps reporting the last failure it was handed, however long ago
   the user fixed it.
   */
  static func signalErrorsResolved(for account: AccountIdentifier) async {
    guard let manager = try? await providerManager(for: account) else { return }
    await withTaskGroup(of: Void.self) { group in
      for code in latchingErrorCodes {
        group.addTask { try? await manager.signalErrorResolved(NSFileProviderError(code)) }
      }
    }
  }

  /// Asks the system to re-enumerate an account's working set, which is how
  /// a change the app made to the index reaches Finder.
  static func signalWorkingSet(for account: AccountIdentifier) async {
    guard let manager = try? await providerManager(for: account) else { return }
    try? await manager.signalEnumerator(for: .workingSet)
  }

  /// The user-visible location of one item, security-scoped for a sandboxed
  /// caller, or `nil` when the account has no domain or the system won't say.
  static func userVisibleURL(
    of item: NSFileProviderItemIdentifier,
    in account: AccountIdentifier
  ) async -> URL? {
    guard let manager = try? await providerManager(for: account) else { return nil }
    return try? await manager.getUserVisibleURL(for: item)
  }

  /// An account's domain registration in one line, for a diagnostics report.
  static func domain(forDiagnostics account: AccountIdentifier) async -> String {
    guard let domain = try? await domain(for: account) else { return "not registered" }
    return domain.isDisconnected ? "registered, disconnected" : "registered, connected"
  }

  private static func providerManager(
    for account: AccountIdentifier
  ) async throws -> NSFileProviderManager? {
    guard let domain = try await domain(for: account) else { return nil }
    return NSFileProviderManager(for: domain)
  }

  private static func addMissingDomains(
    for configurations: [AccountConfiguration],
    existing: [NSFileProviderDomain]
  ) async throws {
    let existingIdentifiers = Set(existing.map(\.identifier.rawValue))
    let missing = configurations.filter {
      !existingIdentifiers.contains($0.accountID.providerDomainIdentifier)
    }
    guard !missing.isEmpty else { return }
    // Sampled before the first domain joins, because a domain that joins
    // connected is itself an answer to this question.
    let joinsPausedSyncing = await DomainConnection.areAllDisconnected()
    for configuration in missing {
      try await add(domain(for: configuration), disconnected: joinsPausedSyncing)
      stampRegistrationVersion(of: configuration.accountID)
    }
  }

  /**
   Registers one domain, stopping it when the Mac it joins has syncing paused.

   Pause is not a flag Zephyr stores: it is every registered domain being
   disconnected, and nothing else. So a domain that arrives connected does not
   merely miss the pause — it ends it, for accounts the user never resumed,
   while every surface goes on reporting syncing as running.
   */
  private static func add(_ domain: NSFileProviderDomain, disconnected: Bool) async throws {
    try await NSFileProviderManager.add(domain)
    guard disconnected else { return }
    try await DomainConnection.disconnect(domain)
  }

  private static func removeOrphanedDomains(
    in existing: [NSFileProviderDomain],
    linked configurations: [AccountConfiguration]
  ) async throws {
    let linkedAccounts = Set(configurations.map(\.accountID))
    for domain in existing where !belongsToLinkedAccount(domain, in: linkedAccounts) {
      try await NSFileProviderManager.remove(domain)
      if let account = account(of: domain) { forgetRegistrationVersion(of: account) }
    }
  }

  private static func belongsToLinkedAccount(
    _ domain: NSFileProviderDomain,
    in accounts: Set<AccountIdentifier>
  ) -> Bool {
    guard let account = account(of: domain) else { return false }
    return accounts.contains(account)
  }

  /// The account a registered domain belongs to, or `nil` for a domain whose
  /// identifier no account goes by.
  private static func account(of domain: NSFileProviderDomain) -> AccountIdentifier? {
    try? AccountIdentifier(providerDomainIdentifier: domain.identifier.rawValue)
  }

  private static func domain(for configuration: AccountConfiguration) -> NSFileProviderDomain {
    let domain = NSFileProviderDomain(
      identifier: NSFileProviderDomainIdentifier(
        rawValue: configuration.accountID.providerDomainIdentifier
      ),
      // This is the Finder sidebar's label for the account. It names Zephyr,
      // not Dropbox: the row is what Zephyr serves, and a location that says
      // only "Dropbox" reads as the official client's.
      //
      // Only a domain being registered for the first time takes this name. A
      // domain that already exists keeps the label it was created with, because
      // the only way to relabel one is to remove and re-add it — see
      // ``currentRegistrationVersion`` for what that costs.
      displayName: String(localized: "Zephyr (\(configuration.email))", bundle: #bundle)
    )
    // Dropbox has no trash API; deletes fall back to revision history.
    domain.supportsSyncingTrash = false
    return domain
  }
}

// MARK: Registration versions

extension DomainManager {
  /**
   The version of the domain registration this build writes.

   A domain's settings live with its registration, so the only way to change
   them on a domain that already exists is to remove it and add it again —
   which throws away the account's local replica and makes the system
   re-download everything the user had materialized. That is too expensive to
   guess at, so every registration is stamped with the version that wrote it
   and a build that needs different settings names the versions it is
   replacing in ``needsReregistration(_:registeredBy:)``.

   Raise this only alongside a settings change, and only with a matching
   migration. A version that needs no migration removes nothing.
   */
  private static var currentRegistrationVersion: Int { 1 }

  private static var registrationVersionKeyPrefix: String { "domainRegistrationVersion-" }

  /// The stamps live in the shared container, beside the accounts they
  /// describe, so every Zephyr process reads the same answer.
  private static var registrationDefaults: UserDefaults? {
    UserDefaults(suiteName: ZephyrEnvironment.appGroupIdentifier)
  }

  /**
   Removes the domains an older build registered with settings this build
   can't live with, so ``reconcile(with:)`` registers them again.

   The stamp is what makes this targeted: a domain registered by this build
   is never a candidate, whatever its settings say.
   */
  private static func migrateDomainRegistrations(
    in existing: [NSFileProviderDomain]
  ) async throws {
    for domain in existing {
      guard let account = account(of: domain) else { continue }
      guard needsReregistration(domain, registeredBy: registrationVersion(of: account)) else {
        stampRegistrationVersion(of: account)
        continue
      }
      try await NSFileProviderManager.remove(domain)
      forgetRegistrationVersion(of: account)
    }
  }

  /**
   Whether a domain registered at `version` has to be registered again.

   Version 0 is a domain from a build that stamped nothing. Those builds
   registered the domain with trash syncing on, which Dropbox has no API to
   serve, so the flag is the evidence that a version-0 domain came from one
   of them — and a version-0 domain without it was registered correctly and
   is left alone. Nothing consults the flag once a domain carries a stamp.
   */
  private static func needsReregistration(
    _ domain: NSFileProviderDomain,
    registeredBy version: Int
  ) -> Bool {
    guard version < currentRegistrationVersion else { return false }
    return version == 0 && domain.supportsSyncingTrash
  }

  /// Which build registered the account's domain; zero for a domain
  /// registered before Zephyr stamped its registrations.
  private static func registrationVersion(of account: AccountIdentifier) -> Int {
    registrationDefaults?.integer(forKey: registrationVersionKey(for: account)) ?? 0
  }

  private static func stampRegistrationVersion(of account: AccountIdentifier) {
    registrationDefaults?.set(
      currentRegistrationVersion,
      forKey: registrationVersionKey(for: account)
    )
  }

  private static func forgetRegistrationVersion(of account: AccountIdentifier) {
    registrationDefaults?.removeObject(forKey: registrationVersionKey(for: account))
  }

  private static func registrationVersionKey(for account: AccountIdentifier) -> String {
    registrationVersionKeyPrefix + account.rawValue
  }
}

// MARK: Pending set

extension DomainManager {
  /**
   How many items each account is still waiting to send to Dropbox, as the
   system counts them.

   This is the outbound backlog and nothing else: the pending set holds the
   items the system has taken from disk and not yet handed to the extension.
   An account whose count can't be read is left out rather than reported as
   zero, so a failure reads as "not known" instead of "nothing to do".
   */
  static func pendingItemCounts() async -> [AccountIdentifier: UInt] {
    guard let domains = try? await NSFileProviderManager.domains() else { return [:] }
    return await withTaskGroup(of: (account: AccountIdentifier, count: UInt?).self) { group in
      for domain in domains {
        guard let account = account(of: domain),
          let manager = NSFileProviderManager(for: domain)
        else { continue }
        group.addTask { (account, await pendingItemCount(readBy: manager)) }
      }
      return await group.reduce(into: [:]) { counts, pending in
        counts[pending.account] = pending.count
      }
    }
  }

  /// How many items one domain has pending, or `nil` when its enumerator
  /// couldn’t be read to the end.
  private static func pendingItemCount(readBy manager: NSFileProviderManager) async -> UInt? {
    guard
      let count = try? await PendingSetReader(
        enumerator: manager.enumeratorForPendingItems()
      ).itemCount()
    else { return nil }
    return UInt(count)
  }
}

/**
 Drives the system's pending-set enumerator to completion and reports how many
 items it holds.

 The enumerator and its observer come from a pre-concurrency Objective-C
 protocol whose callbacks arrive on the system's own queues; the count and the
 continuation are held behind the lock, which is what makes the unchecked
 conformance safe.
 */
private final class PendingSetReader: NSObject, NSFileProviderEnumerationObserver,
  @unchecked Sendable
{
  /// The page the pending set starts from: like the materialized set, its
  /// listing has no sort order for the initial-page constants to choose.
  private static var firstPage: NSFileProviderPage { NSFileProviderPage(Data()) }

  /// How long the system gets to finish before the read gives up. Every
  /// account is read at once, so this bounds one enumerator alone: one that
  /// never calls back costs its own account’s count and nothing else.
  private static var readTimeout: Duration { .seconds(15) }

  private let enumerator: any NSFileProviderEnumerator
  private let state = OSAllocatedUnfairLock(initialState: State())

  init(enumerator: any NSFileProviderEnumerator) {
    self.enumerator = enumerator
    super.init()
  }

  /// How many items are pending, in one pass over the enumerator.
  func itemCount() async throws -> Int {
    try await withCheckedThrowingContinuation { continuation in
      state.withLock { $0.continuation = continuation }
      abandonReadAfterTimeout()
      enumerator.enumerateItems(for: self, startingAt: Self.firstPage)
    }
  }

  func didEnumerate(_ items: [any NSFileProviderItemProtocol]) {
    state.withLock { $0.count += items.count }
  }

  func finishEnumerating(upTo nextPage: NSFileProviderPage?) {
    guard let nextPage else {
      finish(with: .success(state.withLock { $0.count }))
      return
    }
    enumerator.enumerateItems(for: self, startingAt: nextPage)
  }

  func finishEnumeratingWithError(_ error: any Error) {
    finish(with: .failure(error))
  }

  private func abandonReadAfterTimeout() {
    Task { [weak self] in
      try? await Task.sleep(for: Self.readTimeout)
      self?.finish(with: .failure(PendingSetUnread()))
    }
  }

  /// Resumes the read, once. A second call — the timeout arriving after the
  /// enumeration finished, or the reverse — finds no continuation and does
  /// nothing.
  private func finish(with result: Result<Int, any Error>) {
    let continuation = state.withLock { locked in
      defer { locked.continuation = nil }
      return locked.continuation
    }
    continuation?.resume(with: result)
  }

  private struct State {
    var count = 0
    var continuation: CheckedContinuation<Int, any Error>?
  }
}

/// The pending set couldn't be read. It never reaches the user: an account
/// with no count reads as one whose backlog isn't known, which is what it is.
private struct PendingSetUnread: Error {}
