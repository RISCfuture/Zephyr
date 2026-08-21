@preconcurrency import FileProvider
import Foundation
import libZephyr
import os

// MARK: Thumbnails

/**
 Serves Finder's thumbnails from Dropbox's renders rather than letting it
 fall back to a generic type icon.

 The protocol adopted here is the one declared beside
 `NSFileProviderCustomAction` in `NSFileProviderReplicatedExtension.h`; the
 category of the same name in `NSFileProviderThumbnailing.h` is iOS-only.
 */
extension FileProviderExtension: NSFileProviderThumbnailing {
  func fetchThumbnails(
    for itemIdentifiers: [NSFileProviderItemIdentifier],
    requestedSize size: CGSize,
    perThumbnailCompletionHandler:
      @escaping @Sendable (
        NSFileProviderItemIdentifier, Data?, (any Error)?
      ) -> Void,
    completionHandler: @escaping @Sendable ((any Error)?) -> Void
  ) -> Progress {
    let progress = Progress(totalUnitCount: Int64(itemIdentifiers.count))
    let requested = itemIdentifiers.count
    let task = Task { [adapterBox] in
      do {
        try await adapterBox.adapter().thumbnails(
          for: itemIdentifiers,
          size: size
        ) { identifier, data in
          perThumbnailCompletionHandler(identifier, data, nil)
          progress.completedUnitCount += 1
        }
        completionHandler(nil)
      } catch {
        ZephyrLog.provider.error(
          """
          fetchThumbnails failed for \(requested, privacy: .public) items: \
          \(String(describing: error), privacy: .private)
          """
        )
        // Whatever went unreported belongs to this error: the protocol lets a
        // global failure stand in for the per-thumbnail handlers it skipped.
        completionHandler(mapToFileProviderError(error))
      }
    }
    progress.cancellationHandler = { task.cancel() }
    return progress
  }
}
