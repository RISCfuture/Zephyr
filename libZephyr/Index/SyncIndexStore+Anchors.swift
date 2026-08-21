import Foundation
import GRDB

// MARK: Sync anchors

extension SyncIndexStore {
  /// How many anchor generations are retained; older generations expire.
  private static let anchorRetentionCount = 50

  /// The identifiers a page's apply will remove, read from the pre-apply
  /// index: tombstoned subtrees (sparing ignored items and their ancestor
  /// folders) plus everything an upsert displaces from its path — a whole
  /// subtree when the displaced occupant is a folder, and nothing at all
  /// when it is one that survives, renamed aside.
  private static func removedIdentifiers(
    for mutations: [IndexMutation],
    in db: Database
  ) throws -> Set<DropboxFileIdentifier> {
    var removed: Set<DropboxFileIdentifier> = []
    for mutation in mutations {
      switch mutation {
        case .deleteSubtree(let path):
          removed.formUnion(try doomedIdentifiers(underTombstone: path, in: db))
        case .upsert(let record):
          removed.formUnion(try evictedEntries(byUpsertOf: record, in: db).map(\.dbxID))
      }
    }
    return removed
  }

  private static func insertChanges(
    updated: [DropboxFileIdentifier],
    removed: [DropboxFileIdentifier],
    generation: UInt64,
    in db: Database
  ) throws {
    for id in updated {
      try db.execute(
        sql: "INSERT INTO anchor_changes (generation, dbx_id, kind) VALUES (?, ?, ?)",
        arguments: [Int64(generation), id.rawValue, ChangeKind.updated.rawValue]
      )
    }
    for id in removed {
      try db.execute(
        sql: "INSERT INTO anchor_changes (generation, dbx_id, kind) VALUES (?, ?, ?)",
        arguments: [Int64(generation), id.rawValue, ChangeKind.removed.rawValue]
      )
    }
  }

  private static func insertAnchor(cursor: DeltaCursor, in db: Database) throws -> UInt64 {
    try db.execute(
      sql: "INSERT INTO anchors (cursor, created_at) VALUES (?, ?)",
      arguments: [cursor.rawValue, Date()]
    )
    let generation = db.lastInsertedRowID
    try db.execute(
      sql: "DELETE FROM anchors WHERE generation NOT IN "
        + "(SELECT generation FROM anchors ORDER BY generation DESC LIMIT ?)",
      arguments: [anchorRetentionCount]
    )
    try db.execute(
      sql: "DELETE FROM anchor_changes WHERE generation NOT IN (SELECT generation FROM anchors)"
    )
    return UInt64(generation)
  }

  /**
   Records a sync anchor for a delta cursor, returning its generation.

   Generations come from the `anchors` table's auto-incremented key, so they
   are strictly monotonic for the life of the database. Only the newest
   `anchorRetentionCount` anchors are kept; older generations expire.
   */
  public func recordAnchor(cursor: DeltaCursor) async throws -> UInt64 {
    try ensureWritable()
    return try await write { db in
      try Self.insertAnchor(cursor: cursor, in: db)
    }
  }

  /**
   Applies one delta page, records a sync anchor for its cursor, and records
   the item changes the page produced — all in one transaction, so a crash
   can never advance the index past its newest anchor or leave a generation
   whose changes cannot be replayed.

   The returned change set is disjoint: an identifier tombstoned and then
   re-upserted by the same page (a remote move) reports as updated, an
   identifier upserted and later deleted reports as removed, and an
   identifier evicted from its path by an upsert under a different
   identifier reports as removed.
   */
  public func applyDeltaPageRecordingAnchor(
    _ mutations: [IndexMutation],
    history: [HistoryEventRecord],
    advancingCursorTo cursor: DeltaCursor
  ) async throws -> AppliedChangeSet {
    try ensureWritable()
    let applied = try await write { db in
      var removed = try Self.removedIdentifiers(for: mutations, in: db)
      let sidestepped = try Self.applyPage(
        mutations,
        history: history,
        advancingCursorTo: cursor,
        in: db
      )
      var updated: [DropboxFileIdentifier] = []
      var reported: Set<DropboxFileIdentifier> = []
      for case .upsert(let record) in mutations {
        let id = record.dbxID
        guard reported.insert(id).inserted else { continue }
        if try IndexEntryRecord.fetchOne(db, key: id.rawValue) != nil {
          removed.remove(id)
          updated.append(id)
        } else {
          removed.insert(id)
        }
      }
      // Ignored rows renamed aside to free their path changed filename;
      // the system must hear about them to rename the local replica.
      for id in sidestepped where reported.insert(id).inserted {
        updated.append(id)
      }
      let generation = try Self.insertAnchor(cursor: cursor, in: db)
      try Self.insertChanges(
        updated: updated,
        removed: Array(removed),
        generation: generation,
        in: db
      )
      return AppliedChangeSet(
        generation: generation,
        updatedIDs: updated,
        removedIDs: Array(removed),
        isLatest: true
      )
    }
    changeSignal?.post()
    return applied
  }

