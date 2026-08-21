import FileProvider
import Foundation
import libZephyr
import os

/// The `fileproviderd` requests whose failures are logged and mapped. The raw
/// values are the field a failed sync is grepped by in the unified log.
enum ProviderRequest: String {
  case item, fetchContents, modifyItem, deleteItem
}

/**
 Maps a libZephyr engine error to the `NSFileProviderError` the system expects
 in completion handlers, passing unrecognized errors through as-is.

 The distinction the system acts on is whether the request can ever succeed:
 a terminal failure becomes `.cannotSynchronize` so `fileproviderd` stops
 re-issuing it and Finder shows a settled state, while a failure a later
 attempt can clear is left retryable.
 */
func mapToFileProviderError(_ error: any Error) -> any Error {
  if isCancellation(error) {
    return NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
  }
  if let failure = error as? EngineFailure { return providerError(for: failure) }
  if error is any AuthError { return NSFileProviderError(.notAuthenticated) }
  if let failure = error as? ItemSyncFailure { return providerError(for: failure) }
  return error
}

/// Maps errors from delete requests: a revision-guard conflict rejects the
/// deletion, so the system restores the item and the change feed then
/// delivers the newer remote version.
func mapToDeletionError(_ error: any Error) -> any Error {
  switch error {
    case ItemSyncFailure.fileConflict, ItemSyncFailure.folderConflict:
      NSFileProviderError(.deletionRejected)
    default:
      mapToFileProviderError(error)
  }
}

/// Logs a failed request from `fileproviderd` before mapping it, and returns
/// the error the system expects back. `fileproviderd` records nothing of its
/// own about why a request failed, so without this line a failed sync leaves
/// no trace anywhere on the machine.
func mapToFileProviderError(
  _ error: any Error,
  failing request: ProviderRequest,
  on identifier: NSFileProviderItemIdentifier
) -> any Error {
  logProviderFailure(error, failing: request, on: identifier)
  return mapToFileProviderError(error)
}

/// The deletion-request counterpart of ``mapToFileProviderError(_:failing:on:)``.
func mapToDeletionError(
  _ error: any Error,
  failing request: ProviderRequest,
  on identifier: NSFileProviderItemIdentifier
) -> any Error {
  logProviderFailure(error, failing: request, on: identifier)
  return mapToDeletionError(error)
}

private func isCancellation(_ error: any Error) -> Bool {
  switch error {
    case is CancellationError, EngineFailure.cancelled: true
    case let urlError as URLError: urlError.code == .cancelled
    default: false
  }
}

private func providerError(for failure: EngineFailure) -> any Error {
  switch failure {
    case .notLinked:
      NSFileProviderError(.notAuthenticated)
    case .connection:
      NSFileProviderError(.serverUnreachable)
    // The account's namespace moved and the app re-resolves it out of band, so
    // the system should come back later rather than settle the request.
    case .pathRootChanged:
      NSFileProviderError(.serverUnreachable)
    // Indexing held back over what the path costs. Nothing the user asked for
    // rides that session, so this only ever reaches an enumeration waiting on
    // a catch-up, and the honest answer is to come back later.
    case .deferredForNetworkCost:
      NSFileProviderError(.serverUnreachable)
    case .cancelled:
      NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
    // Both are the adapter's own business: a cursor reset is handled by
    // reindexing, and a busy lock clears as soon as the holder finishes.
    case .cursorReset, .busy, .cacheDirectory:
      failure
  }
}

private func providerError(for failure: ItemSyncFailure) -> any Error {
  switch failure {
    case .notFound:
      NSFileProviderError(.noSuchItem)
    case .insufficientSpace:
      NSFileProviderError(.insufficientQuota)
    // Re-granting a scope, freeing a lock, or a settled local write genuinely
    // clears these, so the system keeps the item pending.
    case .insufficientPermissions, .dataChanged, .fileReadFailed, .serverError, .fileConflict,
      .folderConflict:
      failure
    // Nothing a retry does changes the answer: the content, the name, the item
    // type, or the account's plan is what Dropbox objected to.
    case .dataCorruption, .invalidPath, .isAFolder, .notAFolder, .restrictedContent,
      .unsupportedFile, .fileSizeExceeded, .symlink, .teamFolder, .operationSuppressed,
      .sharedLinkExists, .linkSettingsUnavailable, .linkSettingsInvalid, .accountEmailUnverified:
      cannotSynchronize(failure)
  }
}

/// A terminal failure, carrying its own text so Finder shows what Dropbox
/// objected to rather than a bare "couldn't be synchronized."
private func cannotSynchronize(_ failure: ItemSyncFailure) -> any Error {
  var userInfo: [String: Any] = [NSUnderlyingErrorKey: failure as NSError]
  if let description = failure.errorDescription {
    userInfo[NSLocalizedDescriptionKey] = description
  }
  if let reason = failure.failureReason {
    userInfo[NSLocalizedFailureReasonErrorKey] = reason
  }
  return NSError(
    domain: NSFileProviderError.errorDomain,
    code: NSFileProviderError.Code.cannotSynchronize.rawValue,
    userInfo: userInfo
  )
}

private func logProviderFailure(
  _ error: any Error,
  failing request: ProviderRequest,
  on identifier: NSFileProviderItemIdentifier
) {
  ZephyrLog.provider.error(
    """
    \(request.rawValue, privacy: .public) failed for item \
    \(identifier.rawValue, privacy: .private(mask: .hash)): \
    \(String(describing: error), privacy: .private)
    """
  )
}
