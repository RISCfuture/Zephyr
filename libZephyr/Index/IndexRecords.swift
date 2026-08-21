import Foundation
import GRDB

/// The kind of item an index row describes.
public enum IndexItemType: Int, Sendable, Codable, Equatable {
  case file = 0

  case folder = 1

  case symlink = 2
}

/**
 One row of the sync index: a known remote item with the identity facts sync
 decisions need (revision, content hash) and the path facts enumeration needs.
 */
public struct IndexEntryRecord: Sendable, Equatable, Codable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "items"

  /// The Dropbox file identifier — also the File Provider item identifier.
  public let dbxID: DropboxFileIdentifier

  /// The normalized path, unique per item.
  public let pathNormalized: NormalizedDropboxPath

  /// The parent folder's normalized path (`""` for items in the root).
  public let parentPathNormalized: NormalizedDropboxPath

  /// The cased display path.
  public let pathCased: DropboxPath

  public let name: String

  /**
   ``name`` reduced to the form a search compares — see
   ``NormalizedDropboxPath/folded(_:)``.

   Derived rather than supplied, so it cannot fall out of step with ``name``.
   It is stored and indexed rather than folded per row at query time, which is
   what lets a name search seek an index instead of walking the whole table.
   */
  public let nameNormalized: String

  public let itemType: IndexItemType

  /// The current revision; `nil` for folders.
  public let revision: FileRevision?

  /// The current content hash; `nil` for folders and non-downloadable files.
  public let contentHash: ContentHash?

  public let symlinkTarget: String?

  public let size: UInt64?

  /**
   The client-reported modification date. Dropbox has none for folders, so the
   index stamps a stable first-seen date instead (Finder renders a `nil` date
   as the Unix epoch).
   */
  public var clientModified: Date?

  public let serverModified: Date?

  /// Bumped on every metadata change; backs the File Provider metadata version.
  public var metaGeneration: Int64

  /**
   Finder tag data the system asked the provider to persist. Local-only: never
   sent to Dropbox, preserved across remote upserts.
   */
  public var tagData: Data?

  /// The item's sidebar favorite rank. Local-only, like ``tagData``.
  public var favoriteRank: Int64?

  /// The system-reported last-used date. Local-only, like ``tagData``.
  public var lastUsedDate: Date?

  /**
   Extended attributes the system asked the provider to persist. Dropbox stores
   no xattrs, so these are local-only, like ``tagData``.
   */
  public var xattrs: [String: Data]?

  /**
   Whether the item is excluded from syncing by the `com.dropbox.ignored`
   marker: its local state is authoritative and remote changes to it are
   suppressed until syncing resumes.
   */
  public var ignored = false

  public init(
    dbxID: DropboxFileIdentifier,
    pathNormalized: NormalizedDropboxPath,
    parentPathNormalized: NormalizedDropboxPath,
    pathCased: DropboxPath,
    name: String,
    itemType: IndexItemType,
    revision: FileRevision?,
    contentHash: ContentHash?,
    symlinkTarget: String?,
    size: UInt64?,
    clientModified: Date?,
    serverModified: Date?,
    metaGeneration: Int64 = 0,
    tagData: Data? = nil,
    favoriteRank: Int64? = nil,
    lastUsedDate: Date? = nil,
    xattrs: [String: Data]? = nil,
    ignored: Bool = false
  ) {
    self.dbxID = dbxID
    self.pathNormalized = pathNormalized
    self.parentPathNormalized = parentPathNormalized
    self.pathCased = pathCased
    self.name = name
    nameNormalized = NormalizedDropboxPath.folded(name)
    self.itemType = itemType
    self.revision = revision
    self.contentHash = contentHash
    self.symlinkTarget = symlinkTarget
    self.size = size
    self.clientModified = clientModified
    self.serverModified = serverModified
    self.metaGeneration = metaGeneration
    self.tagData = tagData
    self.favoriteRank = favoriteRank
    self.lastUsedDate = lastUsedDate
    self.xattrs = xattrs
    self.ignored = ignored
  }

  public enum CodingKeys: String, CodingKey {
    case dbxID = "dbx_id"

    case pathNormalized = "path_normalized"

    case parentPathNormalized = "parent_path_normalized"

    case pathCased = "path_cased"

    case name

    case nameNormalized = "name_normalized"

    case itemType = "item_type"

    case revision = "rev"

    case contentHash = "content_hash"

    case symlinkTarget = "symlink_target"

    case size

    case clientModified = "client_modified"

    case serverModified = "server_modified"

    case metaGeneration = "meta_generation"

    case tagData = "tag_data"

    case favoriteRank = "favorite_rank"

    case lastUsedDate = "last_used_date"

    case xattrs

    case ignored
  }
}

