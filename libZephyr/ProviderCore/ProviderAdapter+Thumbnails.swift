import CoreGraphics
import FileProvider
import Foundation
import os

extension ProviderAdapter {
  /**
   The file extensions Dropbox renders thumbnails for.

   Kept here rather than asked of Dropbox, because asking costs a round trip
   to be told what the filename already said — and a Finder scroll asks about
   every file it passes.
   */
  private static let thumbnailableExtensions: Set<String> = [
    "jpg", "jpeg", "png", "tiff", "tif", "gif", "webp", "ppm", "bmp"
  ]

  /// The largest source Dropbox renders. Anything above it comes back
  /// declined, so sending it spends a round trip on a refusal.
  private static let thumbnailSourceSizeLimit: UInt64 = 20 * 1_024 * 1_024

  /**
   The largest render worth asking for, whatever size the system named.

   The size that arrives is a fixed 2048×2048 ceiling rather than the size
   the icon gets drawn at — list view's 16-pixel icons ask for it too — so
   honoring it literally spends a full-resolution render on every thumbnail.
   This bucket covers Finder's icon sizes through 320 points on a 2× display
   and costs an order of magnitude less; only the largest icon view draws it
   upscaled.
   */
  private static let largestRenderWorthFetching = ThumbnailSize.w640h480

  /**
   Renders thumbnails for as many of `identifiers` as Dropbox can, reporting
   each to `deliver` as it arrives and `nil` for every item there is none for.

   Rendered bytes are not kept anywhere. The system caches a thumbnail per
   item and invalidates it when `NSFileProviderItemVersion.contentVersion`
   changes, which `ProviderAdapter.contentVersion(of:)` derives from the
   file's content hash — the same key a cache here would use. A second cache
   would buy a copy of what the system already holds, in exchange for an
   eviction policy to maintain and derived image content at rest in the app
   group container. So there isn't one.

   - Parameters:
     - identifiers: The items to render, in any order.
     - size: The size the system asked for. Dropbox is asked for the nearest
       bucket at or above it.
     - deliver: Called once per identifier, with the rendered bytes or `nil`.
       Called as each batch lands rather than at the end, so Finder fills in
       while the rest is still on the wire.
   */
  public func thumbnails(
    for identifiers: [NSFileProviderItemIdentifier],
    size: CGSize,
    deliver: @Sendable (NSFileProviderItemIdentifier, Data?) -> Void
  ) async throws {
    var renderable: [RenderableItem] = []
    for identifier in identifiers {
      if let revision = try await renderableRevision(of: identifier) {
        renderable.append(RenderableItem(identifier: identifier, revision: revision))
      } else {
        deliver(identifier, nil)
      }
    }
    guard !renderable.isEmpty else { return }
    let bucket = min(.covering(size), Self.largestRenderWorthFetching)
    ZephyrLog.provider.debug(
      """
      Rendering \(renderable.count, privacy: .public) of \(identifiers.count, privacy: .public) \
      requested thumbnails at \(bucket.rawValue, privacy: .public), asked for \
      \(Int(size.width), privacy: .public)×\(Int(size.height), privacy: .public)
      """
    )
    try await render(renderable, size: bucket, deliver: deliver)
  }

  /**
   The revision to render the item at, or `nil` when there is nothing worth
   asking Dropbox about.

   Every exclusion here is decided from the index alone, so a folder of PDFs
   costs no requests at all.
   */
  private func renderableRevision(
    of identifier: NSFileProviderItemIdentifier
  ) async throws -> FileRevision? {
    guard let id = try? DropboxFileIdentifier(validating: identifier.rawValue),
      let entry = try await store.entry(forID: id),
      entry.itemType == .file,
      let revision = entry.revision,
      Self.thumbnailableExtensions.contains(entry.name.thumbnailExtension),
      entry.size ?? 0 <= Self.thumbnailSourceSizeLimit,
      // An excluded item's local copy is the authoritative one and may have
      // been edited away from anything Dropbox holds, so its revision would
      // render a picture of the wrong file.
      !entry.ignored
    else { return nil }
    return revision
  }

  /**
   Renders in batches of the size Dropbox accepts, delivering each before
   asking for the next.

   Sequential rather than concurrent: a gallery scroll is already a stream of
   batches, and Zephyr is a background utility issuing them. Two in flight
   would halve the wait and double the claim on a rate limit whose refusals
   reach the user as sync failures.

   Items repeated within one request are rendered once. Overlapping requests
   are not coalesced against each other: sharing an in-flight batch means an
   unstructured task nobody's cancellation reaches, and a thumbnail request
   the system has walked away from must stop.
   */
  private func render(
    _ renderable: [RenderableItem],
    size: ThumbnailSize,
    deliver: @Sendable (NSFileProviderItemIdentifier, Data?) -> Void
  ) async throws {
    for batch in renderable.deduplicatedByRevision().chunked(
      into: DropboxClient.thumbnailBatchLimit
    ) {
      try Task.checkCancellation()
      let entries = try await client.thumbnails(
        for: batch.map { .revision($0.revision) },
        size: size
      )
      for (item, entry) in zip(batch, entries) {
        deliver(item.identifier, entry.renderedData)
        for duplicate in item.sharingTheRevision {
          deliver(duplicate, entry.renderedData)
        }
      }
    }
  }

  /// One item worth rendering, and any others in the same request that are
  /// the very same revision and can be answered from its one render.
  fileprivate struct RenderableItem {
    let identifier: NSFileProviderItemIdentifier
    let revision: FileRevision
    var sharingTheRevision: [NSFileProviderItemIdentifier] = []
  }
}

extension ThumbnailEntry {
  /// The rendered bytes, or `nil` where Dropbox rendered nothing.
  fileprivate var renderedData: Data? {
    switch self {
      case .rendered(let data): data
      case .unavailable: nil
    }
  }
}

extension String {
  /// The lowercased extension a thumbnail request is decided on — lowercased
  /// because Dropbox's set is spelled that way and a filename is not.
  ///
  /// A leading dot names a hidden file rather than an extension, so
  /// `.jpg` has none.
  fileprivate var thumbnailExtension: String {
    guard let dot = lastIndex(of: "."), dot != startIndex else { return "" }
    return self[index(after: dot)...].lowercased()
  }
}

extension [ProviderAdapter.RenderableItem] {
  /// One entry per distinct revision, each carrying the other identifiers
  /// that asked for it, so a file listed twice is rendered once.
  fileprivate func deduplicatedByRevision() -> Self {
    var distinct = Self()
    var positions: [FileRevision: Int] = [:]
    for item in self {
      if let position = positions[item.revision] {
        distinct[position].sharingTheRevision.append(item.identifier)
      } else {
        positions[item.revision] = distinct.count
        distinct.append(item)
      }
    }
    return distinct
  }
}

extension Array {
  /// The array in runs of at most `size`, in order.
  fileprivate func chunked(into size: Int) -> [[Element]] {
    stride(from: 0, to: count, by: size).map { start in
      Array(self[start..<Swift.min(start + size, count)])
    }
  }
}
