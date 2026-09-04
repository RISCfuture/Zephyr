import FileProvider
import Foundation
import Testing

@testable import libZephyr

@Suite
struct ProviderAdapterTests {
  private static let continuePageJSON = """
    {
      "entries": [
        {".tag": "file", "id": "id:fileb1", "name": "b.txt",
         "path_lower": "/docs/b.txt", "path_display": "/Docs/b.txt",
         "client_modified": "2026-01-02T03:04:05Z", "server_modified": "2026-01-02T03:04:06Z",
         "rev": "015d1a1f3f2e5c0", "size": 5,
         "content_hash": "\(String(repeating: "cd", count: 32))"},
        {".tag": "deleted", "name": "Old", "path_lower": "/old", "path_display": "/Old"}
      ],
      "cursor": "cursor-2",
      "has_more": false
    }
    """

  // MARK: Static fixtures

  private static func uploadedFileJSON(
    id: String,
    name: String,
    pathLower: String,
    pathDisplay: String
  ) -> String {
    """
    {"id": "\(id)", "name": "\(name)",
     "path_lower": "\(pathLower)", "path_display": "\(pathDisplay)",
     "client_modified": "2026-02-01T10:00:00Z", "server_modified": "2026-02-01T10:00:01Z",
     "rev": "015d1a1f3f2e5d0", "size": 5,
     "content_hash": "\(String(repeating: "9a", count: 32))"}
    """
  }

  private static func lastAPIArgument(of transport: MockTransport) async -> String? {
    await transport.requests.last?.value(forHTTPHeaderField: "Dropbox-API-Arg")
  }

  private static func hash(of data: Data) -> ContentHash {
    var hasher = DropboxContentHasher()
    hasher.update(data)
    return hasher.finalize()
  }

  /// A `files/download` reply: the bytes in the body, the revision's
  /// metadata in the header the client reads it from.
  private static func downloadExchange(
    id: String,
    name: String,
    pathLower: String,
    pathDisplay: String,
    rev: String,
    body: Data
  ) -> MockTransport.Exchange {
    let metadata = """
      {"id": "\(id)", "name": "\(name)", "path_lower": "\(pathLower)", "path_display": \
      "\(pathDisplay)", "client_modified": "2026-02-01T10:00:00Z", "server_modified": \
      "2026-02-01T10:00:01Z", "rev": "\(rev)", "size": \(body.count), "content_hash": \
      "\(hash(of: body).rawValue)"}
      """
    return MockTransport.Exchange(headers: ["Dropbox-API-Result": metadata], body: body)
  }

  /// A `files/delete_v2` reply for a file.
  private static func deletedFileJSON(
    id: String,
    name: String,
    pathLower: String,
    pathDisplay: String
  ) -> String {
    """
    {"metadata": {".tag": "file", "id": "\(id)", "name": "\(name)", "path_lower": "\(pathLower)", \
    "path_display": "\(pathDisplay)", "client_modified": "2026-02-01T10:00:00Z", \
    "server_modified": "2026-02-01T10:00:01Z", "rev": "015d1a1f3f2e5d0", "size": 5, \
    "content_hash": "\(String(repeating: "9a", count: 32))"}}
    """
  }

  @Test
  func `changes applies one page and reports updated removed and anchor`() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await store.applyDeltaPage(
      [
        .upsert(try folderRecord(id: "id:docs01", path: "/Docs")),
        .upsert(try fileRecord(id: "id:filea1", path: "/Docs/a.txt")),
        .upsert(try folderRecord(id: "id:oldf01", path: "/Old")),
        .upsert(try fileRecord(id: "id:gonef1", path: "/Old/gone.txt"))
      ],
      history: [],
      advancingCursorTo: try cursor("c1")
    )
    try await store.markInitialIndexComplete()
    let (transport, adapter) = await makeAdapter(store: store, scratchDirectory: directory)

    let initialAnchor = try await adapter.currentAnchor()
    await transport.enqueueJSON(Self.continuePageJSON)
    let batch = try await adapter.changes(fromAnchor: initialAnchor)

