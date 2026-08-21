import Foundation

/// Something a shortcut asked Zephyr to do, and Zephyr could not.
public enum ScriptingFailure: Error, Equatable {
  /// No Dropbox account is linked to the app.
  case noAccountLinked

  /// The item the shortcut named is no longer in the sync index.
  case itemUnavailable(name: String)

  /// The shortcut named a file where a folder belongs.
  case notAFolder(name: String)

  /// Dropbox holds no earlier revision of the file.
  case noRevisions(name: String)

  /// Nothing is registered with Finder, so there is no syncing to pause.
  case noSyncingToPause
}

extension ScriptingFailure: LocalizedError {
  public var errorDescription: String? {
    String(localized: "Zephyr couldn’t run this shortcut.", bundle: #bundle)
  }

  public var failureReason: String? {
    switch self {
      case .noAccountLinked:
        // Word for word what `EngineFailure.notLinked` says. One condition
        // reads the same however the reader arrived at it, and the catalog
        // holds one entry rather than two that translators must keep level.
        String(localized: "No Dropbox account is linked.", bundle: #bundle)
      case .itemUnavailable(let name):
        String(localized: "“\(name)” is no longer in your Dropbox.", bundle: #bundle)
      case .notAFolder(let name):
        String(localized: "“\(name)” is a file, not a folder.", bundle: #bundle)
      case .noRevisions(let name):
        String(localized: "Dropbox has no earlier version of “\(name)”.", bundle: #bundle)
      case .noSyncingToPause:
        String(localized: "No Dropbox account is set up in Finder.", bundle: #bundle)
    }
  }

  /// `EngineFailure` answers the same condition by naming `zephyr auth link`,
  /// which is the wrong advice for somebody holding a shortcut — and the
  /// reason these cases carry their own suggestions rather than deferring.
  public var recoverySuggestion: String? {
    switch self {
      case .noAccountLinked:
        String(localized: "Open Zephyr and link a Dropbox account.", bundle: #bundle)
      case .itemUnavailable:
        String(localized: "Choose the item again in the shortcut.", bundle: #bundle)
      case .notAFolder:
        String(localized: "Choose a folder instead.", bundle: #bundle)
      case .noRevisions:
        nil
      case .noSyncingToPause:
        String(localized: "Open Zephyr and turn it on in Finder.", bundle: #bundle)
    }
  }

  public var helpAnchor: String? {
    switch self {
      case .noAccountLinked: HelpAnchor.linkAccount.rawValue
      case .noSyncingToPause: HelpAnchor.dropboxNotInFinder.rawValue
      default: nil
    }
  }
}
