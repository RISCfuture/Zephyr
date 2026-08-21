import Foundation
import os
import Synchronization

/**
 One linked account's operations: browsing, transfers, revisions, and shared
 links. The Maestral-object equivalent for everything below the sync engine.
 */
public actor AccountSession {
  /// How many revisions a surface lists when it has no reason to ask for a
  /// different number. Deep enough to reach past a run of automatic saves,
  /// short enough to read without scrolling.
  public static let defaultRevisionLimit: UInt = 10

  /// The client sending the account's path root, for all path-based calls
  /// somebody is waiting on.
  let client: DropboxClient
  /// The client without a path root, for account-level calls.
  let baseClient: DropboxClient
  /// The path-rooted client for work nobody asked for — the initial listing,
  /// delta pages, the change feed — which macOS may keep off a path that
  /// costs the user something.
  let bulkClient: DropboxClient

  let environment: ZephyrEnvironment
  private let registry: AccountRegistry
  private let storedConfiguration: Mutex<AccountConfiguration>
  private var configurationWatcher: Task<Void, Never>?

  /// The account's index, opened once for the session's own bookkeeping:
  /// resumable upload checkpoints and cached account names. Both features
  /// degrade to doing without when the index will not open.
  private var bookkeepingIndex: SyncIndexStore?

  /**
   The account's stored configuration.

   A snapshot of the file the registry keeps, refreshed whenever this session
   rewrites it and — for a session watching its configuration — whenever
   another process does.
   */
  nonisolated public var configuration: AccountConfiguration {
    storedConfiguration.withLock { $0 }
  }

  /// The linked account's identifier.
  nonisolated public let accountID: AccountIdentifier

  /// Whether the account's index database exists yet.
  nonisolated public var indexExists: Bool {
    FileManager.default.fileExists(atPath: environment.indexURL(for: accountID).path)
  }

  init(
    configuration: AccountConfiguration,
    refreshToken: String,
    environment: ZephyrEnvironment,
    registry: AccountRegistry
  ) {
    accountID = configuration.accountID
    storedConfiguration = Mutex(configuration)
    self.environment = environment
    self.registry = registry
    // Token refresh keeps the transport it makes for itself, which is a
    // user-initiated one. It is a few hundred bytes, every other call waits on
    // it, and putting it on the bulk session would turn a refused path into a
    // failure to authenticate.
    baseClient = DropboxClient(
      transport: URLSessionTransport(downloadThrottle: TransferPacing.downloadThrottle),
      tokenProvider: AccessTokenProvider(refreshToken: refreshToken),
      uploadThrottle: TransferPacing.uploadThrottle
    )
    client = baseClient.withPathRoot(PathRoot(namespaceID: configuration.rootNamespaceID))
    // No download throttle: nothing bulk fetches file contents, so there is no
    // second pacer to keep in step with the first.
    bulkClient = client.usingTransport(
      URLSessionTransport(traffic: .bulk(TransferPacing.expensiveNetworkPolicy))
    )
  }

  // MARK: Account

  /// Fetches the account's details from the API.
  public func accountInfo() async throws -> FullAccount {
    try await baseClient.currentAccount()
  }

  /// Fetches the account's storage usage.
  public func spaceUsage() async throws -> SpaceUsage {
    try await baseClient.spaceUsage()
  }

  // MARK: Attribution

  /**
   Names the accounts that last changed shared files, so a change can be
   reported as somebody's rather than as nobody's.

   The linked account answers from its own configuration: "I changed it" is
   the overwhelmingly common case, and it costs no request and introduces no
   second answer to who this Mac is signed in as. Everyone else is answered
   from the index's cache, and failing that from `users/get_account_batch`,
   whose answers are cached there for the processes that come after. An
   account Dropbox declines to name is simply absent from the result:
   attribution is a nicety, and a notification is better unattributed than
   unsent.

   - Parameter accounts: The identifiers to name, as a shared file's
     ``FileMetadata/modifiedBy`` and ``HistoryEventRecord/modifiedBy``
     report them. Duplicates cost nothing.
   - Returns: A display name for each account that could be named.
   */
  public func displayNames(
    ofAccounts accounts: [AccountIdentifier]
  ) async -> [AccountIdentifier: String] {
    var names: [AccountIdentifier: String] = [:]
    var unnamed = Set(accounts)
    if unnamed.remove(accountID) != nil {
      names[accountID] = configuration.displayName
    }
    guard !unnamed.isEmpty else { return names }

    let index = bookkeeping()
    if let cached = try? await index?.cachedAccountNames(for: Array(unnamed)) {
      names.merge(cached) { current, _ in current }
      unnamed.subtract(cached.keys)
    }
    guard !unnamed.isEmpty else { return names }

    let fetched = await fetchedDisplayNames(of: Array(unnamed))
    names.merge(fetched) { current, _ in current }
    try? await index?.cacheAccountNames(fetched)
    return names
  }

  /// Asks Dropbox to name accounts the cache could not. Dropbox fails a whole
  /// batch when it will not name one of its members — a departed teammate
  /// would otherwise cost everyone in the batch their name — so a rejected
  /// batch is retried one account at a time.
  private func fetchedDisplayNames(
    of accounts: [AccountIdentifier]
  ) async -> [AccountIdentifier: String] {
    do {
      return try await baseClient.accounts(accounts)
        .reduce(into: [AccountIdentifier: String]()) { $0[$1.accountID] = $1.displayName }
    } catch {
      ZephyrLog.engine.info(
        """
        users/get_account_batch named none of \(accounts.count, privacy: .public) accounts: \
        \(error.localizedDescription, privacy: .private)
        """
      )
      return await individuallyFetchedDisplayNames(of: accounts)
    }
  }

  private func individuallyFetchedDisplayNames(
    of accounts: [AccountIdentifier]
  ) async -> [AccountIdentifier: String] {
    typealias NamedAccount = (account: AccountIdentifier, displayName: String)

    let baseClient = baseClient
    return await withTaskGroup(of: NamedAccount?.self) { group in
      for account in accounts {
        group.addTask {
          guard let named = try? await baseClient.account(account) else { return nil }
          return (account, named.displayName)
        }
      }
      var names: [AccountIdentifier: String] = [:]
      for await named in group {
        guard let named else { continue }
        names[named.account] = named.displayName
      }
      return names
    }
  }

  // MARK: Path root

  /**
   Re-resolves the account's path root and retargets this session at it.

   Dropbox invalidates an account's root namespace when the member joins or
   leaves a team, and every path-based call fails with
   ``EngineFailure/pathRootChanged(newRoot:)`` until the new namespace is
   sent — a state no amount of retrying escapes. Catch that failure, call
   this, and retry the operation. It is worth calling proactively too: when a
   session starts watching an account, and when the change feed cycles, which
   is how a member moved between teams is noticed before anything fails.

   The namespace comes from `users/get_current_account` rather than from the
   rejection, because only the account record also says whether the new root
   is a team space and where the member's home folder sits inside it. The
   result is written back through the registry, so the next process to open
   the account starts with the right root.

   - Returns: Whether the root moved, and so whether a call Dropbox refused
     is now worth repeating.
   */
  @discardableResult
  public func refreshPathRoot() async throws -> Bool {
    let root = try await baseClient.currentAccount().rootInfo
    let previous = configuration.rootNamespaceID
    await adopt(try await registry.updateRoot(root, for: accountID))
    guard root.rootNamespaceID != previous else { return false }
    ZephyrLog.engine.warning(
      """
      Account path root moved from \(previous.rawValue, privacy: .public) to \
      \(root.rootNamespaceID.rawValue, privacy: .public)
      """
    )
    return true
  }

  // MARK: Configuration

  /**
   Applies configuration changes made by another process — a bandwidth limit
   set in the app's Settings pane or by `zephyr bandwidth`, a path root
   another process re-resolved — to this live session.

   Only a long-lived host needs this: a CLI invocation and the share
   extension each build a session, use it, and exit, so they read the current
   configuration anyway. The File Provider extension outlives many such
   changes, and ``makeProviderAdapter(scratchDirectory:)`` starts the watch on
   its behalf.
   */
  public func watchConfigurationChanges() {
    guard configurationWatcher == nil else { return }
    let changes = ChangeSignal.configuration(accountID).signals()
    configurationWatcher = Task { [weak self] in
      for await _ in changes {
        guard let self else { return }
        await adoptStoredConfiguration()
      }
    }
  }

  /**
   Keeps transfers paced to the limits that are set and to what the network
   currently asks for, for a process long-lived enough to see either change.

   A process built for one command reads both as it starts and is gone before
   they move. The File Provider extension runs across a whole afternoon of
   joining and leaving networks, and of somebody dragging a slider in a
   Settings pane it cannot see — and a limit that only applied at launch would
   be no limit at all.

   The pacing is the process's rather than this session's, so this only starts
   it; calling it from every session is how it comes to be started at all.
   */
  public func watchTransferPacing() {
    TransferPacing.start()
  }

  /// Re-reads the account's stored configuration and adopts it; one that
  /// cannot be read leaves the session on the configuration it already has.
  private func adoptStoredConfiguration() async {
    guard let stored = try? await registry.configuration(for: accountID) else { return }
    await adopt(stored)
  }

  /// Takes the configuration as the session's own: transfers pace to its
  /// bandwidth limits and path-based calls address its root namespace.
  private func adopt(_ configuration: AccountConfiguration) async {
    storedConfiguration.withLock { $0 = configuration }
    await client.adoptPathRoot(PathRoot(namespaceID: configuration.rootNamespaceID))
  }

  // MARK: Browsing

  /// Lists a folder, paging lazily as the caller iterates.
  nonisolated public func listFolder(
    _ path: DropboxPath,
    recursive: Bool = false,
    includeDeleted: Bool = false
  ) -> ListFolderSequence {
    ListFolderSequence(
      client: client,
      path: path,
      recursive: recursive,
      includeDeleted: includeDeleted
    )
  }

  // MARK: Transfers

  /// Downloads a file (optionally a pinned revision) with hash verification.
  public func download(
    _ path: DropboxPath,
    revision: FileRevision? = nil,
    to destination: URL
  ) async throws -> FileMetadata {
    let specifier: PathSpecifier = if let revision { .revision(revision) } else { .path(path) }
    return try await FileDownloader(client: client).download(specifier, to: destination)
  }

  /**
   Uploads a local file with Maestral's lost-update guards, checkpointing a
   chunked upload into the index so a later attempt can resume it.
   */
  public func upload(
    _ localURL: URL,
    to path: DropboxPath,
    mode: WriteMode = .add,
    autorename: Bool = true
  ) async throws -> FileMetadata {
    try await FileUploader(client: client, checkpointingInto: bookkeeping()).upload(
      localURL,
      to: path,
      mode: mode,
      autorename: autorename
    )
  }

  // MARK: Manipulation

  /// Deletes a file (optionally revision-guarded) or folder.
  public func delete(_ path: DropboxPath, parentRevision: FileRevision? = nil) async throws
    -> ItemMetadata
  {
    try await client.delete(.path(path), parentRevision: parentRevision)
  }

  /// Moves or renames server-side.
  public func move(from source: DropboxPath, to destination: DropboxPath) async throws
    -> ItemMetadata
  {
    try await client.move(from: .path(source), to: destination)
  }

  /// Creates a folder.
  public func createFolder(at path: DropboxPath) async throws -> FolderMetadata {
    try await client.createFolder(at: path)
  }

  // MARK: Revisions

  /**
   Lists a file's stored revisions, most recent first.

   Address the file by ``PathSpecifier/id(_:)`` to follow it through the
   renames and moves it survived; a path lists the revisions of whatever
   occupies that path now, which is where a renamed file's history appears
   to stop.
   */
  public func revisions(
    of specifier: PathSpecifier,
    limit: UInt = defaultRevisionLimit
  ) async throws -> [FileMetadata] {
    try await client.revisions(of: specifier, limit: limit)
  }

  /// Restores a file to an earlier revision.
  public func restore(_ path: DropboxPath, to revision: FileRevision) async throws -> FileMetadata {
    try await client.restore(path, to: revision)
  }

  // MARK: Shared links

  /// Creates a shared link.
  public func createSharedLink(
    for path: DropboxPath,
    settings: SharedLinkSettings = SharedLinkSettings()
  ) async throws -> SharedLinkMetadata {
    try await client.createSharedLink(for: path, settings: settings)
  }

  /// Revokes a shared link.
  public func revokeSharedLink(_ url: URL) async throws {
    try await client.revokeSharedLink(url)
  }

  /// Lists shared links, optionally for one path.
  public func listSharedLinks(for path: DropboxPath? = nil) async throws -> [SharedLinkMetadata] {
    var links: [SharedLinkMetadata] = []
    var cursor: String?
    repeat {
      let result = try await client.listSharedLinks(for: path, cursor: cursor)
      links.append(contentsOf: result.links)
      cursor = result.hasMore ? result.cursor : nil
    } while cursor != nil
    return links
  }

  // MARK: Sync index

  /// Opens the account's sync index database.
  public func openIndex(mode: SyncIndexStore.AccessMode = .readWrite) throws -> SyncIndexStore {
    try environment.ensureAccountDirectories(for: accountID)
    return try SyncIndexStore(
      url: environment.indexURL(for: accountID),
      mode: mode,
      changeSignal: mode == .readWrite ? .index(accountID) : nil
    )
  }

  /// The index this session keeps its own bookkeeping in, opened for writing
  /// when it can be and for reading when it cannot — the app reads a cache
  /// the File Provider extension fills.
  private func bookkeeping() -> SyncIndexStore? {
    if let bookkeepingIndex { return bookkeepingIndex }
    bookkeepingIndex = (try? openIndex()) ?? (try? openIndex(mode: .readOnly))
    return bookkeepingIndex
  }

  /**
   Creates the remote indexer that keeps the index mirroring Dropbox, able to
   re-resolve the account's path root when Dropbox rejects one.

   Its work is Zephyr's own errand, so it rides the bulk client and macOS may
   keep it off a path that costs the user something.
   */
  public func makeIndexer() throws -> RemoteIndexer {
    try makeIndexer(over: bulkClient)
  }

  private func makeIndexer(over client: DropboxClient) throws -> RemoteIndexer {
    RemoteIndexer(
      client: client,
      store: try openIndex(),
      refreshPathRoot: { try await self.refreshPathRoot() }
    )
  }

  /**
   Drops the index and rebuilds it from a fresh recursive listing.

   The attributes Dropbox does not store — Finder tags, favorite ranks,
   last-used dates, extended attributes, and the ignore marker — survive the
   rebuild; the File Provider re-enumerates the domain because the rebuild
   expires every sync anchor.

   Somebody asked for this by name and is watching it run, so it goes over
   the user-initiated client even though it is the largest listing Zephyr
   ever does. Refusing a command the user typed, with no way to insist, would
   be worse than the traffic.
   */
  public func rebuildIndex() async throws {
    try await makeIndexer(over: client).rebuildIndex()
  }

  /**
   Dismisses the sync failure recorded against `path`, which is how a user
   clears an error whose cause they have dealt with — the next attempt at
   the item records a fresh one if it fails again.
   */
  public func dismissSyncError(at path: NormalizedDropboxPath) async throws {
    try await openIndex(mode: .readWrite).clearSyncError(forPath: path)
  }

  // MARK: Change feed

  /**
   Waits for remote changes after a cursor (longpoll).

   The change feed is Zephyr's own errand, not anybody's request, so it
   rides the bulk session and stays off a path that costs the user.
   */
  public func waitForChanges(after cursor: DeltaCursor) async throws -> LongpollResult {
    try await bulkClient.waitForChanges(after: cursor)
  }
}
