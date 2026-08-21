import Foundation
import GRDB
import System
import os

/// A change to apply to the index, derived from one delta entry.
public enum IndexMutation: Sendable {
  /// Insert or update an item.
  case upsert(IndexEntryRecord)

  /// Remove the item at a path and everything beneath it (a deletion tombstone).
  case deleteSubtree(NormalizedDropboxPath)
}

/**
 The per-account sync index: a WAL-mode SQLite database in the shared
 container, holding every known remote item plus the delta cursor.

 The cursor is committed in the same transaction as the page of mutations it
 reflects, so a crash can never leave the index claiming state it does not
 have. One process writes (the engine host); others open read-only.
 */
public final class SyncIndexStore: Sendable {
  static let cursorStateKey = "deltaCursor"

  private static let initialIndexCompleteKey = "didFinishInitialIndex"

  /// How long history events are kept (one week, Maestral's default).
  private static let historyRetention: TimeInterval = 604_800

  /// How long a cached account display name is trusted before Dropbox is
  /// asked again (30 days) — people do rename themselves.
  private static let accountNameRetention: TimeInterval = 30 * 24 * 60 * 60

  /// How many identifiers one `IN (…)` deletion carries, keeping the
  /// expression tree inside SQLite's limit.
  private static let deletionChunkSize = 500

  /// How long a write waits out a lock another process holds. The CLI and the
  /// File Provider extension may write from separate processes; waiting out
  /// cross-process contention beats failing the operation.
  private static let lockContentionTimeout: TimeInterval = 5

  /// Matches rows carrying attributes Dropbox does not store, which a
  /// rebuild must preserve.
  private static var hasLocalOnlyState: SQLExpression {
    Column("ignored") == true
      || Column("tag_data") != nil
      || Column("favorite_rank") != nil
      || Column("last_used_date") != nil
      || Column("xattrs") != nil
  }

  private let pool: DatabasePool

  private let mode: AccessMode

  let changeSignal: ChangeSignal?

  /**
   Opens (and for ``AccessMode/readWrite``, migrates) the index database at `url`.

   - Parameter url: The index database file for one account.
   - Parameter mode: Whether this process may write. Only a writer migrates the
     schema; a reader opens the file read-only and leaves it as it found it.
   - Parameter changeSignal: Posted after each commit, telling the other
     processes to read the index again. Only a writer passes one; a reader has
     nothing to announce.
   */
  public init(url: URL, mode: AccessMode = .readWrite, changeSignal: ChangeSignal? = nil) throws {
    self.mode = mode
    self.changeSignal = changeSignal
    var configuration = Configuration()
    configuration.readonly = (mode == .readOnly)
    configuration.busyMode = .timeout(Self.lockContentionTimeout)
    do {
      pool = try DatabasePool(path: url.path, configuration: configuration)
      if mode == .readWrite {
        try Self.refuseIndexFromNewerBuild(in: pool)
        try Self.migrator.migrate(pool)
      }
    } catch {
      throw Self.failure(from: error)
    }
  }

  /**
   Stops an older build from writing an index a newer one migrated.

   Both editions of Zephyr share a bundle identifier, and so share one File
   Provider registration and one index per account. Which edition's extension
   macOS elects is decided by version, not by which app is running — so if both
   are installed, an older build can be handed an index whose schema it has
   never seen. GRDB would migrate nothing and carry on writing through the
   tables it does know, silently, which is how an index ends up claiming state
   it doesn't have.

   Refusing outright turns that into an error the user can act on.
   */
  private static func refuseIndexFromNewerBuild(in pool: DatabasePool) throws {
    let superseded = try pool.read(migrator.hasBeenSuperseded)
    if superseded { throw IndexStoreFailure.schemaFromNewerBuild }
  }

  /**
   The error a caller has to see: the ones that already say what went wrong,
   left as they are, and anything else read as an index failure.

   Giving up on a read is not the index being unavailable. SwiftUI cancels a
   `.task` when its view goes away, which is routine — the menu bar panel
   closes mid-read every time someone dismisses it — and a cancellation
   dressed up as a database fault reads to the user as an account that has
   stopped syncing.
   */
  private static func failure(from error: any Error) -> any Error {
    switch error {
      case let failure as IndexStoreFailure: failure
      case is CancellationError: CancellationError()
      default: databaseFailure(error)
    }
  }

