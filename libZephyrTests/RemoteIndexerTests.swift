import Foundation
import Testing

@testable import libZephyr

@Suite
struct RemoteIndexerTests {
  private static let cursorResetJSON = """
    {"error_summary": "reset/...", "error": {".tag": "reset"}}
    """

  private static func page(
    files: [(id: String, path: String)],
    deletions: [String] = [],
    cursor: String,
    hasMore: Bool
  ) -> String {
    let entries =
      files.map { file in
        """
        {".tag": "file", "id": "\(file.id)", "name": \
        "\(URL(filePath: file.path).lastPathComponent)",
         "path_lower": "\(file.path.lowercased())", "path_display": "\(file.path)",
         "client_modified": "2026-01-02T03:04:05Z", "server_modified": "2026-01-02T03:04:06Z",
         "rev": "015d1a1f3f2e5c0", "size": 5,
         "content_hash": "\(String(repeating: "cd", count: 32))"}
        """
      }
      + deletions.map { path in
        """
        {".tag": "deleted", "name": "\(URL(filePath: path).lastPathComponent)",
         "path_lower": "\(path.lowercased())", "path_display": "\(path)"}
        """
      }
    return """
      {"entries": [\(entries.joined(separator: ","))],
       "cursor": "\(cursor)", "has_more": \(hasMore)}
      """
  }

  private static func routeNames(of transport: MockTransport) async -> [String] {
    await transport.requests.compactMap { $0.url?.lastPathComponent }
  }

  private static func requestBodies(of transport: MockTransport) async -> [String] {
    await transport.requests.compactMap { request in
      request.httpBody.flatMap { String(bytes: $0, encoding: .utf8) }
    }
  }

  private func makeIndexer(store: SyncIndexStore) async -> (MockTransport, RemoteIndexer) {
    let transport = MockTransport()
    let client = await makeLinkedClient(transport: transport)
    return (transport, RemoteIndexer(client: client, store: store))
  }

  @Test
  func `resumes an interrupted initial listing from its committed cursor`() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    // A cursor without the completion marker is an initial listing that died
    // partway through.
    try await store.applyDeltaPage(
      [.upsert(try fileRecord(id: "id:filea1", path: "/a.txt"))],
      history: [],
      advancingCursorTo: try cursor("page-1")
    )
    let (transport, indexer) = await makeIndexer(store: store)
    await transport.enqueueJSON(
      Self.page(files: [(id: "id:fileb1", path: "/b.txt")], cursor: "page-2", hasMore: false)
    )

    try await indexer.catchUp()

