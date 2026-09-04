public import Foundation
import GRDB

// MARK: Locally-initiated writes

/// One field of a local-attribute update: left alone, or set to a new value
/// (possibly `nil` — clearing a tag is a real update).
public enum LocalAttributeUpdate<Value: Sendable>: Sendable {
  case keep

  case set(Value?)
}

extension SyncIndexStore {
  /// Rewrites the indexed paths of everything beneath a moved or renamed
  /// folder, preserving each row's identity and local-only attributes. The
  /// paths they vacate carry no sync errors afterwards — nothing would ever
  /// clear an error keyed on a path the index no longer holds.
  static func rewriteDescendantPaths(
    from oldPath: NormalizedDropboxPath,
    to newPath: NormalizedDropboxPath,
    fromCased oldCasedPath: DropboxPath,
    toCased newCasedPath: DropboxPath,
    in db: Database
  ) throws {
    let descendants =
      try IndexEntryRecord
      .filter(Self.under(oldPath))
      .fetchAll(db)
    try Self.clearSyncErrors(atPaths: descendants.map(\.pathNormalized), in: db)
    for descendant in descendants {
      guard
        let rewritten = Self.rewriting(
          descendant,
          fromPath: oldPath,
          toPath: newPath,
          fromCased: oldCasedPath,
          toCased: newCasedPath
        )
      else { continue }
      try rewritten.save(db)
    }
  }

  private static func rewriting(
    _ record: IndexEntryRecord,
    fromPath oldPath: NormalizedDropboxPath,
    toPath newPath: NormalizedDropboxPath,
    fromCased oldCased: DropboxPath,
    toCased newCased: DropboxPath
  ) -> IndexEntryRecord? {
    let oldPrefix = oldPath.rawValue + "/"
    guard record.pathNormalized.rawValue.hasPrefix(oldPrefix),
      let pathNormalized = try? NormalizedDropboxPath(
        validating: newPath.rawValue + "/"
          + record.pathNormalized.rawValue.dropFirst(oldPrefix.count)
      )
    else { return nil }
    let pathCased = rewriting(record.pathCased, fromCased: oldCased, toCased: newCased)
    return IndexEntryRecord(
      dbxID: record.dbxID,
      pathNormalized: pathNormalized,
      parentPathNormalized: pathNormalized.parent,
      pathCased: pathCased,
      name: record.name,
      itemType: record.itemType,
      revision: record.revision,
      contentHash: record.contentHash,
      symlinkTarget: record.symlinkTarget,
      size: record.size,
      clientModified: record.clientModified,
      serverModified: record.serverModified,
      metaGeneration: record.metaGeneration + 1,
      tagData: record.tagData,
      favoriteRank: record.favoriteRank,
      lastUsedDate: record.lastUsedDate,
      xattrs: record.xattrs,
      ignored: record.ignored
    )
  }

  /// A descendant's cased path with the moved ancestor's cased path swapped
  /// in, left alone when the ancestor's casing does not prefix it.
  private static func rewriting(
    _ pathCased: DropboxPath,
    fromCased oldCased: DropboxPath,
    toCased newCased: DropboxPath
  ) -> DropboxPath {
    let oldPrefix = oldCased.rawValue + "/"
    guard pathCased.rawValue.hasPrefix(oldPrefix) else { return pathCased }
    let rewritten = newCased.rawValue + "/" + pathCased.rawValue.dropFirst(oldPrefix.count)
    return (try? DropboxPath(validating: rewritten)) ?? pathCased
  }

  /**
   Applies mutations produced by a locally-initiated write (an upload, move,
   or delete this client performed), without advancing the delta cursor: the
   server will re-deliver the same state through the change feed, where the
   upsert is idempotent.
   */
  public func applyLocalChange(
    _ mutations: [IndexMutation],
    history: [HistoryEventRecord] = []
  ) async throws {
    try ensureWritable()
    try await write { db in
      _ = try Self.apply(mutations, history: history, origin: .local, in: db)
    }
  }

  /**
   Applies a locally-initiated move: upserts the moved item's new record and
   rewrites the paths of every indexed descendant in the same transaction,
   so child enumerations answer correctly before the server's change feed
   re-delivers the subtree.
   */
  public func applyLocalMove(
    to record: IndexEntryRecord,
    from oldPath: NormalizedDropboxPath,
    oldCasedPath: DropboxPath,
    history: [HistoryEventRecord] = []
  ) async throws {
    try ensureWritable()
    let newPath = record.pathNormalized
    let newCasedPath = record.pathCased
    try await write { db in
      try Self.apply([.upsert(record)], history: history, origin: .local, in: db)
      try Self.rewriteDescendantPaths(
        from: oldPath,
        to: newPath,
        fromCased: oldCasedPath,
        toCased: newCasedPath,
        in: db
      )
    }
  }

  /**
   Updates an item's local-only attributes (tags, favorite rank, last-used
   date), bumping its metadata generation, and returns the updated record.
   */
  public func updateLocalAttributes(
    forID id: DropboxFileIdentifier,
    tagData: LocalAttributeUpdate<Data> = .keep,
    favoriteRank: LocalAttributeUpdate<Int64> = .keep,
    lastUsedDate: LocalAttributeUpdate<Date> = .keep,
    xattrs: LocalAttributeUpdate<[String: Data]> = .keep
  ) async throws -> IndexEntryRecord? {
    try ensureWritable()
    return try await write { db in
      guard var record = try IndexEntryRecord.fetchOne(db, key: id.rawValue) else {
        return nil
      }
      if case .set(let value) = tagData { record.tagData = value }
      if case .set(let value) = favoriteRank { record.favoriteRank = value }
      if case .set(let value) = lastUsedDate { record.lastUsedDate = value }
      if case .set(let value) = xattrs { record.xattrs = value?.isEmpty == true ? nil : value }
      record.metaGeneration += 1
      try record.save(db)
      return record
    }
  }

