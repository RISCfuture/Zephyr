import Foundation
import GRDB
import Testing

@testable import libZephyr

@Suite
struct IndexQueryTests {
  @Test
  func searchesOnlyBeneathTheFolderItWasGiven() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }

    // "/Docs-old" sorts between "/Docs" and "/Docs/", so a subtree bound that
    // is off by one character sweeps it in. It is the whole reason the bound
    // is a range rather than a prefix test.
    try await store.applyDeltaPage(
      [
        .upsert(try folderRecord(id: "id:d1", path: "/Docs")),
        .upsert(try fileRecord(id: "id:d2", path: "/Docs/report.txt")),
        .upsert(try fileRecord(id: "id:d3", path: "/Docs/Deep/report.txt")),
        .upsert(try fileRecord(id: "id:d4", path: "/Docs-old/report.txt")),
        .upsert(try fileRecord(id: "id:d5", path: "/Elsewhere/report.txt"))
      ],
      history: [],
      advancingCursorTo: try cursor("c1")
    )

    let found = try await store.items(
      matching: IndexQuery(
        nameContains: "report",
        subtree: try DropboxPath(validating: "/Docs").normalized
      )
    )
    #expect(
      found.map(\.pathNormalized.rawValue) == ["/docs/report.txt", "/docs/deep/report.txt"]
    )
  }

  @Test
  func rootAsASubtreeSearchesTheWholeAccount() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }

    try await store.applyDeltaPage(
      [
        .upsert(try fileRecord(id: "id:r1", path: "/Docs/report.txt")),
        .upsert(try fileRecord(id: "id:r2", path: "/Elsewhere/report.txt"))
      ],
      history: [],
      advancingCursorTo: try cursor("c1")
    )

    let found = try await store.items(
      matching: IndexQuery(nameContains: "report", subtree: .root)
    )
    #expect(found.count == 2)
  }

  @Test
  func answersWithTheBestMatchFirst() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }

    try await store.applyDeltaPage(
      [
        .upsert(try fileRecord(id: "id:b1", path: "/Archive/Q3-budget-draft.md")),
        .upsert(try fileRecord(id: "id:b2", path: "/Docs/budget-2026.numbers")),
        .upsert(try fileRecord(id: "id:b3", path: "/Work/Team/budget")),
        .upsert(try fileRecord(id: "id:b4", path: "/budget"))
      ],
      history: [],
      advancingCursorTo: try cursor("c1")
    )

    let found = try await store.items(matching: IndexQuery(nameContains: "budget"))
    // Exact names first and the shallower of the two ahead; then the name that
    // begins with the text; then the one that merely contains it.
    #expect(
      found.map(\.pathNormalized.rawValue) == [
        "/budget",
        "/work/team/budget",
        "/docs/budget-2026.numbers",
        "/archive/q3-budget-draft.md"
      ]
    )
  }

  @Test
  func aBetterMatchOutranksAnEarlierOneEvenPastTheLimit() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }

    // In path order the exact match comes last. Ranking has to be decided over
    // every match rather than over the first few the table happens to yield.
    var entries = try (1...20).map {
      try fileRecord(id: "id:a\($0)", path: "/AAA/report-\($0).txt")
    }
    entries.append(try fileRecord(id: "id:z1", path: "/ZZZ/report"))
    try await store.applyDeltaPage(
      entries.map { .upsert($0) },
      history: [],
      advancingCursorTo: try cursor("c1")
    )

    let found = try await store.items(matching: IndexQuery(nameContains: "report", limit: 1))
    #expect(found.map(\.pathNormalized.rawValue) == ["/zzz/report"])
  }

  @Test
  func withoutTextToMatchResultsComeBackInPathOrder() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }

    try await store.applyDeltaPage(
      [
        .upsert(try fileRecord(id: "id:p2", path: "/b.txt")),
        .upsert(try fileRecord(id: "id:p1", path: "/a.txt"))
      ],
      history: [],
      advancingCursorTo: try cursor("c1")
    )

    let found = try await store.items(matching: IndexQuery(itemTypes: [.file]))
    #expect(found.map(\.pathNormalized.rawValue) == ["/a.txt", "/b.txt"])
  }

  @Test
  func restrictsToTheKindsOfItemAsked() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }

    try await store.applyDeltaPage(
      [
        .upsert(try folderRecord(id: "id:k1", path: "/Notes")),
        .upsert(try fileRecord(id: "id:k2", path: "/Notes.txt"))
      ],
      history: [],
      advancingCursorTo: try cursor("c1")
    )

    let folders = try await store.items(
      matching: IndexQuery(nameContains: "notes", itemTypes: [.folder])
    )
    #expect(folders.map(\.name) == ["Notes"])
  }

  @Test
  func aSizeBoundLeavesOutFoldersBecauseTheyHaveNoSize() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }

    try await store.applyDeltaPage(
      [
        .upsert(try folderRecord(id: "id:s1", path: "/Big")),
        .upsert(try fileRecord(id: "id:s2", path: "/Big/small.txt", size: 10)),
        .upsert(try fileRecord(id: "id:s3", path: "/Big/large.txt", size: 5_000))
      ],
      history: [],
      advancingCursorTo: try cursor("c1")
    )

    #expect(
      try await store.items(matching: IndexQuery(minimumSize: 100)).map(\.name) == [
        "large.txt"
      ]
    )
    #expect(
      try await store.items(matching: IndexQuery(maximumSize: 100)).map(\.name) == [
        "small.txt"
      ]
    )
  }

  @Test
  func restrictsToARangeOfModificationDates() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }

    // `fileRecord` stamps client_modified at 1_000_000.
    let stamped = Date(timeIntervalSince1970: 1_000_000)
    try await store.applyDeltaPage(
      [.upsert(try fileRecord(id: "id:t1", path: "/dated.txt"))],
      history: [],
      advancingCursorTo: try cursor("c1")
    )

    #expect(
      try await store.items(
        matching: IndexQuery(modifiedAfter: stamped.addingTimeInterval(-1))
      ).count == 1
    )
    #expect(
      try await store.items(
        matching: IndexQuery(modifiedAfter: stamped.addingTimeInterval(1))
      ).isEmpty
    )
    #expect(
      try await store.items(
        matching: IndexQuery(modifiedBefore: stamped.addingTimeInterval(-1))
      ).isEmpty
    )
  }

  @Test
  func excludedItemsTakePartOnlyWhenAsked() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }

    try await store.applyDeltaPage(
      [.upsert(try fileRecord(id: "id:e1", path: "/Notes/gone.txt"))],
      history: [],
      advancingCursorTo: try cursor("c1")
    )
    _ = try await store.setIgnoredState(true, forID: try DropboxFileIdentifier(validating: "id:e1"))

    #expect(try await store.items(matching: IndexQuery(nameContains: "gone")).isEmpty)
    #expect(
      try await store.items(
        matching: IndexQuery(nameContains: "gone", includesExcluded: true)
      ).count == 1
    )
  }

  @Test
  func aQueryWithNothingToMatchOnAnswersWithNothing() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }

    try await store.applyDeltaPage(
      [.upsert(try fileRecord(id: "id:n1", path: "/a.txt"))],
      history: [],
      advancingCursorTo: try cursor("c1")
    )

    // Asking for a name and naming nothing is not the same as asking for
    // every name, and a zero limit asks for no rows at all.
    #expect(try await store.items(matching: IndexQuery(nameContains: "")).isEmpty)
    #expect(try await store.items(matching: IndexQuery(limit: 0)).isEmpty)
  }

  @Test
  func answersEveryShapeOfSearchFromAnIndex() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }

    // Search runs on a background utility's budget, so the shape of the plan
    // is part of the contract rather than an implementation detail. A name
    // search cannot seek — no index answers “contains” — but it can be made to
    // scan the narrow index that covers every column it reads instead of the
    // table, and a subtree bound can seek outright. Spelling either as a bare
    // `LIKE` would quietly give both back.
    let searches = [
      IndexQuery(nameContains: "budget"),
      IndexQuery(subtree: try DropboxPath(validating: "/Docs").normalized),
      IndexQuery(
        nameContains: "budget",
        subtree: try DropboxPath(validating: "/Docs").normalized
      )
    ]
    for search in searches {
      let plan = try await store.queryPlan(for: search)
      // Sorting the matches is allowed to want a temporary B-tree; reading
      // every row of the table to find them is not.
      let bareTableScan = "SCAN \(IndexEntryRecord.databaseTableName)"
      #expect(!plan.contains(bareTableScan), "\(plan)")
      #expect(plan.contains { $0.contains("USING INDEX") }, "\(plan)")
    }
  }
}

extension SyncIndexStore {
  /// How SQLite says it would answer a query, one line of
  /// `EXPLAIN QUERY PLAN` per element, for the statement the query really
  /// compiles to rather than an approximation of it.
  fileprivate func queryPlan(for query: IndexQuery) async throws -> [String] {
    let compiled = CompiledIndexQuery(query)
    return try await read { db in
      try String.fetchAll(
        db,
        sql: "EXPLAIN QUERY PLAN \(compiled.sql)",
        arguments: compiled.arguments,
        adapter: ColumnMapping(["": "detail"])
      )
    }
  }
}