    // One request, to continue — the listing did not start over from the root.
    #expect(await Self.routeNames(of: transport) == ["continue"])
    #expect(try #require(await Self.requestBodies(of: transport).first).contains("page-1"))
    #expect(try await store.didFinishInitialIndex())
    #expect(try await store.currentCursor()?.rawValue == "page-2")
    #expect(try await store.entry(forID: try DropboxFileIdentifier(validating: "id:filea1")) != nil)
    #expect(try await store.entry(forID: try DropboxFileIdentifier(validating: "id:fileb1")) != nil)
  }

  @Test
  func `cursor reset during the initial listing restarts it from the root`() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await store.applyDeltaPage(
      [.upsert(try fileRecord(id: "id:stale1", path: "/stale.txt"))],
      history: [],
      advancingCursorTo: try cursor("dead-cursor")
    )
    let (transport, indexer) = await makeIndexer(store: store)
    await transport.enqueueJSON(Self.cursorResetJSON, status: 409)
    await transport.enqueueJSON(
      Self.page(files: [(id: "id:fileb1", path: "/b.txt")], cursor: "page-2", hasMore: false)
    )

    try await indexer.catchUp()

    // The dead resume cursor is dropped and the listing restarts at the root.
    #expect(await Self.routeNames(of: transport) == ["continue", "list_folder"])
    let rootListing = try #require(await Self.requestBodies(of: transport).last)
    #expect(rootListing.contains(#""recursive":true"#))
    #expect(try await store.didFinishInitialIndex())
    #expect(try await store.currentCursor()?.rawValue == "page-2")
    // Entries indexed under the dead cursor went with it.
    #expect(try await store.entry(forID: try DropboxFileIdentifier(validating: "id:stale1")) == nil)
    #expect(try await store.entry(forID: try DropboxFileIdentifier(validating: "id:fileb1")) != nil)
  }

  @Test
  func `applying pending changes without a cursor runs the initial listing`() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (transport, indexer) = await makeIndexer(store: store)
    await transport.enqueueJSON(
      Self.page(files: [(id: "id:filea1", path: "/a.txt")], cursor: "page-1", hasMore: false)
    )

    let entries = try await indexer.applyPendingChanges()

    // An initial listing is not a delta, so nothing counts as a pending change.
    #expect(entries == 0)
    #expect(await Self.routeNames(of: transport) == ["list_folder"])
    #expect(try await store.didFinishInitialIndex())
    #expect(try await store.entry(forID: try DropboxFileIdentifier(validating: "id:filea1")) != nil)
    // Nor does it record anchors: nothing can enumerate against a generation
    // of a listing that has not finished.
    #expect(try await store.latestAnchor()?.generation == nil)
  }

  @Test
  func `draining changes records an anchor the provider can replay deletions from`() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await store.applyDeltaPage(
      [.upsert(try fileRecord(id: "id:filea1", path: "/a.txt"))],
      history: [],
      advancingCursorTo: try cursor("page-1")
    )
    try await store.markInitialIndexComplete()
    // The generation the File Provider is enumerating against.
    let enumerated = try await store.recordAnchor(cursor: try cursor("page-1"))
    let (transport, indexer) = await makeIndexer(store: store)
    await transport.enqueueJSON(
      Self.page(files: [], deletions: ["/a.txt"], cursor: "page-2", hasMore: false)
    )

    _ = try await indexer.applyPendingChanges()

    // The removal is recorded against the applying generation, so the next
    // change request replays it instead of refetching from a cursor this
    // page has already advanced past — where the deletion, already applied,
    // would resolve to nothing and never reach Finder.
    let replay = try #require(try await store.recordedChanges(afterGeneration: enumerated))
    #expect(replay.removedIDs == [try DropboxFileIdentifier(validating: "id:filea1")])
    #expect(try await store.cursor(forAnchorGeneration: replay.generation)?.rawValue == "page-2")
  }

  @Test
  func `drains every delta page and advances the cursor once`() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await store.applyDeltaPage([], history: [], advancingCursorTo: try cursor("page-1"))
    try await store.markInitialIndexComplete()
    let (transport, indexer) = await makeIndexer(store: store)
    await transport.enqueueJSON(
      Self.page(
        files: [(id: "id:filea1", path: "/a.txt"), (id: "id:fileb1", path: "/b.txt")],
        cursor: "page-2",
        hasMore: true
      )
    )
    await transport.enqueueJSON(
      Self.page(files: [(id: "id:filec1", path: "/c.txt")], cursor: "page-3", hasMore: false)
    )

    let entries = try await indexer.applyPendingChanges()

    #expect(entries == 3)
    let bodies = await Self.requestBodies(of: transport)
    try #require(bodies.count == 2)
    // Each page continues from the cursor the page before it returned.
    #expect(bodies[0].contains("page-1"))
    #expect(bodies[1].contains("page-2"))
    #expect(try await store.currentCursor()?.rawValue == "page-3")
    #expect(try await store.entry(forID: try DropboxFileIdentifier(validating: "id:filec1")) != nil)
  }

  @Test
  func `cursor reset while draining rebuilds the index`() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await store.applyDeltaPage(
      [.upsert(try fileRecord(id: "id:stale1", path: "/stale.txt"))],
      history: [],
      advancingCursorTo: try cursor("dead-cursor")
    )
    try await store.markInitialIndexComplete()
    let (transport, indexer) = await makeIndexer(store: store)
    await transport.enqueueJSON(Self.cursorResetJSON, status: 409)
    await transport.enqueueJSON(
      Self.page(files: [(id: "id:fileb1", path: "/b.txt")], cursor: "page-2", hasMore: false)
    )

    let entries = try await indexer.applyPendingChanges()

    #expect(entries == 0)
    #expect(await Self.routeNames(of: transport) == ["continue", "list_folder"])
    #expect(try await store.didFinishInitialIndex())
    #expect(try await store.entry(forID: try DropboxFileIdentifier(validating: "id:stale1")) == nil)
    #expect(try await store.entry(forID: try DropboxFileIdentifier(validating: "id:fileb1")) != nil)
  }
}
