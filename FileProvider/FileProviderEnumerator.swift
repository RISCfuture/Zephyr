// FileProvider vends no Sendable annotations, so this import has to be
// `@preconcurrency` to build under Swift 6. That suppresses concurrency
// checking across it, and `@unsafe` owns the data-race risk the suppression
// carries — only an audited SDK removes it.
@unsafe @preconcurrency import FileProvider
import Foundation
import libZephyr
import os

/// Encodes enumeration page tokens as 8-byte little-endian index watermarks,
/// and sync anchors as change positions: a little-endian generation, followed
/// by a little-endian count of its changes already delivered when the
/// position lies partway through it.
enum GenerationToken {
  /// Decodes an integer from exactly 8 little-endian bytes, or `nil`.
  static func integer(from data: Data) -> UInt64? {
    guard data.count == MemoryLayout<UInt64>.size else { return nil }
    return UInt64(
      littleEndian: unsafe data.withUnsafeBytes { unsafe $0.loadUnaligned(as: UInt64.self) }
    )
  }

  /// Encodes an integer as 8 little-endian bytes.
  static func data(for integer: UInt64) -> Data {
    withUnsafeBytes(of: integer.littleEndian) { unsafe Data($0) }
  }

  /// Decodes a page token, treating Apple's initial-page constants and empty
  /// data as the start of the listing.
  static func pageToken(from page: NSFileProviderPage) -> UInt64? {
    guard
      page.rawValue != NSFileProviderPage.initialPageSortedByName as Data,
      page.rawValue != NSFileProviderPage.initialPageSortedByDate as Data
    else { return nil }
    return integer(from: page.rawValue)
  }

  /// Encodes a continuation token as a page, or `nil` when the listing is done.
  static func page(for generation: UInt64?) -> NSFileProviderPage? {
    generation.map { NSFileProviderPage(data(for: $0)) }
  }

  /// Decodes a sync anchor's change position, or `nil` for an unrecognized anchor.
  static func position(from anchor: NSFileProviderSyncAnchor) -> ChangePosition? {
    let generationBytes = anchor.rawValue.prefix(MemoryLayout<UInt64>.size)
    let deliveredBytes = anchor.rawValue.dropFirst(MemoryLayout<UInt64>.size)
    guard let generation = integer(from: Data(generationBytes)) else { return nil }
    if deliveredBytes.isEmpty { return .through(generation) }
    guard let delivered = integer(from: Data(deliveredBytes)) else { return nil }
    return .within(generation, delivered: UInt(delivered))
  }

  /// Encodes a change position as a sync anchor.
  static func syncAnchor(for position: ChangePosition) -> NSFileProviderSyncAnchor {
    switch position {
      case .through(let generation):
        NSFileProviderSyncAnchor(data(for: generation))
      case let .within(generation, delivered):
        NSFileProviderSyncAnchor(data(for: generation) + data(for: UInt64(delivered)))
    }
  }
}

/// The domain-wide change feed; every enumerator answers change and
/// sync-anchor requests from it because the system may ask any of them.
final class DomainChangeFeed: Sendable {
  /// A generation the anchor store can never issue (SQLite's rowids start
  /// at 1), reported when the current anchor cannot be read: the system's
  /// next change request then expires cleanly instead of dropping tracking.
  private static let neverIssuedGeneration: UInt64 = 0

  private let adapterBox: AdapterBox
  private let capturedGeneration = OSAllocatedUnfairLock<UInt64?>(initialState: nil)

  init(adapterBox: AdapterBox) {
    self.adapterBox = adapterBox
  }

  /**
   Records the current anchor before an item enumeration reads the index, and
   reports that generation as the sync anchor afterwards. Changes applied
   while the enumeration pages through the index are then re-delivered by the
   next change request instead of slipping between the pages and the anchor.
   */
  func captureAnchorForEnumerationStart() async {
    let generation =
      (try? await adapterBox.adapter().currentAnchor())
      ?? Self.neverIssuedGeneration
    capturedGeneration.withLock { $0 = generation }
  }

  /// Reports the index changes recorded after the observer's anchor.
  func enumerateChanges(
    for observer: any NSFileProviderChangeObserver,
    from anchor: NSFileProviderSyncAnchor
  ) {
    guard let position = GenerationToken.position(from: anchor) else {
      observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
      return
    }
    Task {
      do {
        let batch = try await adapterBox.adapter().changes(from: position)
        if !batch.updated.isEmpty { observer.didUpdate(batch.updated) }
        if !batch.removed.isEmpty { observer.didDeleteItems(withIdentifiers: batch.removed) }
        observer.finishEnumeratingChanges(
          upTo: GenerationToken.syncAnchor(for: batch.position),
          moreComing: batch.moreComing
        )
      } catch {
        ZephyrLog.provider.error(
          "Change enumeration failed: \(String(describing: error), privacy: .private)"
        )
        observer.finishEnumeratingWithError(mapToFileProviderError(error))
      }
    }
  }

