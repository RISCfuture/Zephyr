import FileProvider
import Foundation
import os

// MARK: Ignored items (`com.dropbox.ignored`)

extension ProviderAdapter {
  /// The scratch subdirectory holding shadow copies of ignored items'
  /// locally-edited contents (the scratch sweep spares it).
  static let shadowDirectoryName = "ignored-shadow"

  /**
   Ignores an item, matching the official Dropbox client's semantics: the
   contents stay on this Mac, the Dropbox copy is deleted, and syncing stops.
   Folders ignore their whole subtree.

   Because a File Provider item is normally a dataless placeholder, the
   contents this Mac is promised do not exist yet at the moment of the call.
   Every affected file is therefore downloaded into a shadow copy first, and
   the Dropbox delete runs only once the last one is on disk. A file Dropbox
   will not hand over abandons the whole ignore with nothing deleted: the
   remote copy would otherwise be the only one left, recoverable only from
   version history and only until it expires.
   */
  public func ignore(_ identifier: NSFileProviderItemIdentifier) async throws -> ProviderItem {
    guard let id = try? DropboxFileIdentifier(validating: identifier.rawValue),
      let entry = try await store.entry(forID: id)
    else {
      throw NSFileProviderError(.noSuchItem)
    }
    guard !entry.ignored else { return try await freshItem(for: id) }
    try await stashShadowsOfEverythingAffected(by: entry)
    guard let (_, affected) = try await store.setIgnoredState(true, forID: id) else {
      throw NSFileProviderError(.noSuchItem)
    }
    await removeRemoteCopy(of: entry)
    await recordLocalChangeGeneration(updatedIDs: affected)
    return try await freshItem(for: id)
  }

  /**
   Resumes syncing an ignored item: adopts the remote copy when it still
   matches, re-uploads contents edited while ignored, and restores a
   remotely-deleted file from its last synced revision. Folders resume
   their whole subtree.
   */
  public func resumeSync(_ identifier: NSFileProviderItemIdentifier) async throws -> ProviderItem {
    guard let id = try? DropboxFileIdentifier(validating: identifier.rawValue),
      let entry = try await store.entry(forID: id)
    else {
      throw NSFileProviderError(.noSuchItem)
    }
    guard entry.ignored else { return try await freshItem(for: id) }
    guard let (record, affected) = try await store.setIgnoredState(false, forID: id) else {
      throw NSFileProviderError(.noSuchItem)
    }
    switch record.itemType {
      case .folder:
        await restoreFolderTree(rootedAt: record)
      case .file, .symlink:
        try await restoreFile(record)
    }
    await recordLocalChangeGeneration(updatedIDs: affected)
    return try await freshItem(for: id)
  }

  /// Records the state change as a local anchor generation, so the system
  /// comes to collect it. A failure only costs the immediate refresh — the
  /// next enumeration still reports the new state — but nothing else would
  /// say why Finder went quiet.
  private func recordLocalChangeGeneration(updatedIDs: [DropboxFileIdentifier]) async {
    do {
      try await store.recordLocalChangeGeneration(updatedIDs: updatedIDs)
    } catch {
      ZephyrLog.index.error(
        "Couldn’t record a local change generation: \(String(describing: error), privacy: .private)"
      )
    }
  }

  // MARK: Preserving contents before an ignore

  /// Shadows every file the ignore is about to affect, so the Dropbox
  /// delete that follows can never take the last copy of anything. The
  /// whole walk completes before the caller deletes anything: a half-
  /// downloaded subtree followed by a delete is the data loss this exists
  /// to prevent.
  private func stashShadowsOfEverythingAffected(by root: IndexEntryRecord) async throws {
    do {
      // A folder holds no bytes, and a descendant that is already ignored
      // has no Dropbox copy left for the delete to take.
      for entry in try await affectedEntries(of: root)
      where entry.itemType != .folder && !entry.ignored {
        try await stashShadow(ofContentsOf: entry)
      }
    } catch {
      await recordSyncError(
        SyncErrorRecord(
          pathNormalized: root.pathNormalized,
          path: root.pathCased,
          title: String(
            localized: "Couldn’t save the item on this Mac, so it still syncs with Dropbox.",
            bundle: #bundle
          ),
          detail: (error as? any LocalizedError)?.failureReason
            ?? Self.unexpectedDetail(of: error)
        )
      )
      throw error
    }
  }

  /// The entry itself plus every indexed descendant of a folder — exactly
  /// the rows the ignore flips and the one delete removes.
  private func affectedEntries(of root: IndexEntryRecord) async throws -> [IndexEntryRecord] {
    guard root.itemType == .folder else { return [root] }
    let descendants = try await store.descendants(of: root.pathNormalized)
    return [root] + descendants
  }

