import FileProvider
import Foundation
import os

// MARK: Locally-initiated writes

extension ProviderAdapter {
  /**
   Creates a folder under a parent container, adopting an existing folder at
   the path when the server reports a folder conflict (a `.mayAlreadyExist`
   create or a lost race).

   In a team space, a folder created at the root is shared as it is created:
   Dropbox keeps no unshared folders there, and a Business member's domain
   root *is* the team space.
   */
  public func createFolder(
    named name: String,
    in parent: NSFileProviderItemIdentifier
  ) async throws -> ProviderItem {
    guard !ExcludedNames.isExcluded(name) else {
      throw NSFileProviderError(.excludedFromSync)
    }
    let container = try await containerRecord(of: parent)
    guard !container.ignored else { throw NSFileProviderError(.excludedFromSync) }
    let path = try container.path.appending(name)
    let folder = try await remoteFolder(createdAt: path)
    guard let record = DeltaInterpreter.folderRecord(folder) else {
      throw ItemSyncFailure.serverError(
        path: path.rawValue,
        detail: String(localized: "folder metadata had no path", bundle: #bundle)
      )
    }
    try await store.applyLocalChange(
      [.upsert(record)],
      history: [
        HistoryEventRecord(
          dbxID: record.dbxID,
          path: record.pathCased,
          itemType: .folder,
          changeType: .added,
          direction: .up,
          size: nil,
          revision: nil,
          contentHash: nil
        )
      ]
    )
    await shareIntoTeamSpaceIfNeeded(path)
    return try await freshItem(for: record.dbxID)
  }

  private func remoteFolder(createdAt path: DropboxPath) async throws -> FolderMetadata {
    do {
      return try await recordingSyncErrors(at: path) {
        try await reresolvingPathRoot {
          try await client.createFolder(at: path)
        }
      }
    } catch ItemSyncFailure.folderConflict {
      guard let metadata = try await client.metadata(for: .path(path)),
        case .folder(let existing) = metadata
      else {
        throw ItemSyncFailure.folderConflict(path: path.rawValue)
      }
      return existing
    }
  }

  /// Shares a folder created at the root of a team space, where an unshared
  /// folder is not a state Dropbox keeps. The folder itself is already
  /// created and indexed, so a refused share is reported rather than thrown:
  /// undoing the create would be the more destructive answer.
  private func shareIntoTeamSpaceIfNeeded(_ path: DropboxPath) async {
    guard rootType == .team, path.parent.isRoot else { return }
    do {
      _ = try await client.shareFolder(.path(path), inheritAccess: false)
    } catch {
      await recordSyncError(
        SyncErrorRecord(
          pathNormalized: path.normalized,
          path: path,
          title: String(
            localized: "Couldn’t share the new folder with your team.",
            bundle: #bundle
          ),
          detail: (error as? any LocalizedError)?.failureReason
            ?? Self.unexpectedDetail(of: error)
        )
      )
    }
  }

  /**
   Uploads a new file under a parent container with `add` + autorename: a
   name collision yields a renamed sibling, never an overwrite.

   Excluded names (system metadata, temp files) throw
   `NSFileProviderError.excludedFromSync`, telling the system to keep the
   item local and stop asking.
   */
  public func createFile(
    named name: String,
    in parent: NSFileProviderItemIdentifier,
    contents: URL?,
    clientModified: Date?
  ) async throws -> ProviderItem {
    guard !ExcludedNames.isExcluded(name) else {
      throw NSFileProviderError(.excludedFromSync)
    }
    let container = try await containerRecord(of: parent)
    // A file born inside an ignored folder never syncs; the system keeps
    // it local-only and stops asking.
    guard !container.ignored else { throw NSFileProviderError(.excludedFromSync) }
    let path = try container.path.appending(name)
    return try await upload(contents, to: path, mode: .add, clientModified: clientModified)
  }

  /**
   Uploads new contents for an existing file, revision-guarded: a base
   version matching the index commits over the indexed revision; a stale
   base commits over the revision that content belonged to, making the
   server generate the conflicted copy; an unknown base adds alongside.

   Whatever the server does with the name, the answer is always the item the
   caller named: a conflicted copy joins the index as its own item.
   */
  public func modifyContents(
    of identifier: NSFileProviderItemIdentifier,
    baseContentVersion: Data?,
    contents: URL?,
    clientModified: Date?
  ) async throws -> ProviderItem {
    guard let id = try? DropboxFileIdentifier(validating: identifier.rawValue),
      let entry = try await store.entry(forID: id)
    else {
      throw NSFileProviderError(.noSuchItem)
    }
    guard entry.itemType != .folder else {
      throw ItemSyncFailure.isAFolder(path: entry.pathCased.rawValue)
    }
    // Symlink contents cannot be rewritten through the Dropbox API. The
    // system keeps the item local and stops asking — the same answer
    // `createItem` gives for a symlink it is asked to create.
    guard entry.itemType != .symlink else {
      throw NSFileProviderError(.excludedFromSync)
    }
    if entry.ignored {
      return try await recordIgnoredContents(
        of: entry,
        contents: contents,
        clientModified: clientModified
      )
    }
    let path = entry.pathCased
    let mode = try await writeMode(for: entry, baseContentVersion: baseContentVersion)
    return try await upload(
      contents,
      to: path,
      mode: mode,
      clientModified: clientModified,
      updating: id
    )
  }

  private func writeMode(
    for entry: IndexEntryRecord,
    baseContentVersion: Data?
  ) async throws -> WriteMode {
    guard let baseContentVersion, !baseContentVersion.isEmpty else {
      return entry.revision.map(WriteMode.update) ?? .add
    }
    if baseContentVersion == Self.contentVersion(of: entry), let revision = entry.revision {
      return .update(revision)
    }
    if let text = String(bytes: baseContentVersion, encoding: .utf8),
      let hash = try? ContentHash(validating: text),
      let revision = try await store.revision(forContentHash: hash, ofID: entry.dbxID)
    {
      return .update(revision)
    }
    // A base predating sync tracking: add + autorename keeps both versions.
    return .add
  }

  /**
   Uploads contents to a path and indexes the server's answer.

   - Parameter originalID: The item the caller asked to write, when there is
     one. Dropbox autorenames rather than overwriting a revision that moved
     on, so the answer can be a *different* item; naming the original lets
     the copy be indexed as its own item and the original still be returned.
   */
  func upload(
    _ contents: URL?,
    to path: DropboxPath,
    mode: WriteMode,
    clientModified: Date?,
    updating originalID: DropboxFileIdentifier? = nil
  ) async throws -> ProviderItem {
    let localURL = try contents ?? emptyStagedFile()
    defer {
      if contents == nil { try? FileManager.default.removeItem(at: localURL) }
    }
    ZephyrLog.transfers.debug("Uploading \(path.description, privacy: .private)")
    let uploaded = try await recordingSyncErrors(at: path) {
      try await reresolvingPathRoot {
        try await FileUploader(client: client, checkpointingInto: store).upload(
          localURL,
          to: path,
          mode: mode,
          clientModified: clientModified
        )
      }
    }
    guard let record = DeltaInterpreter.fileRecord(uploaded) else {
      throw ItemSyncFailure.serverError(
        path: path.rawValue,
        detail: String(localized: "file metadata had no path", bundle: #bundle)
      )
    }
    if let originalID, isConflictedCopy(record, of: originalID, requestedAt: path) {
      return try await adoptConflictedCopy(record, of: originalID)
    }
    try await store.applyLocalChange(
      [.upsert(record)],
      history: [
        HistoryEventRecord(
          dbxID: record.dbxID,
          path: record.pathCased,
          itemType: record.itemType,
          changeType: mode == .add ? .added : .modified,
          direction: .up,
          size: record.size,
          revision: record.revision,
          contentHash: record.contentHash
        )
      ]
    )
    return try await freshItem(for: record.dbxID)
  }

  /// Whether the server put the upload somewhere other than where it was
  /// asked to: a different item, a different path, or both — the shape of
  /// an autorenamed conflicted copy.
  private func isConflictedCopy(
    _ record: IndexEntryRecord,
    of originalID: DropboxFileIdentifier,
    requestedAt path: DropboxPath
  ) -> Bool {
    record.dbxID != originalID || record.pathNormalized != path.normalized
  }

  /// Indexes a conflicted copy as its own item and answers with the item the
  /// caller actually named, refreshed from Dropbox.
  ///
  /// The copy exists because someone else's revision won the requested path,
  /// so the original's indexed revision is stale; re-reading it is what makes
  /// the version the system holds for the original agree with Dropbox's.
  private func adoptConflictedCopy(
    _ copy: IndexEntryRecord,
    of originalID: DropboxFileIdentifier
  ) async throws -> ProviderItem {
    ZephyrLog.transfers.info(
      "Dropbox kept both versions as \(copy.pathCased.rawValue, privacy: .private)"
    )
    try await store.applyLocalChange(
      [.upsert(copy)],
      history: [
        HistoryEventRecord(
          dbxID: copy.dbxID,
          path: copy.pathCased,
          itemType: copy.itemType,
          changeType: .added,
          direction: .up,
          size: copy.size,
          revision: copy.revision,
          contentHash: copy.contentHash
        )
      ]
    )
    await refreshEntry(forID: originalID)
    return try await freshItem(for: originalID)
  }

  /// Re-reads one item's Dropbox metadata into the index. A failure leaves
  /// the indexed revision stale, which the change feed corrects on its own.
  private func refreshEntry(forID id: DropboxFileIdentifier) async {
    guard let metadata = try? await client.metadata(for: .id(id)),
      case .file(let file) = metadata,
      let record = DeltaInterpreter.fileRecord(file)
    else { return }
    try? await store.applyLocalChange([.upsert(record)])
  }

  func emptyStagedFile() throws -> URL {
    let url = try freshScratchLocation()
    try Data().write(to: url)
    return url
  }

  /**
   Renames and/or reparents an item with a server-side `move_v2` — no
   content transfer. Folder moves rewrite the indexed subtree's paths in the
   same transaction so child enumerations stay correct.
   */
  public func move(
    _ identifier: NSFileProviderItemIdentifier,
    toParent parent: NSFileProviderItemIdentifier?,
    renamedTo newName: String?
  ) async throws -> ProviderItem {
    guard let id = try? DropboxFileIdentifier(validating: identifier.rawValue),
      let entry = try await store.entry(forID: id)
    else {
      throw NSFileProviderError(.noSuchItem)
    }
    if let newName, ExcludedNames.isExcluded(newName) {
      throw NSFileProviderError(.excludedFromSync)
    }
    let (destination, parentIgnored) = try await self.destination(
      for: entry,
      under: parent,
      renamedTo: newName
    )
    if let item = try await movedOutsideSync(
      entry,
      as: identifier,
      to: destination,
      parentIgnored: parentIgnored
    ) {
      return item
    }
    let moved = try await recordingSyncErrors(at: destination) {
      try await reresolvingPathRoot {
        try await client.move(from: .id(id), to: destination, autorename: true)
      }
    }
    try await indexMove(of: moved, from: entry, to: destination)
    return try await freshItem(for: id)
  }

  /// Where a move lands, and whether the folder it lands in is ignored. A move
  /// that names no new parent keeps the one the item already has.
  private func destination(
    for entry: IndexEntryRecord,
    under parent: NSFileProviderItemIdentifier?,
    renamedTo newName: String?
  ) async throws -> (path: DropboxPath, parentIgnored: Bool) {
    let container: (path: DropboxPath, ignored: Bool) =
      if let parent {
        try await containerRecord(of: parent)
      } else {
        (entry.pathCased.parent, try await parentIsIgnored(of: entry))
      }
    let path = try container.path.appending(newName ?? entry.name)
    return (path, container.ignored)
  }

  /**
   Carries a move with an end outside sync and answers with the moved item, or
   `nil` when both ends sync and the move belongs to Dropbox.

   The move itself is local either way. An item leaving ignored space resumes
   syncing at its new location; one entering it leaves sync, so its remote copy
   goes away exactly as if it had been marked directly; one moving within
   ignored space stays where sync cannot see it, and nothing else happens.
   */
  private func movedOutsideSync(
    _ entry: IndexEntryRecord,
    as identifier: NSFileProviderItemIdentifier,
    to destination: DropboxPath,
    parentIgnored: Bool
  ) async throws -> ProviderItem? {
    guard entry.ignored || parentIgnored else { return nil }
    try await moveLocally(entry, to: destination)
    if entry.ignored, parentIgnored { return try await freshItem(for: entry.dbxID) }
    return entry.ignored
      ? try await resumeSync(identifier)
      : try await ignore(identifier)
  }

  /// Indexes the metadata a server-side move returned: a file replaces its own
  /// row, while a folder carries its indexed subtree's paths with it.
  private func indexMove(
    of moved: ItemMetadata,
    from entry: IndexEntryRecord,
    to destination: DropboxPath
  ) async throws {
    switch moved {
      case .file(let file):
        guard let record = DeltaInterpreter.fileRecord(file) else {
          throw ItemSyncFailure.serverError(
            path: destination.rawValue,
            detail: String(localized: "file metadata had no path", bundle: #bundle)
          )
        }
        try await store.applyLocalChange([.upsert(record)])
      case .folder(let folder):
        guard let record = DeltaInterpreter.folderRecord(folder) else {
          throw ItemSyncFailure.serverError(
            path: destination.rawValue,
            detail: String(localized: "folder metadata had no path", bundle: #bundle)
          )
        }
        try await store.applyLocalMove(
          to: record,
          from: entry.pathNormalized,
          oldCasedPath: entry.pathCased
        )
      case .deleted:
        throw ItemSyncFailure.serverError(
          path: destination.rawValue,
          detail: String(localized: "move returned a deletion", bundle: #bundle)
        )
    }
  }

  /**
   Persists system-owned attributes (tags, favorite rank, last-used date,
   extended attributes) in the index — they never travel to Dropbox — and
   echoes them back. Setting or clearing the `com.dropbox.ignored` extended
   attribute triggers the matching ignore or resume flow.
   */
  public func updateLocalAttributes(
    of identifier: NSFileProviderItemIdentifier,
    tagData: LocalAttributeUpdate<Data> = .keep,
    favoriteRank: LocalAttributeUpdate<Int64> = .keep,
    lastUsedDate: LocalAttributeUpdate<Date> = .keep,
    extendedAttributes: LocalAttributeUpdate<[String: Data]> = .keep
  ) async throws -> ProviderItem {
    guard let id = try? DropboxFileIdentifier(validating: identifier.rawValue),
      let entry = try await store.entry(forID: id),
      let updated = try await store.updateLocalAttributes(
        forID: id,
        tagData: tagData,
        favoriteRank: favoriteRank,
        lastUsedDate: lastUsedDate,
        xattrs: extendedAttributes
      )
    else {
      throw NSFileProviderError(.noSuchItem)
    }
    if case .set(let xattrs) = extendedAttributes {
      let wantsIgnored = DropboxIgnoreMarker.isMarked(xattrs ?? [:])
      if wantsIgnored != entry.ignored {
        return wantsIgnored
          ? try await ignore(identifier)
          : try await resumeSync(identifier)
      }
    }
    return try await providerItem(for: updated)
  }

  /**
   Deletes an item: files are guarded by their last-known revision, so a
   concurrent remote change rejects the deletion (and the change feed then
   resurrects the newer version). A folder deletion without `recursive` is
   refused while children exist.
   */
  public func delete(
    _ identifier: NSFileProviderItemIdentifier,
    recursive: Bool
  ) async throws {
    guard let id = try? DropboxFileIdentifier(validating: identifier.rawValue),
      let entry = try await store.entry(forID: id)
    else {
      return
    }
    if entry.itemType == .folder, !recursive,
      try await !store.children(of: entry.pathNormalized).isEmpty
    {
      throw NSFileProviderError(.directoryNotEmpty)
    }
    let path = entry.pathCased
    if entry.ignored {
      // The remote copy was already removed when the item was ignored;
      // only the local tracking and shadow contents remain.
      try await removeShadowsUnder(entry)
      try await store.applyLocalChange(
        [.deleteSubtree(entry.pathNormalized)])
      await clearSyncError(at: path)
      return
    }
    try await recordingSyncErrors(at: path) {
      do {
        _ = try await reresolvingPathRoot {
          try await client.delete(
            .id(id),
            parentRevision: entry.itemType == .folder ? nil : entry.revision
          )
        }
      } catch ItemSyncFailure.notFound {
        // Already gone remotely; converge by dropping the index rows.
      } catch let failure as ItemSyncFailure {
        // The route error blames the item id the request addressed.
        throw failure.retargeted(to: path.rawValue)
      }
    }
    try await store.applyLocalChange(
      [.deleteSubtree(entry.pathNormalized)],
      history: [
        HistoryEventRecord(
          dbxID: id,
          path: entry.pathCased,
          itemType: entry.itemType,
          changeType: .removed,
          direction: .up,
          size: nil,
          revision: nil,
          contentHash: nil
        )
      ]
    )
    await clearSyncError(at: path)
  }

  // MARK: Plumbing

  /// A container's cased path and ignored state; the domain root is never ignored.
  func containerRecord(
    of container: NSFileProviderItemIdentifier
  ) async throws -> (path: DropboxPath, ignored: Bool) {
    guard container != .rootContainer else { return (.root, false) }
    guard let id = try? DropboxFileIdentifier(validating: container.rawValue),
      let entry = try await store.entry(forID: id),
      entry.itemType == .folder
    else {
      throw NSFileProviderError(.noSuchItem)
    }
    return (entry.pathCased, entry.ignored)
  }

  /// Whether an entry's containing folder is ignored.
  func parentIsIgnored(of entry: IndexEntryRecord) async throws -> Bool {
    guard !entry.parentPathNormalized.isRoot else { return false }
    return try await store.entry(forPath: entry.parentPathNormalized)?.ignored ?? false
  }

  func freshItem(for id: DropboxFileIdentifier) async throws -> ProviderItem {
    guard let entry = try await store.entry(forID: id) else {
      throw NSFileProviderError(.noSuchItem)
    }
    return try await providerItem(for: entry)
  }

  /**
   Runs one Dropbox call, re-resolving the account's path root and trying
   once more when Dropbox refuses the call because the root moved.

   A member who joins or leaves a team keeps the same files under a new
   namespace, and every call made against the old one is refused from then
   on — a state no amount of retrying escapes. A root that turns out not to
   have moved rethrows: an account that cannot say where its files are is
   wedged, and saying so beats retrying forever.
   */
  func reresolvingPathRoot<Value: Sendable>(
    _ body: () async throws -> Value
  ) async throws -> Value {
    do {
      return try await body()
    } catch let failure as EngineFailure {
      guard case .pathRootChanged = failure else { throw failure }
      guard let refreshPathRoot, try await refreshPathRoot() else { throw failure }
      return try await body()
    }
  }

  /// Runs one sync operation against a path, clearing that path's recorded
  /// sync error on success and noting any failure on the way out, so the
  /// menu bar and the widget see every attempt's outcome.
  func recordingSyncErrors<Value: Sendable>(
    at path: DropboxPath,
    _ body: () async throws -> Value
  ) async throws -> Value {
    do {
      let value = try await body()
      await clearSyncError(at: path)
      await clearEngineError()
      return value
    } catch {
      await noteFailure(error, at: path)
      throw error
    }
  }

  /// Records a failure worth showing the user, and clears a stale one when
  /// the system was merely told the item is unavailable to it. A cancelled
  /// operation made no statement about the item, so its record stands — and
  /// neither does one that failed only because nothing could reach Dropbox:
  /// an outage is the account's weather rather than this item's fault, and
  /// recording it would leave every file caught by it wearing a failure the
  /// user has to dismiss by hand once the network comes back.
  private func noteFailure(_ error: any Error, at path: DropboxPath) async {
    guard !Self.isCancellation(error) else { return }
    guard !Self.resolvesWithoutUser(error) else { return }
    guard !Self.isSystemProtocolAnswer(error) else {
      await clearSyncError(at: path)
      return
    }
    guard !Self.isAccountWide(error) else {
      await noteAccountWideFailure(error)
      return
    }
    await recordSyncError(Self.syncError(for: error, at: path))
  }

  /// Persists one item's sync failure, logging when the index refuses the
  /// write — the mechanism that reports failures must not fail silently too.
  func recordSyncError(_ syncError: SyncErrorRecord) async {
    do {
      try await store.recordSyncError(syncError)
    } catch {
      ZephyrLog.index.error(
        """
        Couldn’t record a sync error for \(syncError.path.rawValue, privacy: .private): \
        \(String(describing: error), privacy: .private)
        """
      )
    }
  }

  /**
   Records the failure that stopped the whole account, so the app and the
   command line can say what is wrong without reaching the network
   themselves — the extension is the only process that watches Dropbox
   continuously.
   */
  private func noteAccountWideFailure(_ error: any Error) async {
    ZephyrLog.engine.error(
      "Syncing stopped: \(String(describing: error), privacy: .private)"
    )
    let localized = error as? any LocalizedError
    let record = EngineErrorRecord(
      title: localized?.errorDescription
        ?? String(localized: "Syncing stopped.", bundle: #bundle),
      detail: localized?.failureReason ?? Self.unexpectedDetail(of: error)
    )
    do {
      try await store.recordEngineError(record)
    } catch {
      ZephyrLog.index.error(
        """
        Couldn’t record the account-wide failure: \(String(describing: error), privacy: .private)
        """
      )
    }
  }

  /// Retires the account-wide failure, because an operation just succeeded
  /// and an account that syncs is not a stopped one.
  private func clearEngineError() async {
    do {
      try await store.clearEngineError()
    } catch {
      ZephyrLog.index.error(
        """
        Couldn’t clear the account-wide failure: \(String(describing: error), privacy: .private)
        """
      )
    }
  }

  /// Drops any recorded failure for a path, after the item syncs cleanly.
  func clearSyncError(at path: DropboxPath) async {
    do {
      try await store.clearSyncError(forPath: path.normalized)
    } catch {
      ZephyrLog.index.error(
        """
        Couldn’t clear the sync error for \(path.description, privacy: .private): \
        \(String(describing: error), privacy: .private)
        """
      )
    }
  }
}

// MARK: Classifying failures

extension ProviderAdapter {
  /// A failure described the way the status UI shows it, preferring the
  /// error's own localized text over its raw representation.
  private static func syncError(for error: any Error, at path: DropboxPath) -> SyncErrorRecord {
    let error = OSErrorMapping.classified(error, path: path.displayPath)
    let localized = error as? any LocalizedError
    return SyncErrorRecord(
      pathNormalized: path.normalized,
      path: path,
      title: localized?.errorDescription
        ?? String(localized: "Couldn’t sync with Dropbox.", bundle: #bundle),
      detail: localized?.failureReason ?? unexpectedDetail(of: error)
    )
  }

  /**
   The detail a failure record carries when the failure has no localized text
   of its own.

   Its raw description names Swift types and internals, which say nothing to a
   reader, so it goes to the log and the record says only that the failure was
   unexpected.
   */
  static func unexpectedDetail(of error: any Error) -> String {
    ZephyrLog.provider.error(
      "Recording a failure with no localized text: \(String(describing: error), privacy: .private)"
    )
    return String(localized: "An unexpected error occurred.", bundle: #bundle)
  }

  /// Whether the failure belongs to the account rather than to one item: a
  /// revoked token, an unreachable network, an index that will not open.
  ///
  /// Every transfer fails while it lasts, so these are recorded apart from
  /// the per-item failures, in ``EngineErrorRecord``. Filing one against the
  /// path that happened to be in flight — or against the domain root, where
  /// an enumeration failure lands — would report an account-wide outage as
  /// one more item that couldn't sync.
  private static func isAccountWide(_ error: any Error) -> Bool {
    error is any AuthError || error is any SyncFatalError
  }

  /// Whether the error is one that lifts on its own, with nothing for the
  /// user to do about it and so nothing worth recording against them.
  private static func resolvesWithoutUser(_ error: any Error) -> Bool {
    (error as? any SyncFatalError)?.resolvesWithoutUser ?? false
  }

  private static func isCancellation(_ error: any Error) -> Bool {
    switch error {
      case is CancellationError, EngineFailure.cancelled: true
      case let urlError as URLError: urlError.code == .cancelled
      default: false
    }
  }

  /// Whether the error is an answer the File Provider protocol asked for —
  /// an excluded item, an expired anchor, a version the index moved past —
  /// rather than a failure to sync.
  private static func isSystemProtocolAnswer(_ error: any Error) -> Bool {
    (error as NSError).domain == NSFileProviderErrorDomain
  }
}