  /**
   Turns a failure the database driver raised into one worth showing.

   A driver error names SQL and internals that say nothing to a reader, so its
   description goes to the log and the failure carries a general detail.
   */
  private static func databaseFailure(_ error: any Error) -> IndexStoreFailure {
    ZephyrLog.index.error(
      """
      The index database failed with \(resultCode(of: error), privacy: .public): \
      \(String(describing: error), privacy: .private)
      """
    )
    return .database(detail: String(localized: "an unexpected error", bundle: #bundle))
  }

  /**
   The SQLite result code behind a driver error, as a name rather than a number.

   The description beside it is private, because GRDB puts the failing SQL and
   its bound arguments in there and an argument can be a path out of the user's
   Dropbox. A result code names a class of failure and nothing about who hit
   it, so it is the part that can stay readable in a report from a machine
   where nobody enabled private data — which is every machine but a
   developer's.
   */
  private static func resultCode(of error: any Error) -> String {
    guard let databaseError = error as? DatabaseError else {
      // Not every failure down here is SQLite's. Naming the type is what tells
      // a driver error apart from a cancelled read or a file the sandbox
      // refused, and a type name says nothing about the user.
      return "no SQLite code, \(type(of: error))"
    }
    return String(describing: databaseError.extendedResultCode)
  }

  // MARK: Mutation machinery

  @discardableResult
  static func applyPage(
    _ mutations: [IndexMutation],
    history: [HistoryEventRecord],
    advancingCursorTo cursor: DeltaCursor,
    in db: Database
  ) throws -> [DropboxFileIdentifier] {
    let sidestepped = try apply(mutations, history: history, origin: .remote, in: db)
    try db.execute(
      sql: "INSERT INTO engine_state (key, value) VALUES (?, ?) "
        + "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
      arguments: [Self.cursorStateKey, cursor.rawValue]
    )
    return sidestepped
  }

  /// Applies mutations, returning the identifiers of ignored items that were
  /// renamed aside to make room for a remote item landing on their path.
  @discardableResult
  static func apply(
    _ mutations: [IndexMutation],
    history: [HistoryEventRecord],
    origin: MutationOrigin,
    in db: Database
  ) throws -> [DropboxFileIdentifier] {
    let hasPreservedState = try preservedStateExists(in: db)
    var sidestepped: [DropboxFileIdentifier] = []
    for mutation in mutations {
      switch mutation {
        case .upsert(var record):
          let existing = try IndexEntryRecord.fetchOne(db, key: record.dbxID.rawValue)
          // An ignored item's local state is authoritative; remote
          // changes to it stay suppressed until syncing resumes.
          if origin == .remote, let existing, existing.ignored { continue }
          record.metaGeneration = (existing?.metaGeneration ?? -1) + 1
          if let existing {
            carryLocalAttributes(from: existing, into: &record)
            if existing.pathNormalized != record.pathNormalized {
              try clearSyncErrors(atPaths: [existing.pathNormalized], in: db)
            }
          } else if hasPreservedState {
            try restorePreservedState(into: &record, in: db)
          }
          // Dropbox reports no dates for folders; a stable first-seen
          // date keeps Finder from rendering the Unix epoch.
          if record.itemType == .folder, record.clientModified == nil {
            record.clientModified = existing?.clientModified ?? Date()
          }
          try makeRoom(forUpsertOf: record, in: db, sidestepping: &sidestepped)
          try record.save(db)
        case .deleteSubtree(let path):
          let doomed: [IndexEntryRecord] =
            switch origin {
              case .remote: try doomedEntries(underTombstone: path, in: db)
              case .local: try entries(atOrUnder: path, in: db)
            }
          try remove(doomed, in: db)
      }
    }
    for event in history {
      try event.insert(db)
    }
    try HistoryEventRecord
      .filter(Column("recorded_at") < Date(timeIntervalSinceNow: -Self.historyRetention))
      .deleteAll(db)
    return sidestepped
  }

  /// Local-only attributes (tags, favorite rank, last-used date, xattrs, the
  /// ignored flag) belong to the system, not Dropbox; a remote change must
  /// not wipe them.
  private static func carryLocalAttributes(
    from existing: IndexEntryRecord,
    into record: inout IndexEntryRecord
  ) {
    record.tagData = record.tagData ?? existing.tagData
    record.favoriteRank = record.favoriteRank ?? existing.favoriteRank
    record.lastUsedDate = record.lastUsedDate ?? existing.lastUsedDate
    record.xattrs = record.xattrs ?? existing.xattrs
    record.ignored = record.ignored || existing.ignored
  }

  /// Frees a path for an item arriving under a different identifier. The
  /// occupant is dropped unless it must survive, in which case it is renamed
  /// aside and reported for change tracking.
  private static func makeRoom(
    forUpsertOf record: IndexEntryRecord,
    in db: Database,
    sidestepping sidestepped: inout [DropboxFileIdentifier]
  ) throws {
    guard
      let occupant = try entryOccupying(
        record.pathNormalized,
        otherThan: record.dbxID,
        in: db
      )
    else { return }
    guard try !mustSurviveEviction(occupant, in: db) else {
      try sidestep(occupant, in: db)
      sidestepped.append(occupant.dbxID)
      return
    }
    try remove(displacedEntries(of: occupant, in: db), in: db)
  }

  /// The row holding a path under a different identifier, if any; the unique
  /// path index allows at most one.
  private static func entryOccupying(
    _ path: NormalizedDropboxPath,
    otherThan id: DropboxFileIdentifier,
    in db: Database
  ) throws -> IndexEntryRecord? {
    try IndexEntryRecord
      .filter(Column("path_normalized") == path.rawValue)
      .filter(Column("dbx_id") != id.rawValue)
      .fetchOne(db)
  }

  /// The rows an upsert displaces from its path — empty when the occupant is
  /// one that survives, renamed aside.
  static func evictedEntries(
    byUpsertOf record: IndexEntryRecord,
    in db: Database
  ) throws -> [IndexEntryRecord] {
    guard
      let occupant = try entryOccupying(record.pathNormalized, otherThan: record.dbxID, in: db),
      try !mustSurviveEviction(occupant, in: db)
    else { return [] }
    return try displacedEntries(of: occupant, in: db)
  }

  /// The rows a displaced occupant takes with it. A folder cannot leave its
  /// children behind: they would keep their parent path, still enumerate,
  /// and resolve their parent to the item that replaced the folder.
  private static func displacedEntries(
    of occupant: IndexEntryRecord,
    in db: Database
  ) throws -> [IndexEntryRecord] {
    occupant.itemType == .folder
      ? try entries(atOrUnder: occupant.pathNormalized, in: db)
      : [occupant]
  }

  /// Whether a row displaced from its path must be renamed aside rather than
  /// dropped: an ignored item's remote copy is gone, so its row is the only
  /// record it exists, and a folder holding one must survive to keep it
  /// reachable.
  private static func mustSurviveEviction(
    _ occupant: IndexEntryRecord,
    in db: Database
  ) throws -> Bool {
    if occupant.ignored { return true }
    guard occupant.itemType == .folder else { return false }
    return try IndexEntryRecord
      .filter(under(occupant.pathNormalized))
      .filter(Column("ignored") == true)
      .fetchCount(db) > 0
  }

  /**
   The rows a remote tombstone actually removes: everything at and under the
   path except ignored items — which stay local by design — and the folders
   containing them, which must survive to keep them reachable.
   */
  static func doomedEntries(
    underTombstone path: NormalizedDropboxPath,
    in db: Database
  ) throws -> [IndexEntryRecord] {
    let rows = try entries(atOrUnder: path, in: db)
    let survivors = rows.filter(\.ignored)
    guard !survivors.isEmpty else { return rows }
    var kept = Set(survivors.map(\.dbxID))
    for row in rows where row.itemType == .folder {
      if survivors.contains(where: {
        $0.pathNormalized.rawValue.hasPrefix(row.pathNormalized.rawValue + "/")
      }) {
        kept.insert(row.dbxID)
      }
    }
    return rows.filter { !kept.contains($0.dbxID) }
  }

  /// The identifiers a remote tombstone actually removes.
  static func doomedIdentifiers(
    underTombstone path: NormalizedDropboxPath,
    in db: Database
  ) throws -> [DropboxFileIdentifier] {
    try doomedEntries(underTombstone: path, in: db).map(\.dbxID)
  }

  /// The row at a path and every row beneath it, parents before children.
  static func entries(
    atOrUnder path: NormalizedDropboxPath,
    in db: Database
  ) throws -> [IndexEntryRecord] {
    try IndexEntryRecord
      .filter(atOrUnder(path))
      .order(Column("path_normalized"))
      .fetchAll(db)
  }

  /// Drops rows from the index along with the sync errors recorded against
  /// their paths: `sync_error` is keyed on the path alone, so an error left
  /// behind by a delete or a rename is one nothing would ever clear.
  private static func remove(_ entries: [IndexEntryRecord], in db: Database) throws {
    guard !entries.isEmpty else { return }
    try deleteRows(
      of: IndexEntryRecord.self,
      whereColumn: "dbx_id",
      matches: entries.map(\.dbxID.rawValue),
      in: db
    )
    try clearSyncErrors(atPaths: entries.map(\.pathNormalized), in: db)
  }

  /// Drops the sync errors recorded against paths that have left the index.
  static func clearSyncErrors(
    atPaths paths: [NormalizedDropboxPath],
    in db: Database
  ) throws {
    try deleteRows(
      of: SyncErrorRecord.self,
      whereColumn: "path_normalized",
      matches: paths.map(\.rawValue),
      in: db
    )
  }

  private static func deleteRows<Record: TableRecord>(
    of type: Record.Type,
    whereColumn column: String,
    matches values: [String],
    in db: Database
  ) throws {
    for start in stride(from: 0, to: values.count, by: deletionChunkSize) {
      let chunk = values[start..<min(start + deletionChunkSize, values.count)]
      try type.filter(chunk.contains(Column(column))).deleteAll(db)
    }
  }

  /// Matches every row beneath a folder path.
  static func under(_ path: NormalizedDropboxPath) -> SQLExpression {
    Column("path_normalized").like("\(escapeLike(path.rawValue))/%", escape: "\\")
  }

  /// Matches the row at a path and every row beneath it.
  static func atOrUnder(_ path: NormalizedDropboxPath) -> SQLExpression {
    Column("path_normalized") == path.rawValue || under(path)
  }

  /// The most recent failure recorded against a path or anything beneath it.
  private static func newestSyncError(
    atOrUnder path: NormalizedDropboxPath,
    in db: Database
  ) throws -> SyncErrorRecord? {
    try SyncErrorRecord
      .filter(atOrUnder(path))
      .order(Column("occurred_at").desc)
      .fetchOne(db)
  }

  // MARK: Preserved local state

  private static func preservedStateExists(in db: Database) throws -> Bool {
    try PreservedLocalStateRecord.fetchCount(db) > 0
  }

  /// Takes back the attributes an index rebuild set aside for an item,
  /// consuming them so a later re-listing cannot undo changes made since.
  /// An item Dropbox re-created while the index was down comes back under a
  /// fresh identifier, so a path match counts too.
  private static func restorePreservedState(
    into record: inout IndexEntryRecord,
    in db: Database
  ) throws {
    guard
      let preserved =
        try PreservedLocalStateRecord.fetchOne(db, key: record.dbxID.rawValue)
        ?? PreservedLocalStateRecord
        .filter(Column("path_normalized") == record.pathNormalized.rawValue)
        .fetchOne(db)
    else { return }
    record.tagData = record.tagData ?? preserved.tagData
    record.favoriteRank = record.favoriteRank ?? preserved.favoriteRank
    record.lastUsedDate = record.lastUsedDate ?? preserved.lastUsedDate
    record.xattrs = record.xattrs ?? preserved.xattrs
    record.ignored = record.ignored || preserved.ignored
    try preserved.delete(db)
  }

  /// Renames a row aside — "name (ignored).ext", locally only — so a remote
  /// item can take its path; folder sidesteps carry their subtree.
  private static func sidestep(_ record: IndexEntryRecord, in db: Database) throws {
    let newName = try availableSidestepName(for: record, in: db)
    guard let newCasedPath = try? record.pathCased.parent.appending(newName) else { return }
    let newPath = newCasedPath.normalized
    try clearSyncErrors(atPaths: [record.pathNormalized], in: db)
    let renamed = IndexEntryRecord(
      dbxID: record.dbxID,
      pathNormalized: newPath,
      parentPathNormalized: newPath.parent,
      pathCased: newCasedPath,
      name: newName,
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
    try renamed.save(db)
    if record.itemType == .folder {
      try rewriteDescendantPaths(
        from: record.pathNormalized,
        to: newPath,
        fromCased: record.pathCased,
        toCased: newCasedPath,
        in: db
      )
    }
  }

  private static func availableSidestepName(
    for record: IndexEntryRecord,
    in db: Database
  ) throws -> String {
    let filename = FilePath(record.name)
    // An empty extension means a trailing dot, which belongs to the base name.
    let ext = filename.extension ?? ""
    let base = ext.isEmpty ? record.name : filename.stem ?? record.name
    for attempt in 1... {
      let suffix = attempt == 1 ? " (ignored)" : " (ignored \(attempt))"
      let candidate = ext.isEmpty ? base + suffix : "\(base)\(suffix).\(ext)"
      guard let path = try? record.pathCased.parent.appending(candidate) else { continue }
      let taken =
        try IndexEntryRecord
        .filter(Column("path_normalized") == path.normalized.rawValue)
        .fetchCount(db) > 0
      if !taken { return candidate }
    }
    fatalError("unreachable: the sidestep-name loop always returns")
  }

  static func escapeLike(_ string: String) -> String {
    // The escape character itself must be escaped first, or it would
    // double the escapes added for the wildcards.
    string
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "%", with: "\\%")
      .replacingOccurrences(of: "_", with: "\\_")
  }

  // MARK: Reads

  /// The item with the given Dropbox identifier.
  public func entry(forID id: DropboxFileIdentifier) async throws -> IndexEntryRecord? {
    try await read { db in
      try IndexEntryRecord.fetchOne(db, key: id.rawValue)
    }
  }

  /// The item at the given normalized path.
  public func entry(forPath path: NormalizedDropboxPath) async throws -> IndexEntryRecord? {
    try await read { db in
      try IndexEntryRecord
        .filter(Column("path_normalized") == path.rawValue)
        .fetchOne(db)
    }
  }

  /// The direct children of a folder, sorted by name.
  public func children(of parent: NormalizedDropboxPath) async throws -> [IndexEntryRecord] {
    try await read { db in
      try IndexEntryRecord
        .filter(Column("parent_path_normalized") == parent.rawValue)
        .order(Column("name"))
        .fetchAll(db)
    }
  }

  /// The persisted delta cursor, or `nil` before the first successful page.
  public func currentCursor() async throws -> DeltaCursor? {
    try await read { db in
      try String
        .fetchOne(
          db,
          sql: "SELECT value FROM engine_state WHERE key = ?",
          arguments: [Self.cursorStateKey]
        )
        .flatMap { try? DeltaCursor(validating: $0) }
    }
  }

  /// Whether the initial recursive indexing has completed.
  public func didFinishInitialIndex() async throws -> Bool {
    try await read { db in
      try String.fetchOne(
        db,
        sql: "SELECT value FROM engine_state WHERE key = ?",
        arguments: [Self.initialIndexCompleteKey]
      ) == "true"
    }
  }

  /// Counts of indexed files and folders.
  public func counts() async throws -> (files: UInt, folders: UInt) {
    try await read { db in
      let files =
        try IndexEntryRecord
        .filter(Column("item_type") != IndexItemType.folder.rawValue)
        .fetchCount(db)
      let folders =
        try IndexEntryRecord
        .filter(Column("item_type") == IndexItemType.folder.rawValue)
        .fetchCount(db)
      return (UInt(files), UInt(folders))
    }
  }

  /// Every indexed folder's cased path, in path order.
  public func folderPaths() async throws -> [DropboxPath] {
    try await read { db in
      try IndexEntryRecord
        .filter(Column("item_type") == IndexItemType.folder.rawValue)
        .order(Column("path_normalized"))
        .fetchAll(db)
        .map(\.pathCased)
    }
  }

  /**
   The indexed items whose own name contains `text`, best match first.

   The match is on the item's name rather than its whole path. A search for
   “Budget” that answered with every file under a folder called Budget would
   bury the one file the reader was looking for under the folder's contents.

   - Parameters:
     - text: What to look for, matched without regard to case, and without
       regard to whether an accent arrived composed or decomposed. An accent
       itself still counts: “resume” does not find “Résumé”, the same way it
       does not in Dropbox.
     - limit: How many items to return at most.
   - Returns: Matching items, ordered as ``IndexQuery`` describes, at most
     `limit` of them. Empty `text` matches nothing.
   */
  public func items(named text: String, limit: UInt = IndexQuery.defaultLimit) async throws
    -> [IndexEntryRecord]
  {
    try await items(matching: IndexQuery(nameContains: text, limit: limit))
  }

  /// The most recent history events, newest first.
  public func recentHistory(limit: UInt = 100) async throws -> [HistoryEventRecord] {
    try await read { db in
      try HistoryEventRecord
        .order(Column("recorded_at").desc)
        .limit(Int(clamping: limit))
        .fetchAll(db)
    }
  }

  /**
   All recorded per-item sync failures, newest first, each carrying the title
   and detail the UI shows.
   */
  public func syncErrors() async throws -> [SyncErrorRecord] {
    try await read { db in
      try SyncErrorRecord.order(Column("occurred_at").desc).fetchAll(db)
    }
  }

  /**
   The failure that has stopped syncing for the whole account, or `nil`
   while the account syncs.

   Only a read-write open migrates, so the app and the command line — which
   both read an index the extension owns — can meet a database written
   before this table existed. Such an index has recorded no account-wide
   failure, which is exactly `nil`.
   */
  public func engineError() async throws -> EngineErrorRecord? {
    try await read { db in
      guard try db.tableExists(EngineErrorRecord.databaseTableName) else { return nil }
      return try EngineErrorRecord.fetchOne(db, key: EngineErrorRecord.singletonID)
    }
  }

  /**
   The cached display names of the accounts that changed shared files,
   omitting any the cache does not hold or no longer trusts.

   Only a read-write open migrates, so the app and the command line — which
   both read an index the File Provider extension owns — can meet a database
   written before this cache existed. Such an index has cached nothing, which
   is exactly an empty answer.
   */
  public func cachedAccountNames(
    for accounts: [AccountIdentifier]
  ) async throws -> [AccountIdentifier: String] {
    guard !accounts.isEmpty else { return [:] }
    let identifiers = accounts.map(\.rawValue)
    let freshEnough = Date(timeIntervalSinceNow: -Self.accountNameRetention)
    return try await read { db -> [AccountIdentifier: String] in
      guard try db.tableExists(AccountNameRecord.databaseTableName) else { return [:] }
      return
        try AccountNameRecord
        .filter(identifiers.contains(Column("account_id")))
        .filter(Column("fetched_at") >= freshEnough)
        .fetchAll(db)
        .reduce(into: [AccountIdentifier: String]()) { $0[$1.accountID] = $1.displayName }
    }
  }

  /**
   Every entry excluded from syncing by the `com.dropbox.ignored` marker, in
   path order — the account's ignore list.
   */
  public func ignoredEntries() async throws -> [IndexEntryRecord] {
    try await read { db in
      try IndexEntryRecord
        .filter(Column("ignored") == true)
        .order(Column("path_normalized"))
        .fetchAll(db)
    }
  }

  /**
   How the index sees the item at a path: ignored, failing, synced, or
   unknown to it.

   A folder answers for its whole subtree, reporting the newest failure
   recorded at or beneath it, so a folder reads the way Finder badges one.
   The account root answers for the entire index.
   */
  public func status(ofPath path: NormalizedDropboxPath) async throws -> FileSyncStatus {
    try await read { db in
      guard !path.isRoot else {
        return try Self.newestSyncError(atOrUnder: path, in: db).map(FileSyncStatus.failed)
          ?? .synced
      }
      guard
        let entry =
          try IndexEntryRecord
          .filter(Column("path_normalized") == path.rawValue)
          .fetchOne(db)
      else { return .unknown }
      if entry.ignored { return .ignored }
      let failure =
        entry.itemType == .folder
        ? try Self.newestSyncError(atOrUnder: path, in: db)
        : try SyncErrorRecord.fetchOne(db, key: path.rawValue)
      return failure.map(FileSyncStatus.failed) ?? .synced
    }
  }

  // MARK: Writes

  /**
   Applies one delta page atomically: all mutations, their history events,
   and the cursor advance land in a single transaction.
   */
  public func applyDeltaPage(
    _ mutations: [IndexMutation],
    history: [HistoryEventRecord],
    advancingCursorTo cursor: DeltaCursor
  ) async throws {
    try ensureWritable()
    try await write { db in
      _ = try Self.applyPage(mutations, history: history, advancingCursorTo: cursor, in: db)
    }
    changeSignal?.post()
  }

  /**
   Marks the initial recursive indexing as complete.

   A completed listing has returned everything the account holds, so any
   local attributes a rebuild set aside for items it did not return belong to
   items that no longer exist; they are discarded here.
   */
  public func markInitialIndexComplete() async throws {
    try ensureWritable()
    try await write { db in
      try db.execute(
        sql: "INSERT INTO engine_state (key, value) VALUES (?, 'true') "
          + "ON CONFLICT(key) DO UPDATE SET value = 'true'",
        arguments: [Self.initialIndexCompleteKey]
      )
      try PreservedLocalStateRecord.deleteAll(db)
    }
  }

  /**
   Caches the display names Dropbox reported for accounts other than the linked
   one, so the next process — and the next notification — does not have to ask
   again.
   */
  public func cacheAccountNames(_ names: [AccountIdentifier: String]) async throws {
    guard !names.isEmpty else { return }
    try ensureWritable()
    try await write { db in
      for (account, displayName) in names {
        try AccountNameRecord(accountID: account, displayName: displayName).save(db)
      }
    }
  }

  /// Records a per-item sync failure.
  public func recordSyncError(_ record: SyncErrorRecord) async throws {
    try ensureWritable()
    try await write { db in
      try record.save(db)
    }
  }

  /**
   Clears any recorded sync failure for a path — after the item syncs
   cleanly, or because the user dismissed it.
   */
  public func clearSyncError(forPath path: NormalizedDropboxPath) async throws {
    try ensureWritable()
    try await write { db in
      try Self.clearSyncErrors(atPaths: [path], in: db)
    }
  }

  /**
   Records the failure that has stopped syncing for the whole account,
   replacing whatever failure stood before it.
   */
  public func recordEngineError(_ record: EngineErrorRecord) async throws {
    try ensureWritable()
    try await write { db in
      try record.save(db)
    }
  }

  /**
   Clears the account-wide failure, after anything at all syncs cleanly.

   Every successful operation reaches here, so a healthy account settles for
   the read: opening a write transaction per sync would cost far more than
   the failure it is looking for is worth.
   */
  public func clearEngineError() async throws {
    guard try await engineError() != nil else { return }
    try ensureWritable()
    try await write { db in
      _ = try EngineErrorRecord.deleteAll(db)
    }
  }

  /**
   Drops the indexed state, forcing a full re-index. Settings are not
   affected: the attributes Dropbox does not store — Finder tags, favorite
   ranks, last-used dates, extended attributes, and the ignore marker —
   survive the rebuild.

   Ignoring an item deletes its remote copy, so no re-listing could bring an
   ignored row back; those rows are re-inserted outright. Every other item's
   local attributes wait for the re-listing to return the item.
   */
  public func resetSyncState() async throws {
    try ensureWritable()
    try await write { db in
      let preservable =
        try IndexEntryRecord
        .filter(Self.hasLocalOnlyState)
        .fetchAll(db)
      try IndexEntryRecord.deleteAll(db)
      try HistoryEventRecord.deleteAll(db)
      try SyncErrorRecord.deleteAll(db)
      try EngineErrorRecord.deleteAll(db)
      try db.execute(sql: "DELETE FROM engine_state")
      // Anchors map to cursors of the dropped state; a surviving anchor
      // would hand enumerators a cursor Dropbox has already invalidated.
      try db.execute(sql: "DELETE FROM anchors")
      try db.execute(sql: "DELETE FROM anchor_changes")
      for entry in preservable where entry.ignored {
        try entry.insert(db)
      }
      for preserved in preservable.compactMap(PreservedLocalStateRecord.init(preserving:)) {
        try preserved.save(db)
      }
    }
  }

  // MARK: Plumbing

  func ensureWritable() throws {
    guard mode == .readWrite else { throw IndexStoreFailure.readOnly }
  }

  func read<Result: Sendable>(
    _ body: @escaping @Sendable (Database) throws -> Result
  ) async throws -> Result {
    do {
      return try await pool.read(body)
    } catch {
      throw Self.failure(from: error)
    }
  }

  func write<Result: Sendable>(
    _ body: @escaping @Sendable (Database) throws -> Result
  ) async throws -> Result {
    do {
      return try await pool.write(body)
    } catch {
      throw Self.failure(from: error)
    }
  }

  /// Whether this store may write.
  public enum AccessMode: Sendable {
    case readWrite

    case readOnly
  }

  /// Where a batch of mutations originates. Remote mutations respect ignored
  /// items (their local state is authoritative); local mutations are the
  /// user's own actions and apply unconditionally.
  enum MutationOrigin {
    case remote

    case local
  }
}

/// The index database schema.
extension SyncIndexStore {
  private static var migrator: DatabaseMigrator {
    var migrator = DatabaseMigrator()
    migrator.registerMigration("v1") { db in
      try db.create(table: "items") { table in
        table.primaryKey("dbx_id", .text)
        table.column("path_normalized", .text).notNull().unique()
        table.column("parent_path_normalized", .text).notNull().indexed()
        table.column("path_cased", .text).notNull()
        table.column("name", .text).notNull()
        // Searching by name is the one query with no path to seek on, so the
        // folded name is stored rather than computed per row. See the index
        // over it below.
        table.column("name_normalized", .text).notNull()
        table.column("item_type", .integer).notNull()
        table.column("rev", .text)
        table.column("content_hash", .text)
        table.column("symlink_target", .text)
        table.column("size", .integer)
        table.column("client_modified", .datetime)
        table.column("server_modified", .datetime)
        table.column("meta_generation", .integer).notNull().defaults(to: 0)
        table.column("tag_data", .blob)
        table.column("favorite_rank", .integer)
        table.column("last_used_date", .datetime)
        table.column("xattrs", .blob)
        table.column("ignored", .boolean).notNull().defaults(to: false)
      }
      // Everything a name search reads, so the scan it cannot avoid runs over
      // this index rather than over the table: the folded name it matches on,
      // the path it ranks and orders by, and the flag that excludes an item.
      // Measured over 200,000 rows, that is the difference between 17 ms and
      // 9 ms, and it is what keeps the whole-account case affordable.
      try db.create(
        index: "items_on_name_normalized",
        on: "items",
        columns: ["name_normalized", "path_normalized", "ignored"]
      )
      try db.create(table: "history_event") { table in
        table.autoIncrementedPrimaryKey("id")
        table.column("dbx_id", .text)
        table.column("path", .text).notNull()
        table.column("item_type", .integer).notNull()
        table.column("change_type", .integer).notNull()
        table.column("direction", .integer).notNull()
        table.column("size", .integer)
        table.column("rev", .text)
        table.column("content_hash", .text)
        table.column("recorded_at", .datetime).notNull().indexed()
        table.column("modified_by", .text)
      }
      try db.create(table: "sync_error") { table in
        table.primaryKey("path_normalized", .text)
        table.column("path", .text).notNull()
        table.column("title", .text).notNull()
        table.column("detail", .text)
        table.column("occurred_at", .datetime).notNull()
      }
      try db.create(table: "anchors") { table in
        table.autoIncrementedPrimaryKey("generation")
        table.column("cursor", .text).notNull()
        table.column("created_at", .datetime).notNull()
      }
      try db.create(table: "anchor_changes") { table in
        table.column("generation", .integer).notNull().indexed()
        table.column("dbx_id", .text).notNull()
        table.column("kind", .integer).notNull()
      }
      try db.create(table: "preserved_local_state") { table in
        table.primaryKey("dbx_id", .text)
        table.column("path_normalized", .text).notNull().indexed()
        table.column("ignored", .boolean).notNull().defaults(to: false)
        table.column("tag_data", .blob)
        table.column("favorite_rank", .integer)
        table.column("last_used_date", .datetime)
        table.column("xattrs", .blob)
      }
      try db.create(table: "engine_error") { table in
        table.primaryKey("id", .integer)
        table.column("title", .text).notNull()
        table.column("detail", .text)
        table.column("occurred_at", .datetime).notNull()
      }
      try db.create(table: "account_name") { table in
        table.primaryKey("account_id", .text)
        table.column("display_name", .text).notNull()
        table.column("fetched_at", .datetime).notNull()
      }
      try db.create(table: "upload_session") { table in
        table.primaryKey("path_normalized", .text)
        table.column("session_id", .text).notNull()
        table.column("committed_offset", .integer).notNull()
        table.column("prefix_hash", .text).notNull()
        table.column("started_at", .datetime).notNull().indexed()
      }
      try db.create(table: "engine_state") { table in
        table.primaryKey("key", .text)
        table.column("value", .text).notNull()
      }
    }
    return migrator
  }
}