/// A sync-history event, kept for the UI and the hash-to-revision lookup.
public struct HistoryEventRecord: Sendable, Codable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "history_event"

  public var id: Int64?

  public let dbxID: DropboxFileIdentifier?

  public let path: DropboxPath

  public let itemType: IndexItemType

  public let changeType: ChangeType

  public let direction: Direction

  public let size: UInt64?

  public let revision: FileRevision?

  public let contentHash: ContentHash?

  /**
   The account that made the change, when Dropbox named one — it reports a
   modifier only for files inside a shared folder. A change this Mac made
   carries no identifier: it belongs to the linked account by definition.
   */
  public let modifiedBy: AccountIdentifier?

  public let recordedAt: Date

  public init(
    dbxID: DropboxFileIdentifier?,
    path: DropboxPath,
    itemType: IndexItemType,
    changeType: ChangeType,
    direction: Direction,
    size: UInt64?,
    revision: FileRevision?,
    contentHash: ContentHash?,
    modifiedBy: AccountIdentifier? = nil,
    recordedAt: Date = Date()
  ) {
    self.dbxID = dbxID
    self.path = path
    self.itemType = itemType
    self.changeType = changeType
    self.direction = direction
    self.size = size
    self.revision = revision
    self.contentHash = contentHash
    self.modifiedBy = modifiedBy
    self.recordedAt = recordedAt
  }

  public mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }

  /// The direction of a recorded change.
  public enum Direction: Int, Sendable, Codable {
    case down = 0

    case up = 1
  }

  /// What happened to the item.
  public enum ChangeType: Int, Sendable, Codable {
    case added = 0

    case modified = 1

    case removed = 2
  }

  public enum CodingKeys: String, CodingKey {
    case id

    case dbxID = "dbx_id"

    case path

    case itemType = "item_type"

    case changeType = "change_type"

    case direction

    case size

    case revision = "rev"

    case contentHash = "content_hash"

    case modifiedBy = "modified_by"

    case recordedAt = "recorded_at"
  }
}

/// A recorded per-item sync failure, surfaced in status output and retried later.
public struct SyncErrorRecord: Sendable, Codable, Equatable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "sync_error"

  public let pathNormalized: NormalizedDropboxPath

  public let path: DropboxPath

  public let title: String

  public let detail: String?

  public let occurredAt: Date

  public init(
    pathNormalized: NormalizedDropboxPath,
    path: DropboxPath,
    title: String,
    detail: String?,
    occurredAt: Date = Date()
  ) {
    self.pathNormalized = pathNormalized
    self.path = path
    self.title = title
    self.detail = detail
    self.occurredAt = occurredAt
  }

  public enum CodingKeys: String, CodingKey {
    case pathNormalized = "path_normalized"

    case path

    case title

    case detail

    case occurredAt = "occurred_at"
  }
}

/**
 The failure that has stopped syncing for a whole account, as opposed to the
 items in ``SyncErrorRecord`` that individually couldn't sync.

 A revoked token, an unreachable Dropbox, or an index that will not open is
 not a file that failed, and counting it among them reads as "1 couldn't
 sync" for an account where nothing is syncing at all. An index holds at most
 one of these — the current one — so the row is keyed on ``singletonID``.
 */
