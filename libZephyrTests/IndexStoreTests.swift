import Foundation
import GRDB
import Testing

@testable import libZephyr

@Suite
struct IndexStoreTests {
  @Test
  func appliesPageAtomicallyAndAdvancesCursor() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }

    let record = try fileRecord(id: "id:aaa1", path: "/Docs/report.txt")
    try await store.applyDeltaPage(
      [.upsert(record)],
      history: [],
      advancingCursorTo: try cursor("c1")
    )

    let fetched = try #require(try await store.entry(forPath: record.pathNormalized))
    #expect(fetched.dbxID == record.dbxID)
    #expect(try await store.currentCursor()?.rawValue == "c1")
    let counts = try await store.counts()
    #expect(counts.files == 1 && counts.folders == 0)

    try await store.applyDeltaPage([], history: [], advancingCursorTo: try cursor("c2"))
    #expect(try await store.currentCursor()?.rawValue == "c2")
  }

  @Test
  func refusesAnIndexMigratedByANewerBuild() throws {
    let (_, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("index.sqlite")

    // Stand in for a newer Zephyr having migrated this index: a migration this
    // build's migrator has never heard of, recorded against the same database.
    var laterMigrator = DatabaseMigrator()
    laterMigrator.registerMigration("from-a-later-build") { db in
      try db.create(table: "something_new") { $0.primaryKey("id", .text) }
    }
    let pool = try DatabasePool(path: url.path)
    try laterMigrator.migrate(pool)

    #expect {
      _ = try SyncIndexStore(url: url)
    } throws: { error in
      guard case IndexStoreFailure.schemaFromNewerBuild = error else { return false }
      return true
    }
  }

  @Test
  func updatesPathOnMoveAndBumpsMetaGeneration() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }

    let original = try fileRecord(id: "id:move1", path: "/a/file.txt")
    try await store.applyDeltaPage(
      [.upsert(original)],
      history: [],
      advancingCursorTo: try cursor("c1")
    )
    let moved = try fileRecord(id: "id:move1", path: "/b/file.txt")
    try await store.applyDeltaPage(
      [.upsert(moved)],
      history: [],
      advancingCursorTo: try cursor("c2")
    )

    let fetched = try #require(try await store.entry(forID: moved.dbxID))
    #expect(fetched.pathNormalized.rawValue == "/b/file.txt")
    #expect(fetched.metaGeneration == 1)
    #expect(try await store.entry(forPath: original.pathNormalized) == nil)
  }

  @Test
  func replacingAnItemAtAPathEvictsTheOldRow() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }

    let old = try fileRecord(id: "id:old1", path: "/shared/name.txt")
    let new = try fileRecord(id: "id:new1", path: "/shared/name.txt")
    try await store.applyDeltaPage(
      [.upsert(old)],
      history: [],
      advancingCursorTo: try cursor("c1")
    )
    try await store.applyDeltaPage(
      [.upsert(new)],
      history: [],
      advancingCursorTo: try cursor("c2")
    )

    #expect(try await store.entry(forID: old.dbxID) == nil)
    #expect(try await store.entry(forPath: new.pathNormalized)?.dbxID == new.dbxID)
  }

  @Test
  func deleteSubtreeRemovesDescendantsButNotSimilarSiblings() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }

    let inside = try fileRecord(id: "id:in1", path: "/foo/inner.txt")
    let deeper = try fileRecord(id: "id:in2", path: "/foo/sub/deep.txt")
    let sibling = try fileRecord(id: "id:sib1", path: "/foobar/other.txt")
    try await store.applyDeltaPage(
      [.upsert(inside), .upsert(deeper), .upsert(sibling)],
      history: [],
      advancingCursorTo: try cursor("c1")
    )

    try await store.applyDeltaPage(
      [.deleteSubtree(try NormalizedDropboxPath(validating: "/foo"))],
      history: [],
      advancingCursorTo: try cursor("c2")
    )

    #expect(try await store.entry(forID: inside.dbxID) == nil)
    #expect(try await store.entry(forID: deeper.dbxID) == nil)
    #expect(try await store.entry(forID: sibling.dbxID) != nil)
  }

  @Test
  func replacingAFolderWithAFileRemovesTheWholeSubtree() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let subtree = ["id:docs1", "id:file1", "id:sub01", "id:deep1"]
    try await store.applyDeltaPage(
      [
        .upsert(try folderRecord(id: "id:docs1", path: "/Docs")),
        .upsert(try fileRecord(id: "id:file1", path: "/Docs/a.txt")),
        .upsert(try folderRecord(id: "id:sub01", path: "/Docs/Sub")),
        .upsert(try fileRecord(id: "id:deep1", path: "/Docs/Sub/deep.txt"))
      ],
      history: [],
      advancingCursorTo: try cursor("c1")
    )

    let applied = try await store.applyDeltaPageRecordingAnchor(
      [.upsert(try fileRecord(id: "id:file9", path: "/Docs"))],
      history: [],
      advancingCursorTo: try cursor("c2")
    )

    // Children left behind would keep enumerating, parented under a file.
    #expect(Set(applied.removedIDs.map(\.rawValue)) == Set(subtree))
    for id in subtree {
      #expect(try await store.entry(forID: try DropboxFileIdentifier(validating: id)) == nil)
    }
    let docs = try DropboxPath(validating: "/Docs").normalized
    #expect(try await store.children(of: docs).isEmpty)
    #expect(try await store.entry(forPath: docs)?.dbxID.rawValue == "id:file9")
  }

  @Test
  func aFolderHeldOpenByAnIgnoredChildRenamesAsideWhenAFileTakesItsPath() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await store.applyDeltaPage(
      [
        .upsert(try folderRecord(id: "id:docs1", path: "/Docs")),
        .upsert(try fileRecord(id: "id:keep1", path: "/Docs/keep.txt")),
        .upsert(try fileRecord(id: "id:lose1", path: "/Docs/lose.txt"))
      ],
      history: [],
      advancingCursorTo: try cursor("c1")
    )
    _ = try await store.setIgnoredState(
      true,
      forID: try DropboxFileIdentifier(validating: "id:keep1")
    )

    // The folder outlives its own tombstone to keep the ignored file
    // reachable, and a file then lands on the path it still holds.
    let applied = try await store.applyDeltaPageRecordingAnchor(
      [
        .deleteSubtree(try DropboxPath(validating: "/Docs").normalized),
        .upsert(try fileRecord(id: "id:file9", path: "/Docs"))
      ],
      history: [],
      advancingCursorTo: try cursor("c2")
    )

    #expect(Set(applied.removedIDs.map(\.rawValue)) == ["id:lose1"])
    #expect(Set(applied.updatedIDs.map(\.rawValue)) == ["id:file9", "id:docs1"])
    let folder = try #require(
      try await store.entry(forID: try DropboxFileIdentifier(validating: "id:docs1"))
    )
    #expect(folder.pathNormalized.rawValue == "/docs (ignored)")
    let kept = try #require(
      try await store.entry(forID: try DropboxFileIdentifier(validating: "id:keep1"))
    )
    #expect(kept.pathNormalized.rawValue == "/docs (ignored)/keep.txt")
    #expect(
      try await store.entry(forPath: try DropboxPath(validating: "/Docs").normalized)?
        .dbxID.rawValue == "id:file9"
    )
  }

  @Test
  func deleteSubtreeHandlesLikeWildcardsInPaths() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }

    let child = try fileRecord(id: "id:u1", path: "/my_docs/inner.txt")
    let lookalike = try fileRecord(id: "id:u2", path: "/myxdocs/other.txt")
    try await store.applyDeltaPage(
      [.upsert(child), .upsert(lookalike)],
      history: [],
      advancingCursorTo: try cursor("c1")
    )

    try await store.applyDeltaPage(
      [.deleteSubtree(try NormalizedDropboxPath(validating: "/my_docs"))],
      history: [],
      advancingCursorTo: try cursor("c2")
    )

    // The `_` must match literally: the real child dies, the lookalike survives.
    #expect(try await store.entry(forID: child.dbxID) == nil)
    #expect(try await store.entry(forID: lookalike.dbxID) != nil)
  }

  @Test
  func readOnlyStoreRefusesWrites() async throws {
    let (writable, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await writable.applyDeltaPage([], history: [], advancingCursorTo: try cursor("c1"))

    let readOnly = try SyncIndexStore(
      url: directory.appendingPathComponent("index.sqlite"),
      mode: .readOnly
    )
    await #expect(throws: IndexStoreFailure.self) {
      try await readOnly.applyDeltaPage([], history: [], advancingCursorTo: try cursor("c2"))
    }
    #expect(try await readOnly.currentCursor()?.rawValue == "c1")
  }

  @Test
  func resetSyncStateClearsEverything() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await store.applyDeltaPage(
      [.upsert(try fileRecord(id: "id:x1", path: "/x.txt"))],
      history: [],
      advancingCursorTo: try cursor("c1")
    )
    try await store.markInitialIndexComplete()
    _ = try await store.recordAnchor(cursor: try cursor("c1"))

    try await store.resetSyncState()

    #expect(try await store.currentCursor() == nil)
    #expect(try await store.didFinishInitialIndex() == false)
    // A surviving anchor would resurrect a cursor the reset invalidated.
    #expect(try await store.latestAnchor() == nil)
    let counts = try await store.counts()
    #expect(counts.files == 0)
  }

  @Test
  func resetSyncStateKeepsIgnoredItemsAndEveryItemsLocalAttributes() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await store.applyDeltaPage(
      [
        .upsert(try fileRecord(id: "id:skip1", path: "/skipped.txt")),
        .upsert(try fileRecord(id: "id:tag01", path: "/tagged.txt"))
      ],
      history: [],
      advancingCursorTo: try cursor("c1")
    )
    let skippedID = try DropboxFileIdentifier(validating: "id:skip1")
    let taggedID = try DropboxFileIdentifier(validating: "id:tag01")
    _ = try await store.updateLocalAttributes(
      forID: skippedID,
      tagData: .set(Data([1, 2, 3])),
      favoriteRank: .set(7)
    )
    _ = try await store.setIgnoredState(true, forID: skippedID)
    _ = try await store.updateLocalAttributes(forID: taggedID, tagData: .set(Data([4])))

    try await store.resetSyncState()

    // Ignoring deleted the remote copy, so no re-listing could bring the
    // row back: it has to survive the rebuild outright.
    let skipped = try #require(try await store.entry(forID: skippedID))
    #expect(skipped.ignored)
    #expect(skipped.tagData == Data([1, 2, 3]))
    #expect(skipped.favoriteRank == 7)
    #expect(
      skipped.xattrs?[DropboxIgnoreMarker.syncableXattrName] == DropboxIgnoreMarker.markedValue
    )

    // A synced item's tags wait for the re-listing to return the item.
    #expect(try await store.entry(forID: taggedID) == nil)
    try await store.applyDeltaPage(
      [.upsert(try fileRecord(id: "id:tag01", path: "/tagged.txt"))],
      history: [],
      advancingCursorTo: try cursor("c2")
    )
    #expect(try await store.entry(forID: taggedID)?.tagData == Data([4]))
  }

  // MARK: Sync errors

  @Test
  func aPathLeavingTheIndexTakesItsSyncErrorWithIt() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await store.applyDeltaPage(
      [
        .upsert(try fileRecord(id: "id:mv001", path: "/moving.txt")),
        .upsert(try fileRecord(id: "id:rm001", path: "/going.txt"))
      ],
      history: [],
      advancingCursorTo: try cursor("c1")
    )
    for path in ["/moving.txt", "/going.txt"] {
      try await store.recordSyncError(try syncError(path: path, title: "Couldn’t sync."))
    }

    try await store.applyDeltaPage(
      [
        .upsert(try fileRecord(id: "id:mv001", path: "/moved.txt")),
        .deleteSubtree(try NormalizedDropboxPath(validating: "/going.txt"))
      ],
      history: [],
      advancingCursorTo: try cursor("c2")
    )

    // `sync_error` is keyed on the path alone; one stranded at a path the
    // index no longer holds is one nothing would ever clear.
    #expect(try await store.syncErrors().isEmpty)
  }

  @Test
  func pathStatusAnswersForItemsFoldersAndUnknownPaths() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await store.applyDeltaPage(
      [
        .upsert(try folderRecord(id: "id:docs1", path: "/Docs")),
        .upsert(try fileRecord(id: "id:fail1", path: "/Docs/broken.txt")),
        .upsert(try fileRecord(id: "id:skip1", path: "/Docs/skipped.txt"))
      ],
      history: [],
      advancingCursorTo: try cursor("c1")
    )
    _ = try await store.setIgnoredState(
      true,
      forID: try DropboxFileIdentifier(validating: "id:skip1")
    )
    try await store.recordSyncError(
      try syncError(
        path: "/Docs/broken.txt",
        title: "Couldn’t upload the file.",
        detail: "The account is out of space."
      )
    )

    let docs = try DropboxPath(validating: "/Docs").normalized
    let broken = try DropboxPath(validating: "/Docs/broken.txt").normalized
    guard case .failed(let failure) = try await store.status(ofPath: docs) else {
      Issue.record("A folder answers for its subtree")
      return
    }
    #expect(failure.detail == "The account is out of space.")
    #expect(try await store.status(ofPath: broken) == .failed(failure))
    #expect(
      try await store.status(ofPath: try DropboxPath(validating: "/Docs/skipped.txt").normalized)
        == .ignored
    )
    #expect(
      try await store.status(ofPath: try DropboxPath(validating: "/Docs/gone.txt").normalized)
        == .unknown
    )

    try await store.clearSyncError(forPath: broken)
    #expect(try await store.status(ofPath: docs) == .synced)
    #expect(try await store.status(ofPath: broken) == .synced)
  }

  @Test
  func baseRevisionLookupIsKeyedToTheItemAsWellAsItsContent() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let hash = try ContentHash(validating: String(repeating: "ab", count: 32))
    let mine = try DropboxFileIdentifier(validating: "id:mine1")
    let copy = try DropboxFileIdentifier(validating: "id:copy1")
    try await store.applyDeltaPage(
      [],
      history: [
        try historyEvent(
          id: "id:mine1",
          path: "/mine.txt",
          revision: "015d1a1f3f2e5c0000000012a7651",
          hash: hash
        ),
        // A byte-identical file elsewhere, recorded later: keyed on the
        // hash alone, its revision would become the other item's base.
        try historyEvent(
          id: "id:copy1",
          path: "/copy.txt",
          revision: "015d1a1f3f2e5c0000000012a7652",
          hash: hash
        )
      ],
      advancingCursorTo: try cursor("c1")
    )

    #expect(
      try await store.revision(forContentHash: hash, ofID: mine)?.rawValue
        == "015d1a1f3f2e5c0000000012a7651"
    )
    #expect(
      try await store.revision(forContentHash: hash, ofID: copy)?.rawValue
        == "015d1a1f3f2e5c0000000012a7652"
    )
    #expect(
      try await store.revision(
        forContentHash: hash,
        ofID: try DropboxFileIdentifier(validating: "id:none1")
      ) == nil
    )
  }

  // MARK: Ignored items

  @Test
  func settingIgnoredOnAFolderPropagatesToTheSubtree() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await store.applyDeltaPage(
      [
        .upsert(try folderRecord(id: "id:docs1", path: "/Docs")),
        .upsert(try fileRecord(id: "id:file1", path: "/Docs/a.txt")),
        .upsert(try folderRecord(id: "id:sub01", path: "/Docs/Sub")),
        .upsert(try fileRecord(id: "id:deep1", path: "/Docs/Sub/deep.txt")),
        .upsert(try fileRecord(id: "id:else1", path: "/elsewhere.txt"))
      ],
      history: [],
      advancingCursorTo: try cursor("c1")
    )
    let docsID = try DropboxFileIdentifier(validating: "id:docs1")

    let flagged = try #require(try await store.setIgnoredState(true, forID: docsID))
    #expect(
      Set(flagged.affectedIDs.map(\.rawValue))
        == ["id:docs1", "id:file1", "id:sub01", "id:deep1"]
    )
    #expect(
      flagged.record.xattrs?[DropboxIgnoreMarker.syncableXattrName]
        == DropboxIgnoreMarker.markedValue
    )
    let deep = try #require(
      try await store.entry(forID: try DropboxFileIdentifier(validating: "id:deep1"))
    )
    #expect(deep.ignored)
    // The marker attribute belongs to the folder the user flagged, not
    // every descendant.
    #expect(deep.xattrs == nil)
    #expect(
      try await store.entry(forID: try DropboxFileIdentifier(validating: "id:else1"))?
        .ignored == false
    )
    #expect(
      try await store.ignoredEntries().map(\.pathNormalized.rawValue)
        == ["/docs", "/docs/a.txt", "/docs/sub", "/docs/sub/deep.txt"]
    )

    let cleared = try #require(try await store.setIgnoredState(false, forID: docsID))
    #expect(cleared.record.xattrs == nil)
    #expect(try await store.entry(forID: deep.dbxID)?.ignored == false)
  }

  @Test
  func tombstonesSpareIgnoredItemsAndTheirAncestorFolders() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await store.applyDeltaPage(
      [
        .upsert(try folderRecord(id: "id:docs1", path: "/Docs")),
        .upsert(try folderRecord(id: "id:sub01", path: "/Docs/Sub")),
        .upsert(try fileRecord(id: "id:keep1", path: "/Docs/Sub/keep.txt")),
        .upsert(try fileRecord(id: "id:lose1", path: "/Docs/lose.txt"))
      ],
      history: [],
      advancingCursorTo: try cursor("c1")
    )
    _ = try await store.setIgnoredState(
      true,
      forID: try DropboxFileIdentifier(validating: "id:keep1")
    )

    let applied = try await store.applyDeltaPageRecordingAnchor(
      [.deleteSubtree(try DropboxPath(validating: "/Docs").normalized)],
      history: [],
      advancingCursorTo: try cursor("c2")
    )

    #expect(Set(applied.removedIDs.map(\.rawValue)) == ["id:lose1"])
    #expect(try await store.entry(forID: try DropboxFileIdentifier(validating: "id:keep1")) != nil)
    #expect(try await store.entry(forID: try DropboxFileIdentifier(validating: "id:sub01")) != nil)
    #expect(try await store.entry(forID: try DropboxFileIdentifier(validating: "id:docs1")) != nil)
    #expect(try await store.entry(forID: try DropboxFileIdentifier(validating: "id:lose1")) == nil)
  }

  @Test
  func remoteChangesToIgnoredItemsAreSuppressedAndEvicteesRenameAside() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let originalHash = String(repeating: "ab", count: 32)
    try await store.applyDeltaPage(
      [.upsert(try fileRecord(id: "id:mine1", path: "/notes.txt", hash: originalHash))],
      history: [],
      advancingCursorTo: try cursor("c1")
    )
    let mineID = try DropboxFileIdentifier(validating: "id:mine1")
    _ = try await store.setIgnoredState(true, forID: mineID)

    // A remote change to the ignored item itself must not apply.
    try await store.applyDeltaPage(
      [
        .upsert(
          try fileRecord(
            id: "id:mine1",
            path: "/notes.txt",
            revision: "015d1a1f3f2e5c0000000012a9999",
            hash: String(repeating: "cd", count: 32)
          )
        )
      ],
      history: [],
      advancingCursorTo: try cursor("c2")
    )
    #expect(try await store.entry(forID: mineID)?.contentHash?.rawValue == originalHash)

    // A different item landing on the ignored item's path renames the
    // local copy aside instead of evicting it.
    let applied = try await store.applyDeltaPageRecordingAnchor(
      [
        .upsert(
          try fileRecord(
            id: "id:new01",
            path: "/notes.txt",
            hash: String(repeating: "ef", count: 32)
          )
        )
      ],
      history: [],
      advancingCursorTo: try cursor("c3")
    )
    let mine = try #require(try await store.entry(forID: mineID))
    #expect(mine.name == "notes (ignored).txt")
    #expect(mine.pathNormalized.rawValue == "/notes (ignored).txt")
    #expect(mine.ignored)
    #expect(
      try await store.entry(forID: try DropboxFileIdentifier(validating: "id:new01"))?
        .pathNormalized.rawValue == "/notes.txt"
    )
    #expect(Set(applied.updatedIDs.map(\.rawValue)) == ["id:new01", "id:mine1"])
    #expect(applied.removedIDs.isEmpty)
  }

  @Test
  func anIndexPredatingTheEngineErrorTableStillReportsItsStatus() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    // Only a read-write open migrates, so the app and the command line can
    // meet an index whose tables are not all there yet.
    try await store.write { db in try db.drop(table: "engine_error") }

    #expect(try await store.engineError() == nil)
    // Clearing must not try to write a table that is not there.
    try await store.clearEngineError()
  }

  @Test
  func aCancelledReadStaysACancellation() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }

    // SwiftUI cancels a `.task` when its view goes away, which is routine:
    // the menu bar panel closes mid-read every time someone dismisses it.
    // Giving up on a read is not the index being unavailable.
    let reading = Task { try await store.counts() }
    reading.cancel()

    await #expect(throws: CancellationError.self) { try await reading.value }
  }
}