    #expect(batch.updated.count == 1)
    let updated = try #require(batch.updated.first)
    #expect(updated.itemIdentifier.rawValue == "id:fileb1")
    #expect(updated.parentItemIdentifier.rawValue == "id:docs01")
    #expect(Set(batch.removed.map(\.rawValue)) == ["id:oldf01", "id:gonef1"])
    #expect(batch.anchor > initialAnchor)
    #expect(batch.moreComing == false)
    #expect(try await store.cursor(forAnchorGeneration: batch.anchor)?.rawValue == "cursor-2")
    #expect(try await store.entry(forID: try DropboxFileIdentifier(validating: "id:gonef1")) == nil)
    #expect(try await store.entry(forID: try DropboxFileIdentifier(validating: "id:fileb1")) != nil)
  }

  @Test
  func `remote move in one page is an update not a removal`() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await store.applyDeltaPage(
      [
        .upsert(try folderRecord(id: "id:docs01", path: "/Docs")),
        .upsert(try fileRecord(id: "id:movef1", path: "/Docs/a.txt")),
        .upsert(try fileRecord(id: "id:evict1", path: "/Docs/c.txt"))
      ],
      history: [],
      advancingCursorTo: try cursor("c1")
    )
    try await store.markInitialIndexComplete()
    let (transport, adapter) = await makeAdapter(store: store, scratchDirectory: directory)
    let initialAnchor = try await adapter.currentAnchor()

    // A move arrives as a tombstone at the old path plus the same id at the
    // new path; a second entry lands on an existing path under a new id.
    await transport.enqueueJSON(
      """
      {
        "entries": [
          {".tag": "deleted", "name": "a.txt",
           "path_lower": "/docs/a.txt", "path_display": "/Docs/a.txt"},
          {".tag": "file", "id": "id:movef1", "name": "renamed.txt",
           "path_lower": "/docs/renamed.txt", "path_display": "/Docs/renamed.txt",
           "client_modified": "2026-01-02T03:04:05Z", "server_modified": "2026-01-02T03:04:06Z",
           "rev": "015d1a1f3f2e5c1", "size": 5,
           "content_hash": "\(String(repeating: "ab", count: 32))"},
          {".tag": "file", "id": "id:newid1", "name": "c.txt",
           "path_lower": "/docs/c.txt", "path_display": "/Docs/c.txt",
           "client_modified": "2026-01-02T03:04:05Z", "server_modified": "2026-01-02T03:04:06Z",
           "rev": "015d1a1f3f2e5c2", "size": 6,
           "content_hash": "\(String(repeating: "ef", count: 32))"}
        ],
        "cursor": "cursor-2",
        "has_more": false
      }
      """
    )
    let batch = try await adapter.changes(fromAnchor: initialAnchor)

    let updatedIDs = Set(batch.updated.map(\.itemIdentifier.rawValue))
    #expect(updatedIDs == ["id:movef1", "id:newid1"])
    #expect(
      batch.updated.first { $0.itemIdentifier.rawValue == "id:movef1" }?.filename == "renamed.txt"
    )
    // The moved id must survive; the id evicted from /Docs/c.txt must not.
    #expect(Set(batch.removed.map(\.rawValue)) == ["id:evict1"])
  }

  @Test
  func `unknown anchor generation throws sync anchor expired`() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (_, adapter) = await makeAdapter(store: store, scratchDirectory: directory)

    let error = await #expect(throws: NSFileProviderError.self) {
      _ = try await adapter.changes(fromAnchor: 99)
    }
    #expect(error?.code == .syncAnchorExpired)
  }

  @Test
  func `fetch contents rejects stale requested version`() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await store.applyDeltaPage(
      [.upsert(try fileRecord(id: "id:filea1", path: "/Docs/a.txt"))],
      history: [],
      advancingCursorTo: try cursor("c1")
    )
    let (_, adapter) = await makeAdapter(store: store, scratchDirectory: directory)

    let error = await #expect(throws: NSFileProviderError.self) {
      _ = try await adapter.fetchContents(
        for: NSFileProviderItemIdentifier("id:filea1"),
        requestedVersion: NSFileProviderItemVersion(
          contentVersion: Data("stale".utf8),
          metadataVersion: Data(count: 8)
        )
      )
    }
    #expect(error?.code == .versionNoLongerAvailable)
  }

  @Test
  func `domain items pages by row ID watermark until exhausted`() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let ids = (1...5).map { "id:f000\($0)" }
    try await store.applyDeltaPage(
      try ids.enumerated().map { .upsert(try fileRecord(id: $1, path: "/f\($0).txt")) },
      history: [],
      advancingCursorTo: try cursor("c1")
    )
    try await store.markInitialIndexComplete()
    let (_, adapter) = await makeAdapter(store: store, scratchDirectory: directory)

    var collected: [String] = []
    var token: UInt64?
    var pages = 0
    repeat {
      let page = try await adapter.domainItems(after: token, limit: 2)
      pages += 1
      collected += page.items.map(\.itemIdentifier.rawValue)
      token = page.nextToken
    } while token != nil

    #expect(pages == 3)
    #expect(collected == ids)
  }

  @Test
  func `the working set narrows to what the system holds once it reports it`() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    var tagged = try fileRecord(id: "id:tagg01", path: "/Deep/tagged.txt")
    tagged.tagData = Data("red".utf8)
    var used = try fileRecord(id: "id:used01", path: "/Deep/used.txt")
    used.lastUsedDate = Date()
    var ignored = try fileRecord(id: "id:ignr01", path: "/Deep/local.txt")
    ignored.ignored = true
    try await store.applyDeltaPage(
      [
        .upsert(try fileRecord(id: "id:root01", path: "/at-root.txt")),
        .upsert(try folderRecord(id: "id:docs01", path: "/Docs")),
        .upsert(try fileRecord(id: "id:filea1", path: "/Docs/a.txt")),
        .upsert(try folderRecord(id: "id:deep01", path: "/Deep")),
        .upsert(try fileRecord(id: "id:fileb1", path: "/Deep/b.txt")),
        .upsert(tagged),
        .upsert(used),
        .upsert(ignored)
      ],
      history: [],
      advancingCursorTo: try cursor("c1")
    )
    try await store.markInitialIndexComplete()
    let (_, adapter) = await makeAdapter(store: store, scratchDirectory: directory)

    // Until the system reports what it holds, the working set is everything.
    let beforeReport = try await workingSetIdentifiers(of: adapter)
    await adapter.recordMaterializedItems([NSFileProviderItemIdentifier("id:docs01")])
    let afterReport = try await workingSetIdentifiers(of: adapter)

    #expect(beforeReport.contains("id:fileb1"))
    // Everything but `/Deep/b.txt`, which is dataless under a folder the
    // system does not hold, carries no tag and exists on Dropbox too. The
    // order is the index's, which is the order the page was applied in.
    #expect(
      afterReport == [
        "id:root01", "id:docs01", "id:filea1", "id:deep01",
        "id:tagg01", "id:used01", "id:ignr01"
      ]
    )
  }

  // MARK: Change replay

  @Test
  func `changes from an older anchor replay recorded pages without server calls`() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await store.applyDeltaPage(
      [
        .upsert(try folderRecord(id: "id:docs01", path: "/Docs")),
        .upsert(try fileRecord(id: "id:filea1", path: "/Docs/a.txt")),
        .upsert(try folderRecord(id: "id:oldf01", path: "/Old"))
      ],
      history: [],
      advancingCursorTo: try cursor("c1")
    )
    try await store.markInitialIndexComplete()
    let (transport, adapter) = await makeAdapter(store: store, scratchDirectory: directory)
    let initialAnchor = try await adapter.currentAnchor()

    await transport.enqueueJSON(Self.continuePageJSON)
    let first = try await adapter.changes(fromAnchor: initialAnchor)
    await transport.enqueueJSON(
      """
      {
        "entries": [
          {".tag": "file", "id": "id:filec1", "name": "c.txt",
           "path_lower": "/docs/c.txt", "path_display": "/Docs/c.txt",
           "client_modified": "2026-01-03T03:04:05Z", "server_modified": "2026-01-03T03:04:06Z",
           "rev": "015d1a1f3f2e5c9", "size": 7,
           "content_hash": "\(String(repeating: "12", count: 32))"}
        ],
        "cursor": "cursor-3",
        "has_more": false
      }
      """
    )
    let second = try await adapter.changes(fromAnchor: first.anchor)

    // Both replays answer from recordings; the empty transport queue traps
    // on any request, so passing proves no server page was consumed.
    let firstReplay = try await adapter.changes(fromAnchor: initialAnchor)
    #expect(
      Set(firstReplay.updated.map(\.itemIdentifier.rawValue))
        == Set(first.updated.map(\.itemIdentifier.rawValue))
    )
    #expect(Set(firstReplay.removed.map(\.rawValue)) == Set(first.removed.map(\.rawValue)))
    #expect(firstReplay.anchor == first.anchor)
    #expect(firstReplay.moreComing == true)

    let secondReplay = try await adapter.changes(fromAnchor: first.anchor)
    #expect(secondReplay.updated.map(\.itemIdentifier.rawValue) == ["id:filec1"])
    #expect(secondReplay.anchor == second.anchor)
    #expect(secondReplay.moreComing == false)
  }

  @Test
  func `change page naming an unknown parent fetches and indexes it`() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await store.applyDeltaPage(
      [.upsert(try fileRecord(id: "id:filea1", path: "/a.txt"))],
      history: [],
      advancingCursorTo: try cursor("c1")
    )
    try await store.markInitialIndexComplete()
    let (transport, adapter) = await makeAdapter(store: store, scratchDirectory: directory)
    let initialAnchor = try await adapter.currentAnchor()

    // The page delivers a file inside /Docs without ever delivering /Docs.
    await transport.enqueueJSON(Self.continuePageJSON)
    await transport.enqueueJSON(
      """
      {".tag": "folder", "id": "id:docs01", "name": "Docs",
       "path_lower": "/docs", "path_display": "/Docs"}
      """
    )
    let batch = try await adapter.changes(fromAnchor: initialAnchor)

    let updated = try #require(batch.updated.first { $0.itemIdentifier.rawValue == "id:fileb1" })
    #expect(updated.parentItemIdentifier.rawValue == "id:docs01")
    #expect(try await store.entry(forID: try DropboxFileIdentifier(validating: "id:docs01")) != nil)
  }

  // MARK: Local writes

  @Test
  func `create file uploads with add and indexes the server result`() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await store.applyDeltaPage(
      [.upsert(try folderRecord(id: "id:docs01", path: "/Docs"))],
      history: [],
      advancingCursorTo: try cursor("c1")
    )
    try await store.markInitialIndexComplete()
    let (transport, adapter) = await makeAdapter(store: store, scratchDirectory: directory)
    let contents = directory.appendingPathComponent("staged.txt")
    try Data("hello".utf8).write(to: contents)
    await transport.enqueueJSON(
      Self.uploadedFileJSON(
        id: "id:newf01",
        name: "new.txt",
        pathLower: "/docs/new.txt",
        pathDisplay: "/Docs/new.txt"
      )
    )

    let item = try await adapter.createFile(
      named: "new.txt",
      in: NSFileProviderItemIdentifier("id:docs01"),
      contents: contents,
      clientModified: Date(timeIntervalSince1970: 1_700_000_000)
    )

    #expect(item.itemIdentifier.rawValue == "id:newf01")
    #expect(item.parentItemIdentifier.rawValue == "id:docs01")
    let argument = try #require(await Self.lastAPIArgument(of: transport))
    #expect(argument.contains(#""add""#))
    #expect(argument.contains(#"\/Docs\/new.txt"#))
    #expect(try await store.entry(forID: try DropboxFileIdentifier(validating: "id:newf01")) != nil)
    let history = try await store.recentHistory()
    #expect(
      history.contains {
        $0.direction == .up && $0.changeType == .added && $0.path.rawValue == "/Docs/new.txt"
      }
    )
  }

  @Test
  func `excluded names are refused wherever one can be created`() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await store.applyDeltaPage(
      [.upsert(try fileRecord(id: "id:filea1", path: "/a.txt"))],
      history: [],
      advancingCursorTo: try cursor("c1")
    )
    try await store.markInitialIndexComplete()
    let (_, adapter) = await makeAdapter(store: store, scratchDirectory: directory)

    // The empty transport queue proves not one of these reached Dropbox.
    for name in [".DS_Store", "~$Budget.xlsx", ".~lock.report.ods", ".localized"] {
      let created = await #expect(throws: NSFileProviderError.self) {
        _ = try await adapter.createFile(
          named: name,
          in: .rootContainer,
          contents: nil,
          clientModified: nil
        )
      }
      #expect(created?.code == .excludedFromSync, "creating a file named \(name)")
      let folder = await #expect(throws: NSFileProviderError.self) {
        _ = try await adapter.createFolder(named: name, in: .rootContainer)
      }
      #expect(folder?.code == .excludedFromSync, "creating a folder named \(name)")
      let renamed = await #expect(throws: NSFileProviderError.self) {
        _ = try await adapter.move(
          NSFileProviderItemIdentifier("id:filea1"),
          toParent: nil,
          renamedTo: name
        )
      }
      #expect(renamed?.code == .excludedFromSync, "renaming to \(name)")
    }
  }

  @Test
  func `a change page never indexes a name the domain must not carry`() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await store.applyDeltaPage(
      [.upsert(try folderRecord(id: "id:docs01", path: "/Docs"))],
      history: [],
      advancingCursorTo: try cursor("c1")
    )
    try await store.markInitialIndexComplete()
    let (transport, adapter) = await makeAdapter(store: store, scratchDirectory: directory)
    let anchor = try await adapter.currentAnchor()
    // Another client's system metadata, and a file inside a folder that is
    // itself excluded — Finder writes its own `.DS_Store`, and a second one
    // arriving through the domain collides with it.
    await transport.enqueueJSON(
      """
      {
        "entries": [
          {".tag": "file", "id": "id:dsstor", "name": ".DS_Store",
           "path_lower": "/docs/.ds_store", "path_display": "/Docs/.DS_Store",
           "client_modified": "2026-01-02T03:04:05Z", "server_modified": "2026-01-02T03:04:06Z",
           "rev": "015d1a1f3f2e5c1", "size": 5,
           "content_hash": "\(String(repeating: "ab", count: 32))"},
          {".tag": "file", "id": "id:cache1", "name": "scratch.bin",
           "path_lower": "/.dropbox.cache/scratch.bin",
           "path_display": "/.dropbox.cache/scratch.bin",
           "client_modified": "2026-01-02T03:04:05Z", "server_modified": "2026-01-02T03:04:06Z",
           "rev": "015d1a1f3f2e5c2", "size": 5,
           "content_hash": "\(String(repeating: "cd", count: 32))"},
          {".tag": "file", "id": "id:fileb1", "name": "b.txt",
           "path_lower": "/docs/b.txt", "path_display": "/Docs/b.txt",
           "client_modified": "2026-01-02T03:04:05Z", "server_modified": "2026-01-02T03:04:06Z",
           "rev": "015d1a1f3f2e5c3", "size": 5,
           "content_hash": "\(String(repeating: "ef", count: 32))"}
        ],
        "cursor": "cursor-2",
        "has_more": false
      }
      """
    )

    let batch = try await adapter.changes(fromAnchor: anchor)

    #expect(batch.updated.map(\.itemIdentifier.rawValue) == ["id:fileb1"])
    for excluded in ["id:dsstor", "id:cache1"] {
      #expect(
        try await store.entry(forID: try DropboxFileIdentifier(validating: excluded)) == nil,
        "\(excluded) must not be indexed"
      )
    }
  }

  @Test
  func `modify contents commits over the revision the base version belonged to`() async throws {
    let indexedRev = "015d1a1f3f2e5c0000000012a7650"
    let indexedHash = String(repeating: "ab", count: 32)
    let olderRev = "015d1a1f3f2e5c0000000012a7000"
    let olderHash = String(repeating: "0f", count: 32)
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await store.applyDeltaPage(
      [
        .upsert(
          try fileRecord(
            id: "id:filea1",
            path: "/a.txt",
            revision: indexedRev,
            hash: indexedHash
          )
        )
      ],
      history: [
        HistoryEventRecord(
          dbxID: try DropboxFileIdentifier(validating: "id:filea1"),
          path: try DropboxPath(validating: "/a.txt"),
          itemType: .file,
          changeType: .modified,
          direction: .down,
          size: 5,
          revision: try FileRevision(validating: olderRev),
          contentHash: try ContentHash(validating: olderHash)
        )
      ],
      advancingCursorTo: try cursor("c1")
    )
    try await store.markInitialIndexComplete()
    let (transport, adapter) = await makeAdapter(store: store, scratchDirectory: directory)
    let contents = directory.appendingPathComponent("edit.txt")
    try Data("edited".utf8).write(to: contents)

    // A base version matching the index commits over the indexed revision.
    await transport.enqueueJSON(
      Self.uploadedFileJSON(
        id: "id:filea1",
        name: "a.txt",
        pathLower: "/a.txt",
        pathDisplay: "/a.txt"
      )
    )
    _ = try await adapter.modifyContents(
      of: NSFileProviderItemIdentifier("id:filea1"),
      baseContentVersion: Data(indexedHash.utf8),
      contents: contents,
      clientModified: nil
    )
    #expect(try #require(await Self.lastAPIArgument(of: transport)).contains(indexedRev))

    // A stale base commits over the revision that content belonged to, so
    // the server generates the conflicted copy.
    await transport.enqueueJSON(
      Self.uploadedFileJSON(
        id: "id:filea1",
        name: "a.txt",
        pathLower: "/a.txt",
        pathDisplay: "/a.txt"
      )
    )
    _ = try await adapter.modifyContents(
      of: NSFileProviderItemIdentifier("id:filea1"),
      baseContentVersion: Data(olderHash.utf8),
      contents: contents,
      clientModified: nil
    )
    #expect(try #require(await Self.lastAPIArgument(of: transport)).contains(olderRev))

    // A base version no revision accounts for predates sync tracking, so the
    // write adds alongside rather than committing over an unrelated revision.
    await transport.enqueueJSON(
      Self.uploadedFileJSON(
        id: "id:filea1",
        name: "a.txt",
        pathLower: "/a.txt",
        pathDisplay: "/a.txt"
      )
    )
    _ = try await adapter.modifyContents(
      of: NSFileProviderItemIdentifier("id:filea1"),
      baseContentVersion: Data("version-from-an-untracked-past".utf8),
      contents: contents,
      clientModified: nil
    )
    let addArgument = try #require(await Self.lastAPIArgument(of: transport))
    #expect(addArgument.contains(#""add""#))
    #expect(!addArgument.contains(indexedRev))
    #expect(!addArgument.contains(olderRev))
  }

  @Test
  func `an autorenamed upload is indexed apart and the caller's item is still answered`()
    async throws
  {
    let indexedRev = "015d1a1f3f2e5c0000000012a7650"
    let indexedHash = String(repeating: "ab", count: 32)
    let olderRev = "015d1a1f3f2e5c0000000012a7000"
    let olderHash = String(repeating: "0f", count: 32)
    let winningRev = "015d1a1f3f2e5c0000000012a9999"
    let winningHash = String(repeating: "7c", count: 32)
    let copyPath = "/a (conflicted copy 2026-02-01).txt"
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await store.applyDeltaPage(
      [
        .upsert(
          try fileRecord(
            id: "id:filea1",
            path: "/a.txt",
            revision: indexedRev,
            hash: indexedHash
          )
        )
      ],
      history: [
        try historyEvent(
          id: "id:filea1",
          path: "/a.txt",
          revision: olderRev,
          hash: try ContentHash(validating: olderHash)
        )
      ],
      advancingCursorTo: try cursor("c1")
    )
    try await store.markInitialIndexComplete()
    let (transport, adapter) = await makeAdapter(store: store, scratchDirectory: directory)
    let contents = directory.appendingPathComponent("edit.txt")
    try Data("edited".utf8).write(to: contents)

    // Committing over a revision another writer moved past makes Dropbox
    // keep both versions, so the upload answers with a different item…
    await transport.enqueueJSON(
      Self.uploadedFileJSON(
        id: "id:copy01",
        name: "a (conflicted copy 2026-02-01).txt",
        pathLower: copyPath,
        pathDisplay: copyPath
      )
    )
    // …and the original is re-read, because the revision that won the path
    // is the one the system must now hold for it.
    await transport.enqueueJSON(
      """
      {".tag": "file", "id": "id:filea1", "name": "a.txt", "path_lower": "/a.txt", "path_display": \
      "/a.txt", "client_modified": "2026-02-01T10:00:00Z", "server_modified": \
      "2026-02-01T10:00:01Z", "rev": "\(winningRev)", "size": 9, "content_hash": "\(winningHash)"}
      """
    )

    let item = try await adapter.modifyContents(
      of: NSFileProviderItemIdentifier("id:filea1"),
      baseContentVersion: Data(olderHash.utf8),
      contents: contents,
      clientModified: nil
    )

    // The contract: modifying item A is answered with item A.
    #expect(item.itemIdentifier.rawValue == "id:filea1")
    #expect(item.filename == "a.txt")
    #expect(item.itemVersion.contentVersion == Data(winningHash.utf8))
    let copy = try #require(
      try await store.entry(forID: try DropboxFileIdentifier(validating: "id:copy01"))
    )
    #expect(copy.pathCased.rawValue == copyPath)
    let original = try #require(
      try await store.entry(forID: try DropboxFileIdentifier(validating: "id:filea1"))
    )
    #expect(original.pathCased.rawValue == "/a.txt")
    #expect(original.revision?.rawValue == winningRev)
    let history = try await store.recentHistory()
    #expect(
      history.contains {
        $0.direction == .up && $0.changeType == .added && $0.path.rawValue == copyPath
      }
    )
  }

  @Test
  func `a failed write records a sync error and the next clean write clears it`() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await store.applyDeltaPage(
      [.upsert(try fileRecord(id: "id:filea1", path: "/a.txt"))],
      history: [],
      advancingCursorTo: try cursor("c1")
    )
    try await store.markInitialIndexComplete()
    let (transport, adapter) = await makeAdapter(store: store, scratchDirectory: directory)
    let contents = directory.appendingPathComponent("edit.txt")
    try Data("edited".utf8).write(to: contents)
    await transport.enqueueJSON(
      """
      {"error_summary": "path/insufficient_space/..",
       "error": {".tag": "path", "path": {".tag": "insufficient_space"}}}
      """,
      status: 409
    )

    do {
      _ = try await adapter.modifyContents(
        of: NSFileProviderItemIdentifier("id:filea1"),
        baseContentVersion: nil,
        contents: contents,
        clientModified: nil
      )
      Issue.record("modifyContents() should have thrown ItemSyncFailure.insufficientSpace")
    } catch ItemSyncFailure.insufficientSpace {
    } catch {
      Issue.record("Expected ItemSyncFailure.insufficientSpace, got \(error)")
    }

    let recorded = try #require(try await store.syncErrors().first)
    #expect(try await store.syncErrors().count == 1)
    #expect(recorded.path.rawValue == "/a.txt")
    #expect(recorded.pathNormalized.rawValue == "/a.txt")
    // The record carries the specific failure, not a generic one.
    #expect(recorded.detail == ItemSyncFailure.insufficientSpace(path: "/a.txt").failureReason)

    await transport.enqueueJSON(
      Self.uploadedFileJSON(
        id: "id:filea1",
        name: "a.txt",
        pathLower: "/a.txt",
        pathDisplay: "/a.txt"
      )
    )
    _ = try await adapter.modifyContents(
      of: NSFileProviderItemIdentifier("id:filea1"),
      baseContentVersion: nil,
      contents: contents,
      clientModified: nil
    )

    #expect(try await store.syncErrors().isEmpty)
  }

  @Test
  func `a revoked token stops the account rather than counting as an item that couldn't sync`()
    async throws
  {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await store.applyDeltaPage(
      [.upsert(try fileRecord(id: "id:filea1", path: "/a.txt"))],
      history: [],
      advancingCursorTo: try cursor("c1")
    )
    try await store.markInitialIndexComplete()
    let (transport, adapter) = await makeAdapter(store: store, scratchDirectory: directory)
    let contents = directory.appendingPathComponent("edit.txt")
    try Data("edited".utf8).write(to: contents)
    await transport.enqueueJSON(
      """
      {"error_summary": "invalid_access_token/..",
       "error": {".tag": "invalid_access_token"}}
      """,
      status: 401
    )

    do {
      _ = try await adapter.modifyContents(
        of: NSFileProviderItemIdentifier("id:filea1"),
        baseContentVersion: nil,
        contents: contents,
        clientModified: nil
      )
      Issue.record("modifyContents() should have thrown AuthenticationFailure.tokenRevoked")
    } catch AuthenticationFailure.tokenRevoked {
    } catch {
      Issue.record("Expected AuthenticationFailure.tokenRevoked, got \(error)")
    }

    // Nothing is wrong with /a.txt, so it must not read as an item that
    // couldn't sync; the account is what stopped.
    #expect(try await store.syncErrors().isEmpty)
    let stopped = try #require(try await store.engineError())
    #expect(stopped.detail == AuthenticationFailure.tokenRevoked.failureReason)

    await transport.enqueueJSON(
      Self.uploadedFileJSON(
        id: "id:filea1",
        name: "a.txt",
        pathLower: "/a.txt",
        pathDisplay: "/a.txt"
      )
    )
    _ = try await adapter.modifyContents(
      of: NSFileProviderItemIdentifier("id:filea1"),
      baseContentVersion: nil,
      contents: contents,
      clientModified: nil
    )

    #expect(try await store.engineError() == nil)
  }

  @Test
  func `moving a folder rewrites the indexed subtree`() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await store.applyDeltaPage(
      [
        .upsert(try folderRecord(id: "id:docs01", path: "/Docs")),
        .upsert(try fileRecord(id: "id:filea1", path: "/Docs/a.txt")),
        .upsert(try folderRecord(id: "id:subf01", path: "/Docs/Sub")),
        .upsert(try fileRecord(id: "id:deepf1", path: "/Docs/Sub/deep.txt"))
      ],
      history: [],
      advancingCursorTo: try cursor("c1")
    )
    try await store.markInitialIndexComplete()
    let (transport, adapter) = await makeAdapter(store: store, scratchDirectory: directory)
    await transport.enqueueJSON(
      """
      {"metadata": {".tag": "folder", "id": "id:docs01", "name": "Archive",
       "path_lower": "/archive", "path_display": "/Archive"}}
      """
    )

    let item = try await adapter.move(
      NSFileProviderItemIdentifier("id:docs01"),
      toParent: nil,
      renamedTo: "Archive"
    )

    #expect(item.filename == "Archive")
    let body = try #require(await transport.requests.last?.httpBody)
    let bodyText = try #require(String(bytes: body, encoding: .utf8))
    #expect(bodyText.contains(#""from_path":"id:docs01""#))
    let deep = try #require(
      try await store.entry(forID: try DropboxFileIdentifier(validating: "id:deepf1"))
    )
    #expect(deep.pathNormalized.rawValue == "/archive/sub/deep.txt")
    #expect(deep.parentPathNormalized.rawValue == "/archive/sub")
    #expect(deep.pathCased.rawValue == "/Archive/Sub/deep.txt")
    let children = try await adapter.children(of: NSFileProviderItemIdentifier("id:docs01"))
    #expect(Set(children.map(\.itemIdentifier.rawValue)) == ["id:filea1", "id:subf01"])
  }

  @Test
  func `delete is revision guarded and a conflict keeps the item`() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await store.applyDeltaPage(
      [.upsert(try fileRecord(id: "id:filea1", path: "/a.txt"))],
      history: [],
      advancingCursorTo: try cursor("c1")
    )
    try await store.markInitialIndexComplete()
    let (transport, adapter) = await makeAdapter(store: store, scratchDirectory: directory)

    // A revision-guard conflict must reject the delete and keep the row.
    await transport.enqueueJSON(
      """
      {"error_summary": "path_lookup/conflict/file/..",
       "error": {".tag": "path_lookup",
                 "path_lookup": {".tag": "conflict", "conflict": {".tag": "file"}}}}
      """,
      status: 409
    )
    await #expect(throws: ItemSyncFailure.self) {
      try await adapter.delete(NSFileProviderItemIdentifier("id:filea1"), recursive: false)
    }
    let id = try DropboxFileIdentifier(validating: "id:filea1")
    #expect(try await store.entry(forID: id) != nil)
    #expect(try await store.syncErrors().map(\.path.rawValue) == ["/a.txt"])

    await transport.enqueueJSON(
      """
      {"metadata": {".tag": "file", "id": "id:filea1", "name": "a.txt", "path_lower": "/a.txt", \
      "path_display": "/a.txt", "client_modified": "2026-02-01T10:00:00Z", "server_modified": \
      "2026-02-01T10:00:01Z", "rev": "015d1a1f3f2e5d0", "size": 5, "content_hash": \
      "\(String(repeating: "9a", count: 32))"}}
      """
    )
    try await adapter.delete(NSFileProviderItemIdentifier("id:filea1"), recursive: false)
    let body = try #require(await transport.requests.last?.httpBody)
    let bodyText = try #require(String(bytes: body, encoding: .utf8))
    #expect(bodyText.contains(#""parent_rev""#))
    #expect(try await store.entry(forID: id) == nil)
    // The delete that succeeded retires the issue the rejected one recorded.
    #expect(try await store.syncErrors().isEmpty)
  }

  @Test
  func `a refused download records a sync error at the item's path`() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await store.applyDeltaPage(
      [.upsert(try fileRecord(id: "id:filea1", path: "/Docs/a.txt"))],
      history: [],
      advancingCursorTo: try cursor("c1")
    )
    try await store.markInitialIndexComplete()
    // Staging gets its own directory: the adapter sweeps that directory clean
    // on first use, and the index lives in this one.
    let (transport, adapter) = await makeAdapter(
      store: store,
      scratchDirectory: directory.appendingPathComponent("staging")
    )
    await transport.enqueueJSON(
      """
      {"error_summary": "path/restricted_content/..",
       "error": {".tag": "path", "path": {".tag": "restricted_content"}}}
      """,
      status: 409
    )

    var thrown: ItemSyncFailure?
    do {
      _ = try await adapter.fetchContents(
        for: NSFileProviderItemIdentifier("id:filea1"),
        requestedVersion: nil
      )
      Issue.record("fetchContents() should have thrown ItemSyncFailure.restrictedContent")
    } catch let failure as ItemSyncFailure {
      thrown = failure
      guard case .restrictedContent(let blamed) = failure else {
        Issue.record("Expected restrictedContent, got \(failure)")
        return
      }
      // The download addressed a revision, but the user only recognizes the file.
      #expect(blamed == "/Docs/a.txt")
    }

    let recorded = try #require(try await store.syncErrors().first)
    #expect(recorded.path.rawValue == "/Docs/a.txt")
    #expect(recorded.pathNormalized.rawValue == "/docs/a.txt")
    #expect(recorded.detail == thrown?.failureReason)
  }

  @Test
  func `local attributes persist echo and survive remote upserts`() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await store.applyDeltaPage(
      [
        .upsert(try folderRecord(id: "id:docs01", path: "/Docs")),
        .upsert(try fileRecord(id: "id:fileb1", path: "/Docs/b.txt"))
      ],
      history: [],
      advancingCursorTo: try cursor("c1")
    )
    try await store.markInitialIndexComplete()
    let (transport, adapter) = await makeAdapter(store: store, scratchDirectory: directory)
    let tag = Data("finder-tags".utf8)

    let tagged = try await adapter.updateLocalAttributes(
      of: NSFileProviderItemIdentifier("id:fileb1"),
      tagData: .set(tag)
    )
    #expect(tagged.tagData == tag)

    // A remote change to the same item must not wipe the system's tags.
    let anchor = try await adapter.currentAnchor()
    await transport.enqueueJSON(Self.continuePageJSON)
    let batch = try await adapter.changes(fromAnchor: anchor)
    let updated = try #require(batch.updated.first { $0.itemIdentifier.rawValue == "id:fileb1" })
    #expect(updated.tagData == tag)
  }

  @Test
  func `create folder adopts the existing folder on conflict`() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (transport, adapter) = await makeAdapter(store: store, scratchDirectory: directory)
    await transport.enqueueJSON(
      """
      {"error_summary": "path/conflict/folder/..",
       "error": {".tag": "path",
                 "path": {".tag": "conflict", "conflict": {".tag": "folder"}}}}
      """,
      status: 409
    )
    await transport.enqueueJSON(
      """
      {".tag": "folder", "id": "id:docs01", "name": "Docs",
       "path_lower": "/docs", "path_display": "/Docs"}
      """
    )

    let item = try await adapter.createFolder(named: "Docs", in: .rootContainer)

    #expect(item.itemIdentifier.rawValue == "id:docs01")
    #expect(try await store.entry(forID: try DropboxFileIdentifier(validating: "id:docs01")) != nil)
  }

  // MARK: Ignored items

  @Test
  func `ignoring a dataless item saves its bytes before deleting the Dropbox copy`() async throws {
    let rev = "015d1a1f3f2e5c0000000012a7650"
    let body = Data("the only copy".utf8)
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await store.applyDeltaPage(
      [
        .upsert(try folderRecord(id: "id:docs01", path: "/Docs")),
        .upsert(
          try fileRecord(
            id: "id:filea1",
            path: "/Docs/a.txt",
            revision: rev,
            hash: Self.hash(of: body).rawValue
          )
        )
      ],
      history: [],
      advancingCursorTo: try cursor("c1")
    )
    try await store.markInitialIndexComplete()
    // Staging gets its own directory: the adapter sweeps that directory
    // clean on first use, and the index lives in this one.
    let (transport, adapter) = await makeAdapter(
      store: store,
      scratchDirectory: directory.appendingPathComponent("staging")
    )
    let initialAnchor = try await adapter.currentAnchor()
    await transport.enqueue(
      Self.downloadExchange(
        id: "id:filea1",
        name: "a.txt",
        pathLower: "/docs/a.txt",
        pathDisplay: "/Docs/a.txt",
        rev: rev,
        body: body
      )
    )
    await transport.enqueueJSON(
      Self.deletedFileJSON(
        id: "id:filea1",
        name: "a.txt",
        pathLower: "/docs/a.txt",
        pathDisplay: "/Docs/a.txt"
      )
    )

    let item = try await adapter.ignore(NSFileProviderItemIdentifier("id:filea1"))

    #expect(item.userInfo?["ignored"] as? Bool == true)
    #expect(item.decorations == [ProviderItem.ignoredDecoration])
    #expect(
      item.extendedAttributes[DropboxIgnoreMarker.syncableXattrName]
        == DropboxIgnoreMarker.markedValue
    )
    // The bytes came down before the copy that held them went away.
    let requests = await transport.requests
    try #require(requests.count == 2)
    #expect(requests[0].url?.absoluteString == "https://content.dropboxapi.com/2/files/download")
    #expect(requests[1].url?.absoluteString.hasSuffix("/files/delete_v2") == true)
    let deleteBody = try #require(requests[1].httpBody)
    let deleteBodyText = try #require(String(bytes: deleteBody, encoding: .utf8))
    #expect(deleteBodyText.contains(#""parent_rev""#))
    let entry = try #require(
      try await store.entry(forID: try DropboxFileIdentifier(validating: "id:filea1"))
    )
    #expect(entry.ignored)

    // Materialization now has to come from the shadow copy — Dropbox no
    // longer holds these bytes — and the empty queue proves it does.
    let (url, _) = try await adapter.fetchContents(
      for: NSFileProviderItemIdentifier("id:filea1"),
      requestedVersion: nil
    )
    #expect(try Data(contentsOf: url) == body)

    // The system learns about the state change through a recorded local
    // generation; the empty transport queue proves no server page runs.
    let batch = try await adapter.changes(fromAnchor: initialAnchor)
    #expect(batch.updated.map(\.itemIdentifier.rawValue) == ["id:filea1"])
    #expect(batch.updated.first?.userInfo?["ignored"] as? Bool == true)
  }

  @Test
  func `a failed download abandons the ignore with the Dropbox copy intact`() async throws {
    let rev = "015d1a1f3f2e5c0000000012a7650"
    let body = Data("first child".utf8)
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await store.applyDeltaPage(
      [
        .upsert(try folderRecord(id: "id:docs01", path: "/Docs")),
        .upsert(
          try fileRecord(
            id: "id:filea1",
            path: "/Docs/a.txt",
            revision: rev,
            hash: Self.hash(of: body).rawValue
          )
        ),
        .upsert(try fileRecord(id: "id:fileb1", path: "/Docs/b.txt", revision: rev))
      ],
      history: [],
      advancingCursorTo: try cursor("c1")
    )
    try await store.markInitialIndexComplete()
    let (transport, adapter) = await makeAdapter(
      store: store,
      scratchDirectory: directory.appendingPathComponent("staging")
    )
    await transport.enqueue(
      Self.downloadExchange(
        id: "id:filea1",
        name: "a.txt",
        pathLower: "/docs/a.txt",
        pathDisplay: "/Docs/a.txt",
        rev: rev,
        body: body
      )
    )
    // The second child is refused, so the subtree is never fully on disk.
    await transport.enqueueJSON(
      """
      {"error_summary": "path/restricted_content/..",
       "error": {".tag": "path", "path": {".tag": "restricted_content"}}}
      """,
      status: 409
    )

    await #expect(throws: ItemSyncFailure.self) {
      _ = try await adapter.ignore(NSFileProviderItemIdentifier("id:docs01"))
    }

    // Two downloads and no delete: the Dropbox copy of the whole subtree stands.
    let requests = await transport.requests
    #expect(requests.count == 2)
    #expect(requests.allSatisfy { $0.url?.absoluteString.contains("/files/delete") == false })
    for id in ["id:docs01", "id:filea1", "id:fileb1"] {
      let entry = try #require(
        try await store.entry(forID: try DropboxFileIdentifier(validating: id))
      )
      #expect(!entry.ignored, "\(id) must still sync")
    }
    let recorded = try #require(try await store.syncErrors().first)
    #expect(recorded.path.rawValue == "/Docs")
  }

  @Test
  func `modify contents while ignored stashes a shadow instead of uploading`() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await store.applyDeltaPage(
      [.upsert(try fileRecord(id: "id:filea1", path: "/a.txt"))],
      history: [],
      advancingCursorTo: try cursor("c1")
    )
    try await store.markInitialIndexComplete()
    let id = try DropboxFileIdentifier(validating: "id:filea1")
    _ = try await store.setIgnoredState(true, forID: id)
    let (_, adapter) = await makeAdapter(store: store, scratchDirectory: directory)
    let contents = directory.appendingPathComponent("edit.txt")
    try Data("edited while ignored".utf8).write(to: contents)

    // The empty transport queue proves nothing was uploaded.
    let item = try await adapter.modifyContents(
      of: NSFileProviderItemIdentifier("id:filea1"),
      baseContentVersion: nil,
      contents: contents,
      clientModified: nil
    )

    let expectedHash = try DropboxContentHasher.hash(contentsOf: contents)
    #expect(item.itemVersion.contentVersion == Data(expectedHash.rawValue.utf8))
    let entry = try #require(try await store.entry(forID: id))
    #expect(entry.contentHash == expectedHash)
    #expect(entry.revision?.rawValue == "015d1a1f3f2e5c0000000012a7650")

    // Materialization serves the shadow copy — no Dropbox revision holds
    // these bytes.
    let (url, _) = try await adapter.fetchContents(
      for: NSFileProviderItemIdentifier("id:filea1"),
      requestedVersion: nil
    )
    #expect(try Data(contentsOf: url) == Data("edited while ignored".utf8))
  }

  @Test
  func `resume sync restores a remotely missing file from its revision`() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await store.applyDeltaPage(
      [.upsert(try fileRecord(id: "id:filea1", path: "/a.txt"))],
      history: [],
      advancingCursorTo: try cursor("c1")
    )
    try await store.markInitialIndexComplete()
    let id = try DropboxFileIdentifier(validating: "id:filea1")
    _ = try await store.setIgnoredState(true, forID: id)
    let (transport, adapter) = await makeAdapter(store: store, scratchDirectory: directory)
    await transport.enqueueJSON(
      """
      {"error_summary": "path/not_found/..",
       "error": {".tag": "path", "path": {".tag": "not_found"}}}
      """,
      status: 409
    )
    await transport.enqueueJSON(
      Self.uploadedFileJSON(
        id: "id:filea1",
        name: "a.txt",
        pathLower: "/a.txt",
        pathDisplay: "/a.txt"
      )
    )

    let item = try await adapter.resumeSync(NSFileProviderItemIdentifier("id:filea1"))

    #expect(item.userInfo?["ignored"] as? Bool == false)
    let restoreRequest = try #require(await transport.requests.last)
    #expect(restoreRequest.url?.path.contains("files/restore") == true)
    let entry = try #require(try await store.entry(forID: id))
    #expect(entry.ignored == false)
    #expect(entry.revision?.rawValue == "015d1a1f3f2e5d0")
  }

  @Test
  func `resume sync uploads contents edited while ignored`() async throws {
    let indexedRev = "015d1a1f3f2e5c0000000012a7650"
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await store.applyDeltaPage(
      [.upsert(try fileRecord(id: "id:filea1", path: "/a.txt", revision: indexedRev))],
      history: [],
      advancingCursorTo: try cursor("c1")
    )
    try await store.markInitialIndexComplete()
    let id = try DropboxFileIdentifier(validating: "id:filea1")
    _ = try await store.setIgnoredState(true, forID: id)
    let (transport, adapter) = await makeAdapter(store: store, scratchDirectory: directory)
    let contents = directory.appendingPathComponent("edit.txt")
    try Data("edited while ignored".utf8).write(to: contents)
    _ = try await adapter.modifyContents(
      of: NSFileProviderItemIdentifier("id:filea1"),
      baseContentVersion: nil,
      contents: contents,
      clientModified: nil
    )

    // The remote copy survived (say, the ignore-time delete was rejected)
    // with the pre-edit hash; resuming must upload the shadow over it.
    await transport.enqueueJSON(
      """
      {".tag": "file", "id": "id:filea1", "name": "a.txt", "path_lower": "/a.txt", "path_display": \
      "/a.txt", "client_modified": "2026-01-01T00:00:00Z", "server_modified": \
      "2026-01-01T00:00:01Z", "rev": "\(indexedRev)", "size": 42, "content_hash": \
      "\(String(repeating: "ab", count: 32))"}
      """
    )
    await transport.enqueueJSON(
      Self.uploadedFileJSON(
        id: "id:filea1",
        name: "a.txt",
        pathLower: "/a.txt",
        pathDisplay: "/a.txt"
      )
    )

    _ = try await adapter.resumeSync(NSFileProviderItemIdentifier("id:filea1"))

    let uploadArgument = try #require(await Self.lastAPIArgument(of: transport))
    #expect(uploadArgument.contains(#""update""#))
    #expect(uploadArgument.contains(indexedRev))
    let entry = try #require(try await store.entry(forID: id))
    #expect(entry.ignored == false)
    #expect(entry.revision?.rawValue == "015d1a1f3f2e5d0")
  }

  // MARK: Fixtures

  /// Every identifier the working set enumerates, across all its pages.
  private func workingSetIdentifiers(of adapter: ProviderAdapter) async throws -> [String] {
    var identifiers: [String] = []
    var token: UInt64?
    repeat {
      let page = try await adapter.domainItems(after: token)
      identifiers += page.items.map(\.itemIdentifier.rawValue)
      token = page.nextToken
    } while token != nil
    return identifiers
  }

  private func makeAdapter(
    store: SyncIndexStore,
    scratchDirectory: URL
  ) async -> (MockTransport, ProviderAdapter) {
    let transport = MockTransport()
    let client = await makeLinkedClient(transport: transport)
    return (
      transport,
      ProviderAdapter(store: store, client: client, scratchDirectory: scratchDirectory)
    )
  }
}
