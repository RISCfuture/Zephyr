public import FileProvider
import Foundation
import os

/**
 The File Provider extension's engine-facing brain: answers item, enumeration,
 change, and content requests from the sync index, reaching out to Dropbox only
 for catch-up indexing, change pages, and file content.

 Anchors handed to the system are generations recorded in the index's `anchors`
 table; each maps back to the delta cursor the index reflected at that moment.
 */
public actor ProviderAdapter {
  /// How many items a working-set page carries.
  private static let domainPageSize = 500

  /// How many index rows one working-set page reads through before yielding.
  /// The working set is a sparse subset of a large index, so a page has to
  /// scan past the items it leaves out — but not the whole index in one call.
  private static let workingSetScanBudget = 5_000

  let store: SyncIndexStore
  let client: DropboxClient
  /// The client for indexing the account, which nobody is waiting on.
  let bulkClient: DropboxClient
  let scratchDirectory: URL
  let rootType: AccountRootType
  let refreshPathRoot: PathRootRefresh?
  private var catchUpTask: Task<Void, any Error>?
  private var sweptScratch = false

  /// The items the system holds on disk, or `nil` until it reports them.
  private var materializedIdentifiers: Set<DropboxFileIdentifier>?

  /// The folders whose children the system holds on disk. The domain's root
  /// directory always exists, so its children are always represented there.
  private var materializedContainerPaths: Set<NormalizedDropboxPath> = [.root]

  private var workingSetSelection: WorkingSetSelection {
    WorkingSetSelection(
      materializedIdentifiers: materializedIdentifiers,
      materializedContainerPaths: materializedContainerPaths
    )
  }

  /**
   Creates an adapter over one account's sync index.

   - Parameters:
     - store: The account's sync index, opened read-write.
     - client: The account's path-rooted Dropbox client, for the work the
       system and the user are waiting on.
     - bulkClient: The client for keeping the index current, which macOS may
       hold back on a path that costs the user something; defaults to
       `client`.
     - scratchDirectory: Where fetched file contents are staged.
     - rootType: Whether the domain's root is a team space, which a folder
       created at the root has to be shared into.
     - refreshPathRoot: Re-resolves the account's path root when Dropbox
       refuses a write because the root moved.
   */
  public init(
    store: SyncIndexStore,
    client: DropboxClient,
    bulkClient: DropboxClient? = nil,
    scratchDirectory: URL,
    rootType: AccountRootType = .personal,
    refreshPathRoot: PathRootRefresh? = nil
  ) {
    self.store = store
    self.client = client
    self.bulkClient = bulkClient ?? client
    self.scratchDirectory = scratchDirectory
    self.rootType = rootType
    self.refreshPathRoot = refreshPathRoot
  }

  static func contentVersion(of entry: IndexEntryRecord) -> Data {
    entry.contentHash.map { Data($0.rawValue.utf8) } ?? Data()
  }

  // MARK: Items

  /// The item for a File Provider identifier.
  public func item(for identifier: NSFileProviderItemIdentifier) async throws -> ProviderItem {
    guard identifier != .rootContainer else { return .root }
    guard let id = try? DropboxFileIdentifier(validating: identifier.rawValue),
      let entry = try await store.entry(forID: id)
    else {
      throw NSFileProviderError(.noSuchItem)
    }
    return try await providerItem(for: entry)
  }

  /// The direct children of a container, sorted by name.
  public func children(of container: NSFileProviderItemIdentifier) async throws -> [ProviderItem] {
    let signposter = ZephyrLog.signposter
    let state = signposter.beginInterval(
      "Enumerate container",
      id: signposter.makeSignpostID()
    )
    var count = 0
    defer {
      signposter.endInterval("Enumerate container", state, "children: \(count, privacy: .public)")
    }
    let recordingPath = await knownPath(of: container)
    let children = try await recordingSyncErrors(at: recordingPath) {
      try await bringIndexCurrentIfIncomplete()
      let path = try await containerPath(of: container)
      return try await store.children(of: path)
        .map { ProviderItem(record: $0, parentIdentifier: container) }
    }
    count = children.count
    return children
  }

  /// The container's cased path as the index knows it right now, falling back
  /// to the domain root. Enough to record a failure against before the
  /// catch-up that the authoritative lookup may still be waiting on.
  private func knownPath(of container: NSFileProviderItemIdentifier) async -> DropboxPath {
    guard container != .rootContainer,
      let id = try? DropboxFileIdentifier(validating: container.rawValue),
      let entry = try? await store.entry(forID: id)
    else {
      return .root
    }
    return entry.pathCased
  }

  // MARK: Working set

  /**
   One page of the working set, resuming after an opaque page token.

   The working set is the set of items the system keeps available to itself
   regardless of the user's browsing history: everything recently used,
   tagged or favorited, everything that exists only on this Mac, and
   everything whose parent folder the system holds on disk. The rest of the
   index the system fetches when the user browses to it.
   */
  public func domainItems(after token: UInt64?) async throws -> DomainPage {
    try await recordingSyncErrors(at: .root) {
      try await domainItems(after: token, limit: Self.domainPageSize)
    }
  }

  func domainItems(after token: UInt64?, limit: Int) async throws -> DomainPage {
    let signposter = ZephyrLog.signposter
    let state = signposter.beginInterval(
      "Enumerate working set",
      id: signposter.makeSignpostID()
    )
    var items: [ProviderItem] = []
    var scanned = 0
    defer {
      signposter.endInterval(
        "Enumerate working set",
        state,
        "items: \(items.count, privacy: .public), scanned: \(scanned, privacy: .public)"
      )
    }
    if token == nil {
      try await bringIndexCurrentIfIncomplete()
    }
    let selection = workingSetSelection
    var watermark = token.map(Int64.init)
    while items.count < limit, scanned < Self.workingSetScanBudget {
      let rows = try await store.entries(afterRowID: watermark, limit: UInt(limit))
      scanned += rows.count
      watermark = rows.last?.rowID ?? watermark
      for (_, entry) in rows where selection.includes(entry) {
        items.append(try await providerItem(for: entry))
      }
      // A short read is the end of the index.
      guard rows.count == limit else { return DomainPage(items: items, nextToken: nil) }
    }
    return DomainPage(items: items, nextToken: watermark.map(UInt64.init))
  }

  /**
   Records which items the system currently holds on disk, as reported by
   `NSFileProviderManager`'s materialized-set enumerator.

   A provider that does not track the materialized set has to treat its whole
   dataset as the working set, because it cannot tell which items the system
   is relying on it to keep fresh. This adapter does exactly that until the
   first call, and narrows the working set from then on.
   */
  public func recordMaterializedItems(_ identifiers: [NSFileProviderItemIdentifier]) async {
    var materialized: Set<DropboxFileIdentifier> = []
    var containers: Set<NormalizedDropboxPath> = [.root]
    for identifier in identifiers {
      guard let id = try? DropboxFileIdentifier(validating: identifier.rawValue) else { continue }
      materialized.insert(id)
      if let entry = try? await store.entry(forID: id), entry.itemType == .folder {
        containers.insert(entry.pathNormalized)
      }
    }
    materializedIdentifiers = materialized
    materializedContainerPaths = containers
  }

  // MARK: Change tracking

  /// The anchor for the index's current state, recording one when none exists yet.
  public func currentAnchor() async throws -> UInt64 {
    if let latest = try await store.latestAnchor() {
      return latest.generation
    }
    if let cursor = try await store.currentCursor() {
      return try await store.recordAnchor(cursor: cursor)
    }
    try await bringIndexCurrentIfIncomplete()
    guard let cursor = try await store.currentCursor() else {
      throw NSFileProviderError(.syncAnchorExpired)
    }
    return try await store.recordAnchor(cursor: cursor)
  }

  /**
   Reports one page of remote changes since an anchor.

   A generation the index has already advanced past replays its recorded
   successor page — a fresh server page would be diffed against pre-apply
   state that no longer exists. The newest generation fetches and applies one
   `list_folder/continue` page.

   An unknown (pruned or never-issued) generation and a server-side cursor
   reset both surface as `NSFileProviderError.syncAnchorExpired`, telling the
   system to re-enumerate from scratch; a cursor reset also drops the index.
   */
  public func changes(fromAnchor generation: UInt64) async throws -> ChangeBatch {
    let signposter = ZephyrLog.signposter
    let state = signposter.beginInterval("Enumerate changes", id: signposter.makeSignpostID())
    var updated = 0, removed = 0
    defer {
      signposter.endInterval(
        "Enumerate changes",
        state,
        "updated: \(updated, privacy: .public), removed: \(removed, privacy: .public)"
      )
    }
    let batch = try await recordingSyncErrors(at: .root) {
      try await applyChanges(fromAnchor: generation)
    }
    updated = batch.updated.count
    removed = batch.removed.count
    return batch
  }

  private func applyChanges(fromAnchor generation: UInt64) async throws -> ChangeBatch {
    guard let cursor = try await store.cursor(forAnchorGeneration: generation) else {
      throw NSFileProviderError(.syncAnchorExpired)
    }
    if let recorded = try await store.recordedChanges(afterGeneration: generation) {
      return try await changeBatch(from: recorded, moreComing: !recorded.isLatest)
    }
    let page: ListFolderPage
    do {
      page = try await client.listFolderContinue(from: cursor)
    } catch EngineFailure.cursorReset {
      try await store.resetSyncState()
      throw NSFileProviderError(.syncAnchorExpired)
    }
    let interpretation = try await interpret(page)
    let applied = try await store.applyDeltaPageRecordingAnchor(
      interpretation.mutations,
      history: interpretation.history,
      advancingCursorTo: page.cursor
    )
    return try await changeBatch(from: applied, moreComing: page.hasMore)
  }

  private func changeBatch(
    from applied: SyncIndexStore.AppliedChangeSet,
    moreComing: Bool
  ) async throws -> ChangeBatch {
    var updated: [ProviderItem] = []
    for id in applied.updatedIDs {
      // A recorded update whose row is gone was removed by a later
      // generation; that generation's replay reports the removal.
      guard let entry = try await store.entry(forID: id) else { continue }
      // An unresolvable parent means the page is internally
      // inconsistent; a later change or re-enumeration delivers it.
      if let item = try await resolvableProviderItem(for: entry) {
        updated.append(item)
      }
    }
    return ChangeBatch(
      updated: updated,
      removed: applied.removedIDs.map { NSFileProviderItemIdentifier($0.rawValue) },
      anchor: applied.generation,
      moreComing: moreComing
    )
  }

  // MARK: Contents

  /**
   Downloads a file's contents to a fresh scratch location, pinned to the
   revision the index knows.

   Throws `NSFileProviderError.versionNoLongerAvailable` when the caller
   requests a content version the index has already moved past.
   */
  public func fetchContents(
    for identifier: NSFileProviderItemIdentifier,
    requestedVersion: NSFileProviderItemVersion?
  ) async throws -> (URL, ProviderItem) {
    // Wraps the whole answer, not just the transfer nested inside it: what
    // the system waits for is the lookup and the staging too, and only the
    // difference between the two intervals says which of them to go after.
    let signposter = ZephyrLog.signposter
    let state = signposter.beginInterval("Fetch contents", id: signposter.makeSignpostID())
    defer { signposter.endInterval("Fetch contents", state) }
    guard let id = try? DropboxFileIdentifier(validating: identifier.rawValue),
      let entry = try await store.entry(forID: id)
    else {
      throw NSFileProviderError(.noSuchItem)
    }
    return try await recordingSyncErrors(at: entry.pathCased) {
      try await stageContents(of: entry, requestedVersion: requestedVersion)
    }
  }

  /// Puts the item's contents on disk, from the shadow copy of an ignored
  /// item or from Dropbox, and reports where they landed.
  private func stageContents(
    of entry: IndexEntryRecord,
    requestedVersion: NSFileProviderItemVersion?
  ) async throws -> (URL, ProviderItem) {
    guard entry.itemType != .folder else {
      throw ItemSyncFailure.isAFolder(path: entry.pathCased.rawValue)
    }
    guard let revision = entry.revision else {
      throw ItemSyncFailure.unsupportedFile(path: entry.pathCased.rawValue)
    }
    if let requestedContent = requestedVersion?.contentVersion,
      requestedContent != Self.contentVersion(of: entry)
    {
      throw NSFileProviderError(.versionNoLongerAvailable)
    }
    let destination = try freshScratchLocation()
    // An ignored item edited locally has contents no Dropbox revision
    // holds; the shadow copy stashed at edit time is the only source.
    if entry.ignored, let shadow = shadowContents(matching: entry) {
      // A shadow read is not a fast download; a trace that could not tell
      // them apart would credit the network with the saving.
      ZephyrLog.signposter.emitEvent("Materialize from shadow copy")
      try FileManager.default.copyItem(at: shadow, to: destination)
      return (destination, try await providerItem(for: entry))
    }
    ZephyrLog.transfers.debug("Downloading \(entry.pathCased.rawValue, privacy: .private)")
    do {
      let signposter = ZephyrLog.signposter
      let state = signposter.beginInterval(
        "Materialize",
        id: signposter.makeSignpostID(),
        "bytes: \(entry.size ?? 0, privacy: .public)"
      )
      defer { signposter.endInterval("Materialize", state) }
      _ = try await FileDownloader(client: client).download(.revision(revision), to: destination)
    } catch {
      ZephyrLog.transfers.error(
        """
        Download of \(entry.pathCased.rawValue, privacy: .private) failed: \
        \(String(describing: error), privacy: .private)
        """
      )
      try? FileManager.default.removeItem(at: destination)
      // The route error blames the revision the request pinned; the user
      // needs the file it belongs to.
      throw (error as? ItemSyncFailure)?.retargeted(to: entry.pathCased.rawValue) ?? error
    }
    return (destination, try await providerItem(for: entry))
  }

  /// An unused path in the scratch directory for content on its way to or
  /// from Dropbox.
  func freshScratchLocation() throws -> URL {
    sweepScratchOnFirstUse()
    try FileManager.default.createDirectory(
      at: scratchDirectory,
      withIntermediateDirectories: true
    )
    return scratchDirectory.appendingPathComponent(UUID().uuidString)
  }

  /// Clears staged files a previous extension instance left behind; a new
  /// instance only exists after the old one was invalidated, so anything
  /// still in the scratch directory is an orphan.
  private func sweepScratchOnFirstUse() {
    guard !sweptScratch else { return }
    sweptScratch = true
    let leftovers =
      (try? FileManager.default.contentsOfDirectory(
        at: scratchDirectory,
        includingPropertiesForKeys: nil
      )) ?? []
    for leftover in leftovers
    where leftover.lastPathComponent != Self.shadowDirectoryName {
      try? FileManager.default.removeItem(at: leftover)
    }
  }

  // MARK: Item resolution

  func providerItem(for entry: IndexEntryRecord) async throws -> ProviderItem {
    ProviderItem(
      record: entry,
      parentIdentifier: try await parentIdentifier(of: entry) ?? .rootContainer
    )
  }

  /// The item, or `nil` when its parent is missing from the index — callers
  /// reporting changes skip such items rather than misparent them at root.
  func resolvableProviderItem(for entry: IndexEntryRecord) async throws -> ProviderItem? {
    guard let parent = try await parentIdentifier(of: entry) else { return nil }
    return ProviderItem(record: entry, parentIdentifier: parent)
  }

  private func parentIdentifier(
    of entry: IndexEntryRecord
  ) async throws -> NSFileProviderItemIdentifier? {
    let parentPath = entry.parentPathNormalized
    guard !parentPath.isRoot else { return .rootContainer }
    if let parent = try await store.entry(forPath: parentPath) {
      return NSFileProviderItemIdentifier(parent.dbxID.rawValue)
    }
    // A change page can name a parent the index has never seen (Dropbox
    // pages are not snapshot-consistent); fetching it closes the gap
    // without waiting for a later page.
    guard let fetched = await fetchAndIndexFolder(at: parentPath) else { return nil }
    return NSFileProviderItemIdentifier(fetched.dbxID.rawValue)
  }

  private func fetchAndIndexFolder(at path: NormalizedDropboxPath) async -> IndexEntryRecord? {
    guard let displayPath = try? DropboxPath(validating: path.rawValue),
      let metadata = try? await client.metadata(for: .path(displayPath)),
      case .folder(let folder) = metadata,
      let record = DeltaInterpreter.folderRecord(folder)
    else { return nil }
    try? await store.applyLocalChange([.upsert(record)])
    return try? await store.entry(forID: record.dbxID)
  }

  private func containerPath(
    of container: NSFileProviderItemIdentifier
  ) async throws -> NormalizedDropboxPath {
    guard container != .rootContainer else { return .root }
    guard let id = try? DropboxFileIdentifier(validating: container.rawValue),
      let entry = try await store.entry(forID: id)
    else {
      throw NSFileProviderError(.noSuchItem)
    }
    return entry.pathNormalized
  }

  // MARK: Change interpretation

  private func bringIndexCurrentIfIncomplete() async throws {
    let isComplete = try await store.didFinishInitialIndex()
    let hasCursor = try await store.currentCursor() != nil
    guard !isComplete || !hasCursor else { return }
    // Concurrent enumerations join one catch-up rather than racing their own.
    if let catchUpTask {
      try await catchUpTask.value
      return
    }
    let task = Task { [bulkClient, store, refreshPathRoot] in
      try await RemoteIndexer(client: bulkClient, store: store, refreshPathRoot: refreshPathRoot)
        .catchUp()
    }
    catchUpTask = task
    defer { catchUpTask = nil }
    try await task.value
  }

  private func interpret(_ page: ListFolderPage) async throws -> DeltaInterpreter.Interpretation {
    let signposter = ZephyrLog.signposter
    let state = signposter.beginInterval(
      "Interpret page",
      id: signposter.makeSignpostID(),
      "entries: \(page.entries.count, privacy: .public)"
    )
    defer { signposter.endInterval("Interpret page", state) }
    var known = Set<DropboxFileIdentifier>()
    for entry in page.entries {
      let id: DropboxFileIdentifier? =
        switch entry {
          case .file(let file): file.id
          case .folder(let folder): folder.id
          case .deleted: nil
        }
      if let id, try await store.entry(forID: id) != nil {
        known.insert(id)
      }
    }
    return DeltaInterpreter.interpret(entries: page.entries) { known.contains($0) }
  }

  /**
   Which indexed items belong in the working set.

   The system needs the working set to carry everything it must keep fresh
   without being asked for it: the items the user has singled out, the items
   that exist nowhere else, and the items whose parent folder it already
   holds on disk. Anything else it can ask for when the user browses to it,
   and it drops items whose parent is not materialized anyway.
   */
  struct WorkingSetSelection: Sendable {
    /// The items the system holds on disk, or `nil` before it has reported
    /// them — the whole index stands in for the working set until it does.
    let materializedIdentifiers: Set<DropboxFileIdentifier>?

    /// The folders whose children the system holds on disk.
    let materializedContainerPaths: Set<NormalizedDropboxPath>

    /// Whether the item belongs in the working set.
    func includes(_ entry: IndexEntryRecord) -> Bool {
      guard let materializedIdentifiers else { return true }
      return isSingledOut(entry)
        || existsOnlyLocally(entry)
        || materializedIdentifiers.contains(entry.dbxID)
        || materializedContainerPaths.contains(entry.parentPathNormalized)
    }

    /// Whether the item carries one of the three properties the File
    /// Provider API documents as indications of working-set membership.
    private func isSingledOut(_ entry: IndexEntryRecord) -> Bool {
      entry.lastUsedDate != nil || entry.tagData != nil || entry.favoriteRank != nil
    }

    /// Whether some part of the item lives only on this Mac: an ignored item
    /// has no remote counterpart at all, and extended attributes the system
    /// pushed down are held nowhere but the index.
    private func existsOnlyLocally(_ entry: IndexEntryRecord) -> Bool {
      entry.ignored || entry.xattrs != nil
    }
  }

  /// One page of the working set.
  public struct DomainPage: Sendable {
    /// The working-set items this page carries.
    public let items: [ProviderItem]
    /// `nil` when this was the last page; otherwise the opaque watermark to
    /// pass back to ``ProviderAdapter/domainItems(after:)`` for the next one.
    public let nextToken: UInt64?
  }

  /// One applied page of remote changes since an anchor.
  public struct ChangeBatch: Sendable {
    /// The items that were added or changed, ready to hand to the observer.
    public let updated: [ProviderItem]
    /// The items that are gone, by identifier.
    public let removed: [NSFileProviderItemIdentifier]
    /// The generation this page brings the enumeration up to, which the
    /// caller reports as its new sync anchor.
    public let anchor: UInt64
    /// Whether more changes are waiting, meaning the caller must enumerate
    /// again from ``anchor``.
    public let moreComing: Bool
  }
}