@Suite
struct DeltaInterpreterTests {
  private func decode<Value: Decodable>(_ type: Value.Type, _ json: String) throws -> Value {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(type, from: Data(json.utf8))
  }

  @Test
  func classifiesEntriesAndBridgesTombstones() throws {
    let entries = try decode(
      [ItemMetadata].self,
      """
      [
        {".tag": "folder", "id": "id:fold1", "name": "Docs",
         "path_lower": "/docs", "path_display": "/Docs"},
        {".tag": "file", "id": "id:file1", "name": "a.txt",
         "path_lower": "/docs/a.txt", "path_display": "/Docs/a.txt",
         "client_modified": "2026-01-02T03:04:05Z", "server_modified": "2026-01-02T03:04:06Z",
         "rev": "015d1a1f3f2e5c0", "size": 11,
         "content_hash": "\(String(repeating: "cd", count: 32))"},
        {".tag": "deleted", "name": "gone", "path_lower": "/gone", "path_display": "/Gone"}
      ]
      """
    )

    let known = try DropboxFileIdentifier(validating: "id:file1")
    let interpretation = DeltaInterpreter.interpret(entries: entries) { $0 == known }

    #expect(interpretation.mutations.count == 3)
    guard case .upsert(let folder) = interpretation.mutations[0],
      case .upsert(let file) = interpretation.mutations[1],
      case .deleteSubtree(let deletedPath) = interpretation.mutations[2]
    else {
      Issue.record("Unexpected mutation shapes")
      return
    }
    #expect(folder.itemType == .folder)
    #expect(file.itemType == .file)
    #expect(file.parentPathNormalized.rawValue == "/docs")
    #expect(deletedPath.rawValue == "/gone")

    // The known file records as modified; the new folder as added; the tombstone as removed.
    #expect(interpretation.history.count == 3)
    #expect(interpretation.history[0].changeType == .added)
    #expect(interpretation.history[1].changeType == .modified)
    #expect(interpretation.history[2].changeType == .removed)
  }

