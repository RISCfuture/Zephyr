import Foundation
import GRDB

/**
 A search over the sync index.

 The index describes the whole account rather than the bytes on this Mac, so a
 query answers for files that have never been downloaded — the thing a client
 that searches a local folder cannot do. Every predicate is optional; a query
 that sets none matches the whole account.

 ## Ordering

 Results come back best match first, which for a name search means: an exact
 name, then a name that starts with the text, then a name that merely contains
 it. Ties go to the shallower path, then to the path itself. A search that
 answered with four thousand rows in the order SQLite happened to read them
 would be a listing rather than a search.

 Without ``nameContains`` there is nothing to rank, and results come back in
 path order — parents before children, the order the rest of the index uses.
 */
public struct IndexQuery: Sendable {
  /// How many items a query returns when the caller names no limit.
  public static let defaultLimit: UInt = 50

  /**
   Text an item's own name must contain, compared without regard to case or
   to whether an accent arrived composed or decomposed. An accent itself
   still counts: “resume” does not find “Résumé”, as in Dropbox.

   The match is on the name rather than the whole path: a search for
   “Budget” that answered with every file under a folder called Budget
   would bury the one file the reader wanted under the folder's contents.
   */
  public let nameContains: String?

  /// A folder to search beneath. The folder itself is not a result, and the
  /// account root means the whole account.
  public let subtree: NormalizedDropboxPath?

  /// The kinds of item to return; `nil` for every kind.
  public let itemTypes: Set<IndexItemType>?

  /// The smallest size to return. Folders carry no size and so never satisfy
  /// a size bound.
  public let minimumSize: UInt64?

  /// The largest size to return, on the same terms as ``minimumSize``.
  public let maximumSize: UInt64?

  /// The earliest client-reported modification date to return.
  public let modifiedAfter: Date?

  /// The latest client-reported modification date to return.
  public let modifiedBefore: Date?

  /**
   Whether items excluded from syncing take part.

   They are left out by default for the reason path completion leaves them
   out: excluding an item deleted Dropbox's copy, so naming one asks Dropbox
   about an item it no longer holds.
   */
  public let includesExcluded: Bool

  /// How many items to return at most.
  public let limit: UInt

  /// Creates a query. Every predicate defaults to matching everything.
  public init(
    nameContains: String? = nil,
    subtree: NormalizedDropboxPath? = nil,
    itemTypes: Set<IndexItemType>? = nil,
    minimumSize: UInt64? = nil,
    maximumSize: UInt64? = nil,
    modifiedAfter: Date? = nil,
    modifiedBefore: Date? = nil,
    includesExcluded: Bool = false,
    limit: UInt = Self.defaultLimit
  ) {
    self.nameContains = nameContains
    self.subtree = subtree
    self.itemTypes = itemTypes
    self.minimumSize = minimumSize
    self.maximumSize = maximumSize
    self.modifiedAfter = modifiedAfter
    self.modifiedBefore = modifiedBefore
    self.includesExcluded = includesExcluded
    self.limit = limit
  }
}

extension SyncIndexStore {
  /**
   The indexed items a query matches.

   - Parameter query: What to look for, and how many to answer with.
   - Returns: Matching items in the order ``IndexQuery`` describes, at most
     ``IndexQuery/limit`` of them. A ``IndexQuery/nameContains`` that folds
     away to nothing matches nothing, rather than matching everything.
   */
  public func items(matching query: IndexQuery) async throws -> [IndexEntryRecord] {
    guard query.limit > 0 else { return [] }
    let compiled = CompiledIndexQuery(query)
    guard !compiled.matchesNothing else { return [] }
    return try await read { db in
      try IndexEntryRecord.fetchAll(db, sql: compiled.sql, arguments: compiled.arguments)
    }
  }
}

/**
 One ``IndexQuery`` turned into a statement and its arguments.

 The clauses and the arguments are accumulated together so the two cannot
 drift out of step, which is the failure a hand-built SQL string invites.
 */
struct CompiledIndexQuery {
  /// Whether the query is unsatisfiable on its face, and so needs no statement.
  let matchesNothing: Bool

  let sql: String

  let arguments: StatementArguments

  init(_ query: IndexQuery) {
    let needle = query.nameContains.map(NormalizedDropboxPath.folded)
    guard needle.map({ !$0.isEmpty }) ?? true else {
      matchesNothing = true
      (sql, arguments) = ("", StatementArguments())
      return
    }
    matchesNothing = false

    var conditions = Conditions()
    Self.restrict(&conditions, toNamesContaining: needle)
    Self.restrict(&conditions, to: query.subtree)
    Self.restrict(&conditions, to: query.itemTypes)
    Self.restrict(&conditions, from: query.minimumSize, to: query.maximumSize)
    Self.restrict(&conditions, after: query.modifiedAfter, before: query.modifiedBefore)
    if !query.includesExcluded { conditions.require("ignored = 0") }

    var ordering = Conditions()
    Self.order(&ordering, byRelevanceTo: needle)

    sql = """
      SELECT * FROM \(IndexEntryRecord.databaseTableName)\(conditions.whereClause) ORDER BY \
      \(ordering.clauses.joined(separator: ", ")) LIMIT ?
      """
    arguments = StatementArguments(
      conditions.arguments + ordering.arguments + [Int(clamping: query.limit)]
    )
  }