  /// Reports the generation captured at enumeration start, or the index's
  /// current generation when no enumeration ran through this feed.
  func currentSyncAnchor(completionHandler: @escaping @Sendable (NSFileProviderSyncAnchor?) -> Void)
  {
    if let captured = capturedGeneration.withLock({ $0 }) {
      completionHandler(GenerationToken.syncAnchor(for: .through(captured)))
      return
    }
    Task {
      let generation =
        (try? await adapterBox.adapter().currentAnchor())
        ?? Self.neverIssuedGeneration
      completionHandler(GenerationToken.syncAnchor(for: .through(generation)))
    }
  }
}

/// Enumerates the working set — the items the system keeps fresh — paged by
/// index generation.
final class WorkingSetEnumerator: NSObject, NSFileProviderEnumerator {
  private let adapterBox: AdapterBox
  private let changeFeed: DomainChangeFeed

  init(adapterBox: AdapterBox) {
    self.adapterBox = adapterBox
    changeFeed = DomainChangeFeed(adapterBox: adapterBox)
  }

  func invalidate() {}

  func enumerateItems(
    for observer: any NSFileProviderEnumerationObserver,
    startingAt page: NSFileProviderPage
  ) {
    let token = GenerationToken.pageToken(from: page)
    Task { [adapterBox, changeFeed] in
      do {
        if token == nil {
          await changeFeed.captureAnchorForEnumerationStart()
        }
        // A page can be all skipped items: the working set is a sparse
        // subset of the index, and paging follows the index's order.
        let domainPage = try await adapterBox.adapter().domainItems(after: token)
        if !domainPage.items.isEmpty { observer.didEnumerate(domainPage.items) }
        observer.finishEnumerating(upTo: GenerationToken.page(for: domainPage.nextToken))
      } catch {
        ZephyrLog.provider.error(
          "Working-set enumeration failed: \(String(describing: error), privacy: .private)"
        )
        observer.finishEnumeratingWithError(mapToFileProviderError(error))
      }
    }
  }

  func enumerateChanges(
    for observer: any NSFileProviderChangeObserver,
    from anchor: NSFileProviderSyncAnchor
  ) {
    changeFeed.enumerateChanges(for: observer, from: anchor)
  }

  func currentSyncAnchor(completionHandler: @escaping @Sendable (NSFileProviderSyncAnchor?) -> Void)
  {
    changeFeed.currentSyncAnchor(completionHandler: completionHandler)
  }
}

/// Enumerates the direct children of one container, paged by index row.
final class ContainerEnumerator: NSObject, NSFileProviderEnumerator {
  private let container: NSFileProviderItemIdentifier
  private let adapterBox: AdapterBox
  private let changeFeed: DomainChangeFeed

  init(container: NSFileProviderItemIdentifier, adapterBox: AdapterBox) {
    self.container = container
    self.adapterBox = adapterBox
    changeFeed = DomainChangeFeed(adapterBox: adapterBox)
  }

  func invalidate() {}

  func enumerateItems(
    for observer: any NSFileProviderEnumerationObserver,
    startingAt page: NSFileProviderPage
  ) {
    let token = GenerationToken.pageToken(from: page)
    Task { [adapterBox, container, changeFeed] in
      do {
        if token == nil {
          await changeFeed.captureAnchorForEnumerationStart()
        }
        let childPage = try await adapterBox.adapter().children(of: container, after: token)
        if !childPage.items.isEmpty { observer.didEnumerate(childPage.items) }
        observer.finishEnumerating(upTo: GenerationToken.page(for: childPage.nextToken))
      } catch {
        ZephyrLog.provider.error(
          """
          Container enumeration failed for \(container.rawValue, privacy: .private(mask: .hash)): \
          \(String(describing: error), privacy: .private)
          """
        )
        observer.finishEnumeratingWithError(mapToFileProviderError(error))
      }
    }
  }

  func enumerateChanges(
    for observer: any NSFileProviderChangeObserver,
    from anchor: NSFileProviderSyncAnchor
  ) {
    changeFeed.enumerateChanges(for: observer, from: anchor)
  }

  func currentSyncAnchor(completionHandler: @escaping @Sendable (NSFileProviderSyncAnchor?) -> Void)
  {
    changeFeed.currentSyncAnchor(completionHandler: completionHandler)
  }
}