  /// Downloads one file into its shadow copy, unless a shadow of the
  /// contents the index promises is already there.
  private func stashShadow(ofContentsOf entry: IndexEntryRecord) async throws {
    guard shadowContents(matching: entry) == nil else { return }
    guard let revision = entry.revision else {
      // Nothing to download and nothing already on disk: the only copy of
      // the contents is Dropbox's, so the delete must not happen.
      throw ItemSyncFailure.unsupportedFile(path: entry.pathCased.rawValue)
    }
    let staged = try freshScratchLocation()
    defer { try? FileManager.default.removeItem(at: staged) }
    do {
      _ = try await FileDownloader(client: client).download(.revision(revision), to: staged)
    } catch {
      // The route error blames the revision the request pinned; the user
      // needs the file it belongs to.
      throw (error as? ItemSyncFailure)?.retargeted(to: entry.pathCased.rawValue) ?? error
    }
    try stashShadow(staged, for: entry.dbxID)
    guard shadowContents(matching: entry) != nil else {
      // Materialization serves a shadow only while it matches the indexed
      // contents; one that doesn't is no copy at all.
      removeShadow(for: entry.dbxID)
      throw ItemSyncFailure.dataCorruption(path: entry.pathCased.rawValue)
    }
  }

  // MARK: Local-only mutations while ignored

  /// Records new contents for an ignored item without uploading: the index
  /// tracks the local state and a shadow copy keeps the bytes for
  /// materialization and a later resume.
  func recordIgnoredContents(
    of entry: IndexEntryRecord,
    contents: URL?,
    clientModified: Date?
  ) async throws -> ProviderItem {
    let localURL = try contents ?? emptyStagedFile()
    defer {
      if contents == nil { try? FileManager.default.removeItem(at: localURL) }
    }
    let hash = try DropboxContentHasher.hash(contentsOf: localURL)
    let size =
      (try? FileManager.default
      .attributesOfItem(atPath: localURL.path)[.size] as? NSNumber)?.uint64Value ?? 0
    try stashShadow(localURL, for: entry.dbxID)
    guard
      let updated = try await store.applyLocalContentUpdate(
        forID: entry.dbxID,
        contentHash: hash,
        size: size,
        clientModified: clientModified
      )
    else {
      throw NSFileProviderError(.noSuchItem)
    }
    return try await providerItem(for: updated)
  }

  /// Applies a move or rename to the index only — the shape of every move
  /// touching ignored space, where no remote copy exists to move.
  func moveLocally(_ entry: IndexEntryRecord, to destination: DropboxPath) async throws {
    guard entry.pathCased != destination else { return }
    if let occupant = try await store.entry(forPath: destination.normalized),
      occupant.dbxID != entry.dbxID
    {
      throw NSFileProviderError(.filenameCollision)
    }
    let moved = IndexEntryRecord(
      dbxID: entry.dbxID,
      pathNormalized: destination.normalized,
      parentPathNormalized: destination.normalized.parent,
      pathCased: destination,
      name: destination.basename,
      itemType: entry.itemType,
      revision: entry.revision,
      contentHash: entry.contentHash,
      symlinkTarget: entry.symlinkTarget,
      size: entry.size,
      clientModified: entry.clientModified,
      serverModified: entry.serverModified,
      metaGeneration: entry.metaGeneration,
      tagData: entry.tagData,
      favoriteRank: entry.favoriteRank,
      lastUsedDate: entry.lastUsedDate,
      xattrs: entry.xattrs,
      ignored: entry.ignored
    )
    if entry.itemType == .folder {
      try await store.applyLocalMove(
        to: moved,
        from: entry.pathNormalized,
        oldCasedPath: entry.pathCased
      )
    } else {
      try await store.applyLocalChange([.upsert(moved)])
    }
  }

  // MARK: Remote reconciliation

