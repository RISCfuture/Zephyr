import Foundation
import os

/// Re-resolves an account's path root, answering whether it moved.
public typealias PathRootRefresh = @Sendable () async throws -> Bool

/**
 Keeps the sync index mirroring the account's remote state: runs the resumable
 initial recursive listing, applies delta pages, and watches the change feed.

 Cursor resets recover automatically by rebuilding the index — an improvement
 over Maestral, which required a manual rebuild — and so does an account
 whose path root moved between a personal Dropbox and a team space.

 All of it is work nobody is waiting on, so it paces itself to what the Mac
 can afford — see ``BulkWorkPressure``. Pacing is only ever a pause between
 pages: an index that stopped halfway would leave Finder showing a Dropbox
 with files missing from it, and nothing on screen to say why.
 */
public actor RemoteIndexer {
  /// Settle delay after a longpoll fires, letting share/unshare churn finish.
  private static let postLongpollSettleDelay: Duration = .seconds(2)
  /// Extra pause on top of a server-requested longpoll backoff (Maestral's pad).
  private static let serverBackoffPad: Duration = .seconds(5)

  private let client: DropboxClient
  private let store: SyncIndexStore
  private let refreshPathRoot: PathRootRefresh?

  /**
   Creates an indexer over one account's client and index.

   - Parameters:
     - client: The client carrying the account's path root, so listings cover the
       namespace the account actually syncs.
     - store: The index this indexer brings up to date.
     - refreshPathRoot: Re-resolves the account's path root when Dropbox
       rejects the one being sent, which happens when the member joins or
       leaves a team. Without it such a rejection is fatal, because no
       listing can succeed against a namespace that no longer exists.
   */
  public init(
    client: DropboxClient,
    store: SyncIndexStore,
    refreshPathRoot: PathRootRefresh? = nil
  ) {
    self.client = client
    self.store = store
    self.refreshPathRoot = refreshPathRoot
  }

  /**
   Brings the index to a consistent baseline: runs or resumes the initial
   recursive listing, or applies any pending changes when already indexed.
   */
  public func catchUp() async throws {
    ZephyrLog.engine.debug("Bringing the index up to date")
    if try await store.didFinishInitialIndex() {
      _ = try await applyPendingChanges()
      return
    }
    try await runInitialIndex()
  }

  /// Applies all pending remote changes, returning how many entries arrived.
  public func applyPendingChanges() async throws -> UInt {
    guard let cursor = try await store.currentCursor() else {
      try await runInitialIndex()
      return 0
    }
    do {
      return try await drainChanges(from: cursor)
    } catch {
      try await rebuild(after: error)
      return 0
    }
  }

  /**
   Watches the change feed indefinitely, applying changes as they arrive and
   reporting each applied batch.
   */
  public func watch(
    onChanges: @escaping @Sendable ([ItemMetadata]) async -> Void
  ) async throws {
    try await catchUp()
    while true {
      guard let cursor = try await store.currentCursor() else {
        try await runInitialIndex()
        continue
      }
      let result: LongpollResult
      do {
        result = try await client.waitForChanges(after: cursor)
      } catch {
        try await rebuild(after: error)
        continue
      }
      let pressure = BulkWorkPressure.current
      if let backoff = result.backoff {
        // What the server asked for is the floor; pressure only ever adds.
        try await ContinuousClock().sleep(for: backoff + Self.serverBackoffPad)
      }
      guard result.changes else {
        // A poll that heard nothing goes straight back to waiting, which on a
        // Mac with something to conserve is the cheapest thing to slow down.
        try await pressure.pauseBetweenUnits()
        continue
      }
      ZephyrLog.engine.info("Longpoll reported remote changes")
      try await ContinuousClock().sleep(for: pressure.stretching(Self.postLongpollSettleDelay))
      do {
        _ = try await drainChanges(from: cursor, onChanges: onChanges)
      } catch {
        try await rebuild(after: error)
      }
    }
  }

  /// Drops the index and re-runs the initial listing.
  public func rebuildIndex() async throws {
    ZephyrLog.engine.warning("Rebuilding the sync index")
    try await store.resetSyncState()
    try await runInitialIndex()
  }

  // MARK: Internals

  /**
   Rebuilds the index when a failure invalidated the sync state, and rethrows
   every other failure.

   Both invalidations leave the stored cursor addressing state Dropbox will
   not continue from: a reset cursor outright, and a moved path root because
   a cursor belongs to the namespace that issued it.
   */
  private func rebuild(after error: any Error) async throws {
    switch error as? EngineFailure {
      case .cursorReset:
        try await rebuildIndex()
      case .pathRootChanged:
        try await adoptNewPathRoot()
        try await rebuildIndex()
      default:
        throw error
    }
  }

  /// Re-resolves the account's path root, leaving the rejection to the caller
  /// when there is no way to re-resolve it or the root did not actually move
  /// — an account that cannot say where its files are is wedged, and saying
  /// so beats rebuilding the index in a loop.
  private func adoptNewPathRoot() async throws {
    guard let refreshPathRoot, try await refreshPathRoot() else {
      throw EngineFailure.pathRootChanged(newRoot: nil)
    }
  }

  private func runInitialIndex() async throws {
    do {
      try await performInitialListing()
    } catch EngineFailure.cursorReset {
      // The resume cursor died mid-listing; start over once from scratch.
      ZephyrLog.engine.warning("Cursor reset during initial listing; restarting")
      try await store.resetSyncState()
      try await performInitialListing()
    }
    try await store.markInitialIndexComplete()
    ZephyrLog.engine.info("Initial index complete")
  }

  private func performInitialListing() async throws {
    let signposter = ZephyrLog.signposter
    let listing = signposter.beginInterval("Initial listing", id: signposter.makeSignpostID())
    var pages = 0, entries = 0
    defer {
      signposter.endInterval(
        "Initial listing",
        listing,
        "pages: \(pages, privacy: .public), entries: \(entries, privacy: .public)"
      )
    }
    var page: ListFolderPage
    if let cursor = try await store.currentCursor() {
      // Resume an interrupted initial listing from its last committed page.
      page = try await fetchingPage("Fetch listing page") {
        try await client.listFolderContinue(from: cursor)
      }
    } else {
      page = try await fetchingPage("Fetch listing page") {
        try await client.listFolder(.root, recursive: true)
      }
    }
    while true {
      try await applyListingPage(page)
      pages += 1
      entries += page.entries.count
      ZephyrLog.engine.debug("Indexed a listing page of \(page.entries.count) entries")
      guard page.hasMore else { break }
      try await pauseBetweenBulkUnits()
      page = try await fetchingPage("Fetch listing page") {
        try await client.listFolderContinue(from: page.cursor)
      }
    }
  }

  /**
   Fetches one page, marking what the request itself cost.

   The wait between two pages is neither the apply nor the deliberate pause,
   so without an interval of its own it is the one part of a listing a trace
   cannot account for — and it is the part a slow or throttled server owns.
   */
  private func fetchingPage(
    _ name: StaticString,
    _ fetch: () async throws -> ListFolderPage
  ) async rethrows -> ListFolderPage {
    let signposter = ZephyrLog.signposter
    let state = signposter.beginInterval(name, id: signposter.makeSignpostID())
    defer { signposter.endInterval(name, state) }
    return try await fetch()
  }

  /**
   Pauses between units of bulk work, marking what the pause cost and what
   asked for it.

   The pressure is read once and the interval opened only when something is
   actually asking for restraint, so the common case of an unencumbered Mac
   adds no interval to the trace rather than a run of empty ones.
   */
  private func pauseBetweenBulkUnits() async throws {
    let pressure = BulkWorkPressure.current
    guard pressure > .none else { return }
    let signposter = ZephyrLog.signposter
    let state = signposter.beginInterval(
      "Bulk work pause",
      id: signposter.makeSignpostID(),
      "pressure: \(pressure.signpostName, privacy: .public)"
    )
    defer { signposter.endInterval("Bulk work pause", state) }
    try await pressure.pauseBetweenUnits()
  }

  private func drainChanges(
    from cursor: DeltaCursor,
    onChanges: (@Sendable ([ItemMetadata]) async -> Void)? = nil
  ) async throws -> UInt {
    var cursor = cursor
    var totalEntries: UInt = 0
    while true {
      let page = try await fetchingPage("Fetch delta page") {
        try await client.listFolderContinue(from: cursor)
      }
      try await applyChangePage(page)
      totalEntries += UInt(page.entries.count)
      if !page.entries.isEmpty {
        await onChanges?(page.entries)
      }
      cursor = page.cursor
      guard page.hasMore else { break }
      try await pauseBetweenBulkUnits()
    }
    ZephyrLog.engine.info("Applied \(totalEntries) change entries")
    return totalEntries
  }

  /**
   Applies a page of the initial recursive listing, advancing the cursor
   without recording a sync anchor.

   Nothing can be enumerating against an anchor a listing has not finished
   producing, and one generation per page would record a change row for every
   item in the account only to prune it moments later.
   */
  private func applyListingPage(_ page: ListFolderPage) async throws {
    let signposter = ZephyrLog.signposter
    let state = signposter.beginInterval(
      "Listing page",
      id: signposter.makeSignpostID(),
      "entries: \(page.entries.count, privacy: .public)"
    )
    defer { signposter.endInterval("Listing page", state) }
    let interpretation = try await interpretation(of: page)
    try await store.applyDeltaPage(
      interpretation.mutations,
      history: interpretation.history,
      advancingCursorTo: page.cursor
    )
  }

  /**
   Applies a page of the change feed, recording the sync anchor and the item
   changes the page produced.

   The File Provider replays those recordings the next time it asks for
   changes since an anchor. Without them it would find no anchor newer than
   its own, refetch from that anchor's cursor — which this page has already
   advanced past — and diff the page against an index that already holds it:
   the deletions it carried would resolve to nothing and would never reach
   Finder.
   */
  private func applyChangePage(_ page: ListFolderPage) async throws {
    let signposter = ZephyrLog.signposter
    let state = signposter.beginInterval(
      "Delta page",
      id: signposter.makeSignpostID(),
      "entries: \(page.entries.count, privacy: .public)"
    )
    defer { signposter.endInterval("Delta page", state) }
    let interpretation = try await interpretation(of: page)
    _ = try await store.applyDeltaPageRecordingAnchor(
      interpretation.mutations,
      history: interpretation.history,
      advancingCursorTo: page.cursor
    )
  }

  private func interpretation(
    of page: ListFolderPage
  ) async throws -> DeltaInterpreter.Interpretation {
    let signposter = ZephyrLog.signposter
    let state = signposter.beginInterval(
      "Interpret page",
      id: signposter.makeSignpostID(),
      "entries: \(page.entries.count, privacy: .public)"
    )
    defer { signposter.endInterval("Interpret page", state) }
    var known = Set<DropboxFileIdentifier>()
    for entry in page.entries {
      let id: DropboxFileIdentifier? =
        switch entry {
          case .file(let file): file.id
          case .folder(let folder): folder.id
          case .deleted: nil
        }
      if let id, try await store.entry(forID: id) != nil {
        known.insert(id)
      }
    }
    return DeltaInterpreter.interpret(entries: page.entries) { known.contains($0) }
  }
}