  @Test
  func cachedAccountNamesOmitTheUnknownAndTheStale() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }

    let known = try AccountIdentifier(validating: "dbid:known")
    let forgotten = try AccountIdentifier(validating: "dbid:forgotten")
    let stranger = try AccountIdentifier(validating: "dbid:stranger")
    try await store.cacheAccountNames([known: "Franz Ferdinand", forgotten: "Someone Else"])
    // Age the second entry past the point where Dropbox is asked again.
    try await store.write { db in
      try db.execute(
        sql: "UPDATE account_name SET fetched_at = ? WHERE account_id = ?",
        arguments: [Date(timeIntervalSince1970: 0), forgotten.rawValue]
      )
    }

    let names = try await store.cachedAccountNames(for: [known, forgotten, stranger])
    #expect(names == [known: "Franz Ferdinand"])
  }

  @Test
  func attributesADownwardChangeToTheAccountThatMadeIt() throws {
    let entries = try decode(
      [ItemMetadata].self,
      """
      [{".tag": "file", "id": "id:shared1", "name": "notes.txt",
        "path_lower": "/notes.txt", "path_display": "/notes.txt",
        "client_modified": "2026-01-02T03:04:05Z", "server_modified": "2026-01-02T03:04:06Z",
        "rev": "015d1a1f3f2e5c0", "size": 1,
        "sharing_info": {"read_only": false, "parent_shared_folder_id": "84528192421",
                         "modified_by": "dbid:AAH4f99T0taONIb"},
        "content_hash": "\(String(repeating: "ef", count: 32))"}]
      """
    )
    let interpretation = DeltaInterpreter.interpret(entries: entries) { _ in false }
    #expect(interpretation.history.first?.modifiedBy?.rawValue == "dbid:AAH4f99T0taONIb")
  }

  @Test
  func skipsEntriesWithoutPaths() throws {
    let entries = try decode(
      [ItemMetadata].self,
      """
      [{".tag": "file", "id": "id:orphan", "name": "x.txt",
        "client_modified": "2026-01-02T03:04:05Z", "server_modified": "2026-01-02T03:04:06Z",
        "rev": "015d1a1f3f2e5c0", "size": 1,
        "content_hash": "\(String(repeating: "ef", count: 32))"}]
      """
    )
    let interpretation = DeltaInterpreter.interpret(entries: entries) { _ in false }
    #expect(interpretation.mutations.isEmpty)
    #expect(interpretation.history.isEmpty)
  }

  @Test
  func symlinkFilesRecordAsSymlinks() throws {
    let entries = try decode(
      [ItemMetadata].self,
      """
      [{".tag": "file", "id": "id:link1", "name": "link",
        "path_lower": "/link", "path_display": "/link",
        "client_modified": "2026-01-02T03:04:05Z", "server_modified": "2026-01-02T03:04:06Z",
        "rev": "015d1a1f3f2e5c0", "size": 0,
        "symlink_info": {"target": "../real.txt"},
        "content_hash": "\(String(repeating: "01", count: 32))"}]
      """
    )
    let interpretation = DeltaInterpreter.interpret(entries: entries) { _ in false }
    guard case .upsert(let record) = try #require(interpretation.mutations.first) else {
      Issue.record("Expected an upsert")
      return
    }
    #expect(record.itemType == .symlink)
    #expect(record.symlinkTarget == "../real.txt")
  }

  @Test
  func findsItemsByTheirOwnNameRatherThanTheirPath() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }

    try await store.applyDeltaPage(
      [
        .upsert(try folderRecord(id: "id:f1", path: "/Budget")),
        .upsert(try fileRecord(id: "id:a1", path: "/Budget/notes.txt")),
        .upsert(try fileRecord(id: "id:a2", path: "/Docs/budget-2026.numbers"))
      ],
      history: [],
      advancingCursorTo: try cursor("c1")
    )

    // The folder matches by its own name; the file beneath it does not, even
    // though the folder's name is part of its path.
    let found = try await store.items(named: "budget")
    #expect(
      found.map(\.pathNormalized.rawValue) == ["/budget", "/docs/budget-2026.numbers"]
    )
  }

  @Test
  func matchesNamesWithoutRegardToCaseOrUnicodeForm() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }

    // The same name written with a combining accent rather than a composed
    // one: two different strings that name one file.
    let decomposed = "Re\u{0301}sume\u{0301}.pdf"
    try await store.applyDeltaPage(
      [.upsert(try fileRecord(id: "id:r1", path: "/Docs/\(decomposed)"))],
      history: [],
      advancingCursorTo: try cursor("c1")
    )

    #expect(try await store.items(named: "résumé").count == 1)
    #expect(try await store.items(named: "RÉSUMÉ").count == 1)
    // An accent is part of the name, not decoration on it — the same answer
    // Dropbox gives.
    #expect(try await store.items(named: "resume").isEmpty)
  }

  @Test
  func treatsWildcardCharactersInASearchLiterally() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }

    try await store.applyDeltaPage(
      [
        .upsert(try fileRecord(id: "id:w1", path: "/Sales/50%_off.pdf")),
        .upsert(try fileRecord(id: "id:w2", path: "/Sales/504_off.pdf"))
      ],
      history: [],
      advancingCursorTo: try cursor("c1")
    )

    // Unescaped, "%_" would match both: `%` any run, `_` any character.
    let found = try await store.items(named: "50%_off")
    #expect(found.map(\.name) == ["50%_off.pdf"])
  }

  @Test
  func leavesExcludedItemsOutOfSearchAndStopsAtTheLimit() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }

    let notes = try (1...5).map { try fileRecord(id: "id:n\($0)", path: "/Notes/note-\($0).txt") }
    try await store.applyDeltaPage(
      notes.map { .upsert($0) },
      history: [],
      advancingCursorTo: try cursor("c1")
    )
    _ = try await store.setIgnoredState(true, forID: try DropboxFileIdentifier(validating: "id:n1"))

    #expect(try await store.items(named: "note").count == 4)
    #expect(try await store.items(named: "note", limit: 2).count == 2)
    #expect(try await store.items(named: "").isEmpty)
  }

  @Test
  func readsAnAccountsSyncStatusFromTheIndex() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }

    try await store.applyDeltaPage(
      [
        .upsert(try folderRecord(id: "id:s1", path: "/Docs")),
        .upsert(try fileRecord(id: "id:s2", path: "/Docs/a.txt"))
      ],
      history: [],
      advancingCursorTo: try cursor("c1")
    )

    let indexing = try await SyncStatus(reading: store)
    #expect(indexing.indexState == .indexing)
    #expect(indexing.files == 1 && indexing.folders == 1)
    #expect(indexing.syncIssueCount == 0)
    #expect(indexing.accountFailure == nil)

    try await store.markInitialIndexComplete()
    try await store.recordSyncError(try syncError(path: "/Docs/a.txt", title: "Conflict"))
    try await store.recordEngineError(EngineErrorRecord(title: "Stopped", detail: nil))

    let complete = try await SyncStatus(reading: store)
    #expect(complete.indexState == .complete)
    #expect(complete.syncIssueCount == 1)
    #expect(complete.accountFailure?.title == "Stopped")
  }
}