  /**
   Restricts to items whose own name contains the folded text.

   `name_normalized` is stored already folded and carries its own index, so
   the comparison is Dropbox's rather than SQLite's ASCII-only `LIKE`, and
   the leading characters of an exact or prefix match seek that index.
   */
  private static func restrict(_ conditions: inout Conditions, toNamesContaining needle: String?) {
    guard let needle else { return }
    conditions.require("name_normalized LIKE ? ESCAPE '\\'", Self.containing(needle))
  }

  /**
   Restricts to the rows beneath a folder, as a range rather than a `LIKE`.

   ``SyncIndexStore/under(_:)`` spells this as `LIKE 'path/%'`, which SQLite
   cannot reduce to a seek on a `BINARY`-collated column. A half-open range
   can, and `path_normalized` is unique and therefore indexed: `/` is byte
   0x2F, so `0` is the byte immediately after it and bounds the subtree exactly.
   `/Docs-old` sorts below `/Docs/` and is left out, which is the boundary the
   cheaper spelling of this exists to get right.
   */
  private static func restrict(_ conditions: inout Conditions, to subtree: NormalizedDropboxPath?) {
    guard let subtree, !subtree.isRoot else { return }
    conditions.require(
      "path_normalized >= ? AND path_normalized < ?",
      subtree.rawValue + "/",
      subtree.rawValue + "0"
    )
  }

  /// Restricts to a set of item kinds.
  private static func restrict(_ conditions: inout Conditions, to itemTypes: Set<IndexItemType>?) {
    guard let itemTypes, !itemTypes.isEmpty else { return }
    // Sorted so that one set of kinds always spells one statement, which is
    // what lets SQLite reuse a prepared one.
    let kinds = itemTypes.map(\.rawValue).sorted()
    let placeholders = Array(repeating: "?", count: kinds.count).joined(separator: ", ")
    conditions.require("item_type IN (\(placeholders))", kinds)
  }

  /// Restricts to a range of sizes. A folder stores no size, so a size bound
  /// excludes folders by construction.
  private static func restrict(
    _ conditions: inout Conditions,
    from minimumSize: UInt64?,
    to maximumSize: UInt64?
  ) {
    if let minimumSize { conditions.require("size >= ?", minimumSize) }
    if let maximumSize { conditions.require("size <= ?", maximumSize) }
  }

  /// Restricts to a range of client-reported modification dates — the date
  /// `zephyr ls` and `zephyr ignored` show.
  private static func restrict(
    _ conditions: inout Conditions,
    after modifiedAfter: Date?,
    before modifiedBefore: Date?
  ) {
    if let modifiedAfter { conditions.require("client_modified >= ?", modifiedAfter) }
    if let modifiedBefore { conditions.require("client_modified <= ?", modifiedBefore) }
  }

  /**
   Orders by how well each row answers the search.

   `LIMIT` turns this into a bounded top-N sort inside SQLite, so a search
   whose text matches half the account still costs the memory of one page of
   results rather than of every match.
   */
  private static func order(_ ordering: inout Conditions, byRelevanceTo needle: String?) {
    guard let needle else {
      ordering.require("path_normalized")
      return
    }
    ordering.require(
      """
      CASE WHEN name_normalized = ? THEN 0 WHEN name_normalized LIKE ? ESCAPE '\\' THEN 1 ELSE 2 END
      """,
      needle,
      Self.startingWith(needle)
    )
    ordering.require(
      "length(path_normalized) - length(replace(path_normalized, '/', ''))"
    )
    ordering.require("path_normalized")
  }

  /// The `LIKE` pattern matching a folded needle anywhere in a name.
  private static func containing(_ needle: String) -> String {
    "%\(SyncIndexStore.escapeLike(needle))%"
  }

  /// The `LIKE` pattern matching a folded needle at the start of a name.
  private static func startingWith(_ needle: String) -> String {
    "\(SyncIndexStore.escapeLike(needle))%"
  }

  /// SQL fragments and the arguments they consume, appended in step.
  private struct Conditions {
    private(set) var clauses: [String] = []

    private(set) var arguments: [any DatabaseValueConvertible] = []

    /// The `WHERE` clause the accumulated fragments make, or nothing at all
    /// when no predicate was added.
    var whereClause: String {
      clauses.isEmpty ? "" : " WHERE \(clauses.joined(separator: " AND "))"
    }

    mutating func require(_ clause: String, _ values: any DatabaseValueConvertible...) {
      clauses.append(clause)
      arguments.append(contentsOf: values)
    }

    mutating func require(_ clause: String, _ values: [any DatabaseValueConvertible]) {
      clauses.append(clause)
      arguments.append(contentsOf: values)
    }
  }
}
