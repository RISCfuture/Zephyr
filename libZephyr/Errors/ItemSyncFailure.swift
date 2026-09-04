public import Foundation

/**
 A recoverable failure while syncing a single item.

 Mirrors Maestral's `SyncError` hierarchy: each case corresponds to a class of
 Dropbox route errors or local file-system errors that affects one item and is
 retried later rather than stopping the engine.
 */
public enum ItemSyncFailure: SyncItemError, Equatable {
  /// Transferred content failed hash verification, or the server reported
  /// corruption (`content_hash_mismatch`, `incorrect_offset`). Retried automatically.
  case dataCorruption(path: String)
  /// The local file changed while it was being uploaded; a later change event resyncs it.
  case dataChanged(path: String)
  /// Dropbox or the local file system denied access, or the app is missing an
  /// OAuth scope (`missing_scope`).
  case insufficientPermissions(path: String, detail: String?)
  /// The Dropbox account or the local disk is out of space.
  case insufficientSpace(path: String)
  /// The path is malformed, too long, disallowed, or otherwise rejected.
  case invalidPath(path: String, reason: String)
  /// The item does not exist where expected.
  case notFound(path: String)
  /// A conflicting file already exists at the destination.
  case fileConflict(path: String)
  /// A conflicting folder already exists at the destination.
  case folderConflict(path: String)
  /// A folder sits where a file was expected.
  case isAFolder(path: String)
  /// A file sits where a folder was expected.
  case notAFolder(path: String)
  /// Dropbox reported an internal error for this item.
  case serverError(path: String, detail: String?)
  /// Dropbox refuses to sync this content (for example, a DMCA takedown).
  case restrictedContent(path: String)
  /// The file cannot be synced by Dropbox (for example, an export-only cloud document).
  case unsupportedFile(path: String)
  /// The file exceeds Dropbox's size limit.
  case fileSizeExceeded(path: String)
  /// The local file could not be read.
  case fileReadFailed(path: String, detail: String?)
  /// The item is a symlink, which cannot be uploaded to Dropbox.
  case symlink(path: String)
  /// The item is a team folder, whose structure Dropbox manages rather than this client.
  case teamFolder(path: String)
  /// A Dropbox Business policy suppressed the operation (`operation_suppressed`).
  case operationSuppressed(path: String)
  /// A shared link already exists for the item.
  case sharedLinkExists(path: String)
  /// The account's plan does not offer the requested shared-link settings,
  /// such as a password or an expiration date.
  case linkSettingsUnavailable(path: String)
  /// Dropbox rejected the requested shared-link settings as invalid.
  case linkSettingsInvalid(path: String)
  /// Dropbox requires a verified account email address before sharing the item.
  case accountEmailUnverified(path: String)

  /**
   The same failure reported against `path`.

   A Dropbox route error names whichever specifier the request used, so a
   download pinned to a revision blames `rev:015d…` and a delete addressed by
   item id blames `id:…`. Re-targeting restores the path the caller knows,
   which is the only form the user recognizes in the status list.
   */
  public func retargeted(to path: String) -> Self {
    switch self {
      case .dataCorruption: .dataCorruption(path: path)
      case .dataChanged: .dataChanged(path: path)
      case .insufficientPermissions(_, let detail):
        .insufficientPermissions(path: path, detail: detail)
      case .insufficientSpace: .insufficientSpace(path: path)
      case .invalidPath(_, let reason): .invalidPath(path: path, reason: reason)
      case .notFound: .notFound(path: path)
      case .fileConflict: .fileConflict(path: path)
      case .folderConflict: .folderConflict(path: path)
      case .isAFolder: .isAFolder(path: path)
      case .notAFolder: .notAFolder(path: path)
      case .serverError(_, let detail): .serverError(path: path, detail: detail)
      case .restrictedContent: .restrictedContent(path: path)
      case .unsupportedFile: .unsupportedFile(path: path)
      case .fileSizeExceeded: .fileSizeExceeded(path: path)
      case .fileReadFailed(_, let detail): .fileReadFailed(path: path, detail: detail)
      case .symlink: .symlink(path: path)
      case .teamFolder: .teamFolder(path: path)
      case .operationSuppressed: .operationSuppressed(path: path)
      case .sharedLinkExists: .sharedLinkExists(path: path)
      case .linkSettingsUnavailable: .linkSettingsUnavailable(path: path)
      case .linkSettingsInvalid: .linkSettingsInvalid(path: path)
      case .accountEmailUnverified: .accountEmailUnverified(path: path)
    }
  }
}