public struct EngineErrorRecord: Sendable, Codable, Equatable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "engine_error"

  /// The key of the only row the table ever holds.
  public static let singletonID: Int64 = 1

  public let id: Int64

  public let title: String

  public let detail: String?

  public let occurredAt: Date

  public init(title: String, detail: String?, occurredAt: Date = Date()) {
    self.id = Self.singletonID
    self.title = title
    self.detail = detail
    self.occurredAt = occurredAt
  }

  public enum CodingKeys: String, CodingKey {
    case id

    case title

    case detail

    case occurredAt = "occurred_at"
  }
}

/**
 The attributes of one indexed item that Dropbox does not store, parked while
 the index is rebuilt.

 Finder tags, favorite ranks, last-used dates, extended attributes, and the
 ignore marker exist only on this Mac, so a re-listing cannot restore them:
 ``SyncIndexStore/resetSyncState()`` writes them here and the re-listing's
 first upsert of each item takes them back.
 */
struct PreservedLocalStateRecord: Sendable, Codable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "preserved_local_state"

  let dbxID: DropboxFileIdentifier

  /// The path the item held when its state was set aside, matched when the
  /// item returns from the re-listing under a fresh identifier.
  let pathNormalized: NormalizedDropboxPath

  let ignored: Bool

  let tagData: Data?

  let favoriteRank: Int64?

  let lastUsedDate: Date?

  let xattrs: [String: Data]?

  /// The state worth preserving for an entry, or `nil` when it has none.
  init?(preserving entry: IndexEntryRecord) {
    guard
      entry.ignored || entry.tagData != nil || entry.favoriteRank != nil
        || entry.lastUsedDate != nil || entry.xattrs != nil
    else { return nil }
    dbxID = entry.dbxID
    pathNormalized = entry.pathNormalized
    ignored = entry.ignored
    tagData = entry.tagData
    favoriteRank = entry.favoriteRank
    lastUsedDate = entry.lastUsedDate
    xattrs = entry.xattrs
  }

  enum CodingKeys: String, CodingKey {
    case dbxID = "dbx_id"

    case pathNormalized = "path_normalized"

    case ignored

    case tagData = "tag_data"

    case favoriteRank = "favorite_rank"

    case lastUsedDate = "last_used_date"

    case xattrs
  }
}

/**
 The display name of an account other than the linked one, cached so that
 attributing a change to a person does not cost a request per notification.

 The linked account is deliberately absent: its name lives in
 ``AccountConfiguration``, and duplicating it here would make the index a
 second answer to who this Mac is signed in as.
 */
struct AccountNameRecord: Sendable, Codable, Equatable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "account_name"

  let accountID: AccountIdentifier

  let displayName: String

  /// When Dropbox last reported the name. People rename themselves, so a
  /// stale enough row is fetched again rather than trusted forever.
  let fetchedAt: Date

  init(accountID: AccountIdentifier, displayName: String, fetchedAt: Date = Date()) {
    self.accountID = accountID
    self.displayName = displayName
    self.fetchedAt = fetchedAt
  }

  enum CodingKeys: String, CodingKey {
    case accountID = "account_id"

    case displayName = "display_name"

    case fetchedAt = "fetched_at"
  }
}

/**
 A chunked upload left in flight, so the next process to upload the same path
 can carry it on instead of resending everything.

 The row is what makes a resume provable rather than hopeful: it names the
 session, says how many bytes Dropbox has acknowledged, and carries the
 content hash of exactly those bytes. A resume goes ahead only when Dropbox
 still agrees on the offset *and* the file's first ``committedOffset`` bytes
 still hash to ``prefixHash``; anything else starts a fresh session, which is
 always correct and costs only the bytes already sent.
 */