  /**
   Flips an item's ignored state, keeping its `com.dropbox.ignored` extended
   attribute in step. Folders propagate the flag to every indexed descendant
   so remote-change suppression covers the whole subtree.

   - Returns: The updated record plus every affected identifier (for change
     reporting), or `nil` when the identifier is unknown.
   */
  public func setIgnoredState(
    _ ignored: Bool,
    forID id: DropboxFileIdentifier
  ) async throws -> (record: IndexEntryRecord, affectedIDs: [DropboxFileIdentifier])? {
    try ensureWritable()
    return try await write { db in
      guard var record = try IndexEntryRecord.fetchOne(db, key: id.rawValue) else {
        return nil
      }
      var xattrs = DropboxIgnoreMarker.removingMarker(from: record.xattrs ?? [:])
      if ignored {
        xattrs[DropboxIgnoreMarker.syncableXattrName] = DropboxIgnoreMarker.markedValue
      }
      record.xattrs = xattrs.isEmpty ? nil : xattrs
      record.ignored = ignored
      record.metaGeneration += 1
      try record.save(db)
      var affected = [record.dbxID]
      if record.itemType == .folder {
        let descendants =
          try IndexEntryRecord
          .filter(Self.under(record.pathNormalized))
          .filter(Column("ignored") == !ignored)
          .fetchAll(db)
        for var descendant in descendants {
          descendant.ignored = ignored
          descendant.metaGeneration += 1
          try descendant.save(db)
          affected.append(descendant.dbxID)
        }
      }
      return (record, affected)
    }
  }

  /**
   Records new local contents for an ignored item without an upload: the
   hash and size now describe the local replica, while the revision keeps
   naming the last synced version for a later resume.
   */
  public func applyLocalContentUpdate(
    forID id: DropboxFileIdentifier,
    contentHash: ContentHash,
    size: UInt64,
    clientModified: Date?
  ) async throws -> IndexEntryRecord? {
    try ensureWritable()
    return try await write { db in
      guard let record = try IndexEntryRecord.fetchOne(db, key: id.rawValue) else {
        return nil
      }
      let updated = IndexEntryRecord(
        dbxID: record.dbxID,
        pathNormalized: record.pathNormalized,
        parentPathNormalized: record.parentPathNormalized,
        pathCased: record.pathCased,
        name: record.name,
        itemType: record.itemType,
        revision: record.revision,
        contentHash: contentHash,
        symlinkTarget: record.symlinkTarget,
        size: size,
        clientModified: clientModified ?? record.clientModified,
        serverModified: record.serverModified,
        metaGeneration: record.metaGeneration + 1,
        tagData: record.tagData,
        favoriteRank: record.favoriteRank,
        lastUsedDate: record.lastUsedDate,
        xattrs: record.xattrs,
        ignored: record.ignored
      )
      try updated.save(db)
      return updated
    }
  }

  /// Every indexed entry strictly beneath a folder path, parents before
  /// children (normalized-path order).
  public func descendants(of path: NormalizedDropboxPath) async throws -> [IndexEntryRecord] {
    try await read { db in
      try IndexEntryRecord
        .filter(Self.under(path))
        .order(Column("path_normalized"))
        .fetchAll(db)
    }
  }

  /**
   The chunked upload recorded for a path that another process may still
   continue, or `nil` when there is none.

   A record Dropbox's 48-hour session window has closed on names a session
   the server has already forgotten, so it is not offered: the upload starts
   over rather than wedging against a session that answers nothing.
   */
  func resumableUploadSession(
    forPath path: NormalizedDropboxPath
  ) async throws -> UploadSessionRecord? {
    let recorded = try await read { db in
      try UploadSessionRecord.fetchOne(db, key: path.rawValue)
    }
    return recorded?.isUsable() == true ? recorded : nil
  }

  /**
   Records how much of a chunked upload Dropbox has committed, replacing any
   earlier record for the same path.

   Records whose session window has closed are swept first, in the same
   transaction: a path uploaded once and never again would otherwise keep its
   row forever.
   */
  func recordUploadSession(_ record: UploadSessionRecord) async throws {
    try ensureWritable()
    let expired = Date(timeIntervalSinceNow: -UploadSessionRecord.sessionWindow)
    try await write { db in
      try UploadSessionRecord.filter(Column("started_at") < expired).deleteAll(db)
      try record.save(db)
    }
  }

  /// Forgets the session recorded for a path, because the upload committed,
  /// was abandoned, or can no longer be proven resumable.
  func clearUploadSession(forPath path: NormalizedDropboxPath) async throws {
    try ensureWritable()
    try await write { db in
      _ = try UploadSessionRecord.deleteOne(db, key: path.rawValue)
    }
  }

  /**
   The most recently recorded revision of one item whose content matched
   `hash`, from the history log — the base-revision lookup for stale-version
   uploads.

   Keyed by identifier as well as hash: two byte-identical files at different
   paths share a hash, and committing over the other item's revision would
   name the wrong base.
   */
  public func revision(
    forContentHash hash: ContentHash,
    ofID id: DropboxFileIdentifier
  ) async throws -> FileRevision? {
    try await read { db in
      try FileRevision.fetchOne(
        db,
        sql: "SELECT rev FROM history_event WHERE dbx_id = ? AND content_hash = ? "
          + "AND rev IS NOT NULL ORDER BY recorded_at DESC LIMIT 1",
        arguments: [id.rawValue, hash.rawValue]
      )
    }
  }
}