/**
 Keeps the domain's adapter told which items the system holds on disk, so the
 adapter can narrow the working set to the items the system needs kept fresh.

 The materialized set reverses the usual direction: the system announces that
 it changed and the extension reads it back. Reads are deferred and coalesced,
 because the announcement arrives once per item as a folder fills.
 */
actor MaterializedSetTracker {
  /// How long announcements are allowed to pile up before the set is read.
  private static let settlingDelay = Duration.seconds(2)

  private let domain: NSFileProviderDomain
  private let adapterBox: AdapterBox
  private var read: Task<Void, Never>?

  init(domain: NSFileProviderDomain, adapterBox: AdapterBox) {
    self.domain = domain
    self.adapterBox = adapterBox
  }

  /// Schedules a read of the materialized set, joining one already pending.
  func scheduleRead() {
    guard read == nil else { return }
    read = Task {
      try? await Task.sleep(for: Self.settlingDelay)
      await self.recordMaterializedItems()
      self.read = nil
    }
  }

  private func recordMaterializedItems() async {
    guard let manager = NSFileProviderManager(for: domain) else { return }
    do {
      let identifiers = try await MaterializedSetReader(
        enumerator: manager.enumeratorForMaterializedItems()
      ).identifiers()
      try await adapterBox.adapter().recordMaterializedItems(identifiers)
      ZephyrLog.provider.debug(
        "The system holds \(identifiers.count, privacy: .public) materialized items"
      )
    } catch {
      ZephyrLog.provider.error(
        "Reading the materialized set failed: \(String(describing: error), privacy: .private)"
      )
    }
  }
}

/**
 Drives the system's materialized-set enumerator to completion and reports the
 identifiers of every item it holds on disk.

 The enumerator and its observer come from a pre-concurrency Objective-C
 protocol whose callbacks arrive on the system's own queues; every piece of
 mutable state here is held behind the lock, which is what makes the
 unchecked conformance safe.
 */
final class MaterializedSetReader: NSObject, NSFileProviderEnumerationObserver, @unchecked Sendable
{
  /// The page the materialized set starts from: its listing has no sort
  /// order for the usual initial-page constants to choose between.
  private static var firstPage: NSFileProviderPage { NSFileProviderPage(Data()) }

  /// How long the system gets to finish before the read gives up. A read that
  /// never calls back would otherwise hold the tracker's slot for the life of
  /// the extension and no later announcement would be acted on.
  private static var readTimeout: Duration { .seconds(15) }

  private let enumerator: any NSFileProviderEnumerator
  private let state = OSAllocatedUnfairLock(initialState: State())

  init(enumerator: any NSFileProviderEnumerator) {
    self.enumerator = enumerator
    super.init()
  }

  /// Every materialized item's identifier, in one pass over the enumerator.
  func identifiers() async throws -> [NSFileProviderItemIdentifier] {
    try await withCheckedThrowingContinuation { continuation in
      state.withLock { $0.continuation = continuation }
      abandonReadAfterTimeout()
      enumerator.enumerateItems(for: self, startingAt: Self.firstPage)
    }
  }

  func didEnumerate(_ items: [any NSFileProviderItemProtocol]) {
    let identifiers = items.map(\.itemIdentifier)
    state.withLock { $0.identifiers.formUnion(identifiers) }
  }

  func finishEnumerating(upTo nextPage: NSFileProviderPage?) {
    guard let nextPage else {
      finish(with: .success(Array(state.withLock { $0.identifiers })))
      return
    }
    enumerator.enumerateItems(for: self, startingAt: nextPage)
  }

  func finishEnumeratingWithError(_ error: any Error) {
    finish(with: .failure(error))
  }

  private func abandonReadAfterTimeout() {
    Task { [weak self] in
      try? await Task.sleep(for: Self.readTimeout)
      self?.finish(with: .failure(MaterializedSetUnread()))
    }
  }

  /// Resumes the read, once. A second call — the timeout arriving after the
  /// enumeration finished, or the reverse — finds no continuation and does
  /// nothing.
  private func finish(with result: Result<[NSFileProviderItemIdentifier], any Error>) {
    let continuation = state.withLock { locked in
      defer { locked.continuation = nil }
      return locked.continuation
    }
    continuation?.resume(with: result)
  }

  private struct State {
    var identifiers: Set<NSFileProviderItemIdentifier> = []
    var continuation: CheckedContinuation<[NSFileProviderItemIdentifier], any Error>?
  }
}

/// The materialized set couldn't be read. It never reaches the user: the
/// adapter keeps whatever set it was last told about, and enumerates the whole
/// index until it is told a new one.
private struct MaterializedSetUnread: Error {}