  /**
   Records a fresh anchor generation carrying locally-originated item
   changes (an ignore or resume, a local-only rename), so `changes(from:)`
   replay delivers them without a server page. A no-op before the first
   cursor exists — the initial enumeration reports such items anyway.
   */
  public func recordLocalChangeGeneration(updatedIDs: [DropboxFileIdentifier]) async throws {
    guard !updatedIDs.isEmpty else { return }
    try ensureWritable()
    try await write { db in
      guard
        let cursor =
          try String
          .fetchOne(
            db,
            sql: "SELECT value FROM engine_state WHERE key = ?",
            arguments: [Self.cursorStateKey]
          )
          .flatMap({ try? DeltaCursor(validating: $0) })
      else { return }
      let generation = try Self.insertAnchor(cursor: cursor, in: db)
      try Self.insertChanges(updated: updatedIDs, removed: [], generation: generation, in: db)
    }
    changeSignal?.post()
  }

  /// The most recently recorded anchor, or `nil` before the first ``recordAnchor(cursor:)``.
  public func latestAnchor() async throws -> (generation: UInt64, cursor: DeltaCursor)? {
    try await read { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: "SELECT generation, cursor FROM anchors ORDER BY generation DESC LIMIT 1"
        )
      else { return nil }
      let generation: Int64 = row["generation"]
      return (generation: UInt64(generation), cursor: try DeltaCursor(validating: row["cursor"]))
    }
  }

  /// The cursor recorded for an anchor generation, or `nil` when unknown or expired.
  public func cursor(forAnchorGeneration generation: UInt64) async throws -> DeltaCursor? {
    try await read { db in
      try String
        .fetchOne(
          db,
          sql: "SELECT cursor FROM anchors WHERE generation = ?",
          arguments: [Int64(generation)]
        )
        .map { try DeltaCursor(validating: $0) }
    }
  }

  /**
   The recorded change set of the first generation newer than `generation`,
   or `nil` when `generation` is the newest anchor.

   Change requests from an anchor the index has already advanced past replay
   from these recordings; consuming a fresh server page instead would report
   the intervening changes against pre-apply state that no longer exists.
   */
  public func recordedChanges(
    afterGeneration generation: UInt64
  ) async throws -> AppliedChangeSet? {
    try await read { db in
      guard
        let next = try Int64.fetchOne(
          db,
          sql: "SELECT MIN(generation) FROM anchors WHERE generation > ?",
          arguments: [Int64(generation)]
        )
      else { return nil }
      let isLatest =
        try Int64.fetchOne(
          db,
          sql: "SELECT COUNT(*) FROM anchors WHERE generation > ?",
          arguments: [next]
        ) == 0
      var updated: [DropboxFileIdentifier] = []
      var removed: [DropboxFileIdentifier] = []
      let rows = try Row.fetchAll(
        db,
        sql: "SELECT dbx_id, kind FROM anchor_changes WHERE generation = ? ORDER BY rowid",
        arguments: [next]
      )
      for row in rows {
        guard let id = try? DropboxFileIdentifier(validating: row["dbx_id"]),
          let kind = ChangeKind(rawValue: row["kind"])
        else { continue }
        switch kind {
          case .updated: updated.append(id)
          case .removed: removed.append(id)
        }
      }
      return AppliedChangeSet(
        generation: UInt64(next),
        updatedIDs: updated,
        removedIDs: removed,
        isLatest: isLatest
      )
    }
  }

  /// How a recorded per-generation change row classifies its item.
  private enum ChangeKind: Int {
    case updated = 0

    case removed = 1
  }

  /// The item changes one applied delta page produced, keyed to its anchor.
  public struct AppliedChangeSet: Sendable {
    /// The anchor generation recorded for the page.
    public let generation: UInt64

    /// Identifiers whose items were created or updated, in page order.
    public let updatedIDs: [DropboxFileIdentifier]

    /// Identifiers whose items were removed.
    public let removedIDs: [DropboxFileIdentifier]

    /// Whether this generation is the newest recorded anchor.
    public let isLatest: Bool
  }
}

// MARK: Provider enumeration queries

extension SyncIndexStore {
  static func identifiers(
    under path: NormalizedDropboxPath,
    in db: Database
  ) throws -> [DropboxFileIdentifier] {
    try IndexEntryRecord
      .filter(atOrUnder(path))
      .order(Column("path_normalized"))
      .select(Column("dbx_id"), as: DropboxFileIdentifier.self)
      .fetchAll(db)
  }

  /**
   One page of a full-index scan in SQLite rowid order.

   - Parameters:
     - rowID: The watermark from the previous page's last element, or `nil`
       to start from the beginning.
     - limit: The maximum number of entries to return.
   */
  public func entries(afterRowID rowID: Int64?, limit: UInt) async throws
    -> [(rowID: Int64, entry: IndexEntryRecord)]
  {
    try await read { db in
      let rows = try Row.fetchAll(
        db,
        sql: "SELECT *, rowid AS row_id FROM items WHERE rowid > ? ORDER BY rowid LIMIT ?",
        arguments: [rowID ?? 0, Int(clamping: limit)]
      )
      return try rows.map { row in
        let rowID: Int64 = row["row_id"]
        return (rowID: rowID, entry: try IndexEntryRecord(row: row))
      }
    }
  }

  /// The identifiers of the entry at `path` and of every entry beneath it.
  public func identifiers(under path: NormalizedDropboxPath) async throws -> [DropboxFileIdentifier]
  {
    try await read { db in
      try Self.identifiers(under: path, in: db)
    }
  }
}