  /// Removes an ignored item's Dropbox copy, revision-guarded for files. A
  /// rejected or failed delete records a sync error but leaves the item
  /// ignored — the user's intent stands either way.
  private func removeRemoteCopy(of entry: IndexEntryRecord) async {
    do {
      _ = try await client.delete(
        .id(entry.dbxID),
        parentRevision: entry.itemType == .folder ? nil : entry.revision
      )
      try? await store.applyLocalChange(
        [],
        history: [
          HistoryEventRecord(
            dbxID: entry.dbxID,
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
    } catch ItemSyncFailure.notFound {
      // Nothing to remove; the item converges to local-only either way.
    } catch {
      // The route error blames the item id the request addressed.
      let failure = (error as? ItemSyncFailure)?.retargeted(to: entry.pathCased.rawValue) ?? error
      await recordSyncError(
        SyncErrorRecord(
          pathNormalized: entry.pathNormalized,
          path: entry.pathCased,
          title: String(
            localized: "Couldn’t remove the ignored item’s Dropbox copy.",
            bundle: #bundle
          ),
          detail: (failure as? any LocalizedError)?.failureReason
            ?? Self.unexpectedDetail(of: failure)
        )
      )
    }
  }

  /// Brings one resumed file back in sync with Dropbox, choosing between
  /// adopting the remote copy, uploading the shadow contents, and restoring
  /// the last synced revision.
  private func restoreFile(_ entry: IndexEntryRecord) async throws {
    let path = entry.pathCased
    _ = try await recordingSyncErrors(at: path) { () -> Bool in
      if case .file(let file) = try await client.metadata(for: .path(path)) {
        try await reconcile(entry, withRemote: file, at: path)
        removeShadow(for: entry.dbxID)
        return true
      }
      if let shadow = existingShadow(for: entry.dbxID) {
        _ = try await upload(
          shadow,
          to: path,
          mode: .add,
          clientModified: entry.clientModified
        )
        removeShadow(for: entry.dbxID)
        return true
      }
      guard let revision = entry.revision else {
        throw ItemSyncFailure.unsupportedFile(path: entry.pathCased.rawValue)
      }
      let restored = try await client.restore(path, to: revision)
      if let record = DeltaInterpreter.fileRecord(restored) {
        try await store.applyLocalChange(
          [.upsert(record)],
          history: [
            HistoryEventRecord(
              dbxID: record.dbxID,
              path: record.pathCased,
              itemType: record.itemType,
              changeType: .added,
              direction: .up,
              size: record.size,
              revision: record.revision,
              contentHash: record.contentHash
            )
          ]
        )
      }
      return true
    }
  }

  private func reconcile(
    _ entry: IndexEntryRecord,
    withRemote file: FileMetadata,
    at path: DropboxPath
  ) async throws {
    if file.contentHash != entry.contentHash,
      let shadow = existingShadow(for: entry.dbxID)
    {
      // Contents edited while ignored upload over the remote revision;
      // a conflicting remote edit makes the server keep both copies.
      _ = try await upload(
        shadow,
        to: path,
        mode: .update(file.rev),
        clientModified: entry.clientModified,
        updating: entry.dbxID
      )
      return
    }
    // The remote copy matches — or the local copy was never edited while
    // ignored, so the surviving remote version wins. Adopt it.
    if let record = DeltaInterpreter.fileRecord(file) {
      try await store.applyLocalChange([.upsert(record)])
    }
  }

  /// Resumes a folder subtree: folders are recreated remotely as needed
  /// (parents before children), files reconcile individually, and one
  /// item's failure never aborts the rest.
  private func restoreFolderTree(rootedAt root: IndexEntryRecord) async {
    await ensureRemoteFolder(at: root)
    let descendants = (try? await store.descendants(of: root.pathNormalized)) ?? []
    for entry in descendants {
      switch entry.itemType {
        case .folder:
          await ensureRemoteFolder(at: entry)
        case .file, .symlink:
          try? await restoreFile(entry)
      }
    }
  }

  private func ensureRemoteFolder(at entry: IndexEntryRecord) async {
    let path = entry.pathCased
    do {
      let folder: FolderMetadata
      do {
        folder = try await client.createFolder(at: path)
      } catch ItemSyncFailure.folderConflict {
        guard case .folder(let existing) = try await client.metadata(for: .path(path))
        else { return }
        folder = existing
      }
      if let record = DeltaInterpreter.folderRecord(folder) {
        try await store.applyLocalChange([.upsert(record)])
      }
    } catch {
      await recordSyncError(
        SyncErrorRecord(
          pathNormalized: entry.pathNormalized,
          path: entry.pathCased,
          title: String(localized: "Couldn’t re-create the folder on Dropbox.", bundle: #bundle),
          detail: (error as? any LocalizedError)?.failureReason
            ?? Self.unexpectedDetail(of: error)
        )
      )
    }
  }

  // MARK: Shadow copies

  /// The shadow copy backing an ignored item's index-recorded content hash,
  /// or `nil` when the item was never edited while ignored (its contents
  /// still match a Dropbox revision).
  func shadowContents(matching entry: IndexEntryRecord) -> URL? {
    guard let shadow = existingShadow(for: entry.dbxID),
      let hash = try? DropboxContentHasher.hash(contentsOf: shadow),
      hash == entry.contentHash
    else { return nil }
    return shadow
  }

  func existingShadow(for id: DropboxFileIdentifier) -> URL? {
    let url = shadowURL(for: id)
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
  }

  func stashShadow(_ contents: URL, for id: DropboxFileIdentifier) throws {
    let destination = shadowURL(for: id)
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    if FileManager.default.fileExists(atPath: destination.path) {
      try FileManager.default.removeItem(at: destination)
    }
    try FileManager.default.copyItem(at: contents, to: destination)
  }

  func removeShadow(for id: DropboxFileIdentifier) {
    try? FileManager.default.removeItem(at: shadowURL(for: id))
  }

  /// Removes the shadow copies of an entry and everything beneath it.
  func removeShadowsUnder(_ entry: IndexEntryRecord) async throws {
    removeShadow(for: entry.dbxID)
    for id in try await store.identifiers(under: entry.pathNormalized) {
      removeShadow(for: id)
    }
  }

  private func shadowURL(for id: DropboxFileIdentifier) -> URL {
    scratchDirectory
      .appendingPathComponent(Self.shadowDirectoryName)
      .appendingPathComponent(id.rawValue.replacingOccurrences(of: "/", with: "_"))
  }
}