struct UploadSessionRecord: Sendable, Codable, Equatable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "upload_session"

  /// How long Dropbox keeps an upload session usable. Appending to or
  /// finishing an older one is refused, so a record past it names nothing.
  static let sessionWindow: TimeInterval = 48 * 60 * 60

  /// The destination path, which is what a retry of the same write shares
  /// with the attempt that was interrupted — the staged local file does not
  /// survive the process that was handed it.
  let pathNormalized: NormalizedDropboxPath

  let sessionID: UploadSessionIdentifier

  /// The bytes Dropbox has acknowledged. Written only after an append
  /// returns, so it can never claim more than the server holds.
  let committedOffset: UInt64

  /// The Dropbox content hash of the file's first ``committedOffset`` bytes,
  /// which is the proof that a resumed upload continues the same content.
  let prefixHash: ContentHash

  /// When the session was opened, against which Dropbox's window is measured.
  let startedAt: Date

  /// Whether Dropbox's session window is still open on this record.
  func isUsable(at date: Date = Date()) -> Bool {
    date.timeIntervalSince(startedAt) < Self.sessionWindow
  }

  enum CodingKeys: String, CodingKey {
    case pathNormalized = "path_normalized"

    case sessionID = "session_id"

    case committedOffset = "committed_offset"

    case prefixHash = "prefix_hash"

    case startedAt = "started_at"
  }
}

/// What the index can say about the sync state of one path.
public enum FileSyncStatus: Sendable, Equatable {
  /**
   The item is indexed and nothing failed against it — nor, for a folder,
   against anything beneath it.
   */
  case synced

  /// The item is excluded from syncing by the `com.dropbox.ignored` marker.
  case ignored

  /// The item — or, for a folder, something beneath it — last failed to sync.
  case failed(SyncErrorRecord)

  /// Nothing at the path is indexed.
  case unknown
}

extension DropboxFileIdentifier: DatabaseValueConvertible {
  public var databaseValue: DatabaseValue { rawValue.databaseValue }

  public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> DropboxFileIdentifier? {
    String.fromDatabaseValue(dbValue).flatMap { try? DropboxFileIdentifier(validating: $0) }
  }
}

extension AccountIdentifier: DatabaseValueConvertible {
  public var databaseValue: DatabaseValue { rawValue.databaseValue }

  public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> AccountIdentifier? {
    String.fromDatabaseValue(dbValue).flatMap { try? AccountIdentifier(validating: $0) }
  }
}

extension UploadSessionIdentifier: DatabaseValueConvertible {
  var databaseValue: DatabaseValue { rawValue.databaseValue }

  static func fromDatabaseValue(_ dbValue: DatabaseValue) -> UploadSessionIdentifier? {
    String.fromDatabaseValue(dbValue).flatMap { try? UploadSessionIdentifier(validating: $0) }
  }
}

extension DropboxPath: DatabaseValueConvertible {
  public var databaseValue: DatabaseValue { rawValue.databaseValue }

  public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> DropboxPath? {
    String.fromDatabaseValue(dbValue).flatMap { try? DropboxPath(validating: $0) }
  }
}

extension NormalizedDropboxPath: DatabaseValueConvertible {
  public var databaseValue: DatabaseValue { rawValue.databaseValue }

  public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> NormalizedDropboxPath? {
    String.fromDatabaseValue(dbValue).flatMap { try? NormalizedDropboxPath(validating: $0) }
  }
}

extension FileRevision: DatabaseValueConvertible {
  public var databaseValue: DatabaseValue { rawValue.databaseValue }

  public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> FileRevision? {
    String.fromDatabaseValue(dbValue).flatMap { try? FileRevision(validating: $0) }
  }
}

extension ContentHash: DatabaseValueConvertible {
  public var databaseValue: DatabaseValue { rawValue.databaseValue }

  public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> ContentHash? {
    String.fromDatabaseValue(dbValue).flatMap { try? ContentHash(validating: $0) }
  }
}