extension ItemSyncFailure: LocalizedError {
  public var errorDescription: String? {
    String(localized: "Couldn’t sync an item.", bundle: #bundle)
  }

  public var failureReason: String? {
    switch self {
      case .dataCorruption(let path):
        String(
          localized: "The transferred data for “\(path)” failed verification.",
          bundle: #bundle
        )
      case .dataChanged(let path):
        String(localized: "“\(path)” changed while it was being uploaded.", bundle: #bundle)
      case let .insufficientPermissions(path, detail):
        sentence(
          String(localized: "Not permitted to access “\(path)”.", bundle: #bundle),
          followedBy: detail
        )
      case .insufficientSpace(let path):
        String(localized: "There is not enough space to sync “\(path)”.", bundle: #bundle)
      case let .invalidPath(path, reason):
        String(localized: "The path “\(path)” was rejected: \(reason).", bundle: #bundle)
      case .notFound(let path):
        String(localized: "“\(path)” could not be found.", bundle: #bundle)
      case .fileConflict(let path):
        String(localized: "A conflicting file already exists at “\(path)”.", bundle: #bundle)
      case .folderConflict(let path):
        String(localized: "A conflicting folder already exists at “\(path)”.", bundle: #bundle)
      case .isAFolder(let path):
        String(localized: "Expected a file at “\(path)” but found a folder.", bundle: #bundle)
      case .notAFolder(let path):
        String(localized: "Expected a folder at “\(path)” but found a file.", bundle: #bundle)
      case let .serverError(path, detail):
        sentence(
          String(localized: "Dropbox reported a server error for “\(path)”.", bundle: #bundle),
          followedBy: detail
        )
      case .restrictedContent(let path):
        String(localized: "Dropbox restricts syncing the content at “\(path)”.", bundle: #bundle)
      case .unsupportedFile(let path):
        String(localized: "“\(path)” is a file type Dropbox cannot sync.", bundle: #bundle)
      case .fileSizeExceeded(let path):
        String(localized: "“\(path)” is larger than Dropbox allows.", bundle: #bundle)
      case let .fileReadFailed(path, detail):
        sentence(
          String(localized: "Couldn’t read “\(path)”.", bundle: #bundle),
          followedBy: detail
        )
      case .symlink(let path):
        String(localized: "“\(path)” is a symbolic link, which can’t be uploaded.", bundle: #bundle)
      case .teamFolder(let path):
        String(
          localized: "“\(path)” is a team folder, which only a team admin can change.",
          bundle: #bundle
        )
      case .operationSuppressed(let path):
        String(
          localized: "A Dropbox team policy doesn’t allow this change to “\(path)”.",
          bundle: #bundle
        )
      case .sharedLinkExists(let path):
        String(localized: "A shared link for “\(path)” already exists.", bundle: #bundle)
      case .linkSettingsUnavailable(let path):
        String(
          localized: "This Dropbox plan doesn’t offer the requested link settings for “\(path)”.",
          bundle: #bundle
        )
      case .linkSettingsInvalid(let path):
        String(
          localized: "Dropbox rejected the link settings requested for “\(path)”.",
          bundle: #bundle
        )
      case .accountEmailUnverified(let path):
        String(
          localized: "“\(path)” can’t be shared until the account’s email is verified.",
          bundle: #bundle
        )
    }
  }

  public var recoverySuggestion: String? {
    switch self {
      case .linkSettingsUnavailable:
        String(
          localized: "Upgrade the Dropbox plan, or omit the password and expiration date.",
          bundle: #bundle
        )
      case .accountEmailUnverified:
        String(localized: "Verify the email address on this Dropbox account.", bundle: #bundle)
      case .sharedLinkExists:
        String(localized: "List the existing links instead of creating one.", bundle: #bundle)
      default:
        nil
    }
  }

  /**
   The help-book topic, in Foundation's own slot for one.

   Every case is one item that couldn't sync, whatever the reason, and that is
   the article: it says where the list of them lives, what Show and Dismiss do,
   and what to check. A page per Dropbox rejection would be thirty pages
   telling the reader to look at the same window.
   */
  public var helpAnchor: String? { HelpAnchor.syncIssues.rawValue }

  /// `reason` alone, or with the detail Dropbox or the file system supplied as
  /// a second sentence. Several cases carry no detail, so the two are joined
  /// only when there is something to join.
  private func sentence(_ reason: String, followedBy detail: String?) -> String {
    guard let detail else { return reason }
    return "\(reason) \(detail)"
  }
}
