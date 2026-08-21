import Foundation

/**
 The account layer as a process reaches it when nothing has bootstrapped one:
 the accounts it may act as, what the index knows, and the handful of Dropbox
 operations built on top.

 Reached through ``shared`` rather than an injected dependency. Registering one
 happens during the app's own bootstrap, which would make a caller down here
 wait on the app layer above it — and on a cold start, where the request is
 what launched the app, wait on a race. A lazy global has neither problem, and
 because Swift defers it until first use, a process that never asks never
 reaches ``ZephyrEnvironment/standard`` and never needs the entitlement it
 insists on.

 That is what lets the Shortcuts actions and the Finder version-history sheet
 share it: an App Intent and an app extension are both processes with an app
 group and no app behind them.

 Two caches, and they are not the same cache. A session is held so that a
 request of several steps refreshes an access token once rather than once a
 step. An index is opened without one at all: a status reading and a name
 search are answers the index already holds, and routing them through a
 session would make them fail for an account whose authorization has lapsed —
 which is the moment somebody is most likely to ask what state syncing is in.
 */
public actor SharedAccountService {
  /// The instance every caller uses.
  public static let shared = SharedAccountService(
    manager: AccountManager(tokenStore: GroupKeychainTokenStore())
  )

  private let manager: AccountManager
  private let environment: ZephyrEnvironment
  private var sessions: [AccountIdentifier: AccountSession] = [:]
  private var indexes: [AccountIdentifier: SyncIndexStore] = [:]

  /**
   Creates a service over an account manager and a container.

   - Parameters:
     - manager: Where accounts and sessions come from.
     - environment: The shared container holding the indexes.
   */
  init(manager: AccountManager, environment: ZephyrEnvironment = .standard) {
    self.manager = manager
    self.environment = environment
  }

  func scriptableAccounts() async throws -> [AccountConfiguration] {
    var configurations: [AccountConfiguration] = []
    for account in try await manager.authenticatableAccounts() {
      configurations.append(try await manager.configuration(for: account))
    }
    return configurations.sorted {
      $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
    }
  }

  func configuration(
    for account: AccountIdentifier
  ) async throws -> AccountConfiguration {
    try await manager.configuration(for: account)
  }

  /// The index's row for an item, or `nil` when the account has no index or
  /// the item is not in it.
  public func indexedItem(
    _ item: DropboxFileIdentifier,
    in account: AccountIdentifier
  ) async throws -> IndexEntryRecord? {
    try await index(for: account)?.entry(forID: item)
  }

  func indexedItem(
    atPath path: DropboxPath,
    in account: AccountIdentifier
  ) async throws -> IndexEntryRecord? {
    try await index(for: account)?.entry(forPath: path.normalized)
  }

  func indexedItems(
    named text: String,
    in account: AccountIdentifier,
    limit: UInt
  ) async throws -> [IndexEntryRecord] {
    try await index(for: account)?.items(named: text, limit: limit) ?? []
  }

  func topLevelItems(in account: AccountIdentifier) async throws -> [IndexEntryRecord] {
    try await index(for: account)?.children(of: .root) ?? []
  }

  func folderPaths(in account: AccountIdentifier) async throws -> [DropboxPath] {
    try await index(for: account)?.folderPaths() ?? []
  }

  func syncStatus(of account: AccountIdentifier) async throws -> SyncStatus {
    guard let index = try index(for: account) else { return .notIndexed }
    return try await SyncStatus(reading: index)
  }

  func upload(
    _ file: URL,
    to path: DropboxPath,
    mode: WriteMode,
    in account: AccountIdentifier
  ) async throws -> FileMetadata {
    try await session(for: account).upload(file, to: path, mode: mode)
  }

  /// A file's stored revisions, most recent first.
  public func revisions(
    of item: DropboxFileIdentifier,
    in account: AccountIdentifier,
    limit: UInt
  ) async throws -> [FileMetadata] {
    // Addressed by identifier rather than path, so a file's history survives
    // the renames and moves that a path does not.
    try await session(for: account).revisions(of: .id(item), limit: limit)
  }

  /// Puts a file back to an earlier revision.
  public func restore(
    _ path: DropboxPath,
    to revision: FileRevision,
    in account: AccountIdentifier
  ) async throws -> FileMetadata {
    try await session(for: account).restore(path, to: revision)
  }

  /**
   A shared link for an item.

   Dropbox refuses to mint a second link for a path that already has one, so
   the answer to “give me a link for this” is often already on the server. A
   shortcut asked for a link, not for a link to be created, so the existing one
   is the right answer rather than an error.
   */
  func sharedLink(
    for path: DropboxPath,
    in account: AccountIdentifier
  ) async throws -> SharedLinkMetadata {
    let session = try await session(for: account)
    do {
      return try await session.createSharedLink(for: path)
    } catch let refusal as ItemSyncFailure {
      guard case .sharedLinkExists = refusal else { throw refusal }
      guard let existing = try await session.listSharedLinks(for: path).first else {
        throw refusal
      }
      return existing
    }
  }

  /// The account's session, opened once and kept.
  private func session(for account: AccountIdentifier) async throws -> AccountSession {
    if let existing = sessions[account] { return existing }
    let session = try await manager.session(for: account)
    sessions[account] = session
    return session
  }

  /**
   The account's index, opened read-only and kept, or `nil` when the account
   has never been indexed.

   Opened straight from the container rather than through a session: reading
   the index needs no credential, and the File Provider extension owns the
   read-write handle.
   */
  private func index(for account: AccountIdentifier) throws -> SyncIndexStore? {
    if let existing = indexes[account] { return existing }
    let url = environment.indexURL(for: account)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let index = try SyncIndexStore(url: url, mode: .readOnly)
    indexes[account] = index
    return index
  }
}

extension SharedAccountService: FileVersionsService {}
