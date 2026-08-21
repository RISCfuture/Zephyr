import Foundation

/// A failure in the SQLite sync index or the configuration store. Nothing can
/// sync while the index is unreadable, so the type is also in the fatal tier.
enum IndexStoreFailure: StoreError, SyncFatalError {
  /// The underlying database reported an error.
  case database(detail: String)
  /// The database schema could not be created or migrated.
  case migration(detail: String)
  /// The index carries a newer schema than this build understands.
  case schemaFromNewerBuild
  /// A write was attempted through a read-only store.
  case readOnly
}

extension IndexStoreFailure: LocalizedError {
  public var errorDescription: String? {
    String(localized: "The sync index is unavailable.", bundle: #bundle)
  }

  public var failureReason: String? {
    switch self {
      case .database(let detail):
        String(localized: "The index database reported: \(detail).", bundle: #bundle)
      case .migration(let detail):
        String(localized: "The index database couldn’t be migrated: \(detail).", bundle: #bundle)
      case .schemaFromNewerBuild:
        String(
          localized: """
            A newer version of Zephyr built this index, so this one can’t read it safely.
            """,
          bundle: #bundle
        )
      case .readOnly:
        String(localized: "This process opened the index read-only.", bundle: #bundle)
    }
  }

  public var recoverySuggestion: String? {
    switch self {
      case .schemaFromNewerBuild:
        String(
          localized: "Install the newest version of Zephyr, and keep only one copy of the app.",
          bundle: #bundle
        )
      default:
        nil
    }
  }

  /**
   The help-book topic, in Foundation's own slot for one.

   `.schemaFromNewerBuild` is what two installed copies of Zephyr look like
   from down here, and the article about a Dropbox that won't appear in Finder
   is where keeping only one is explained. The rest are faults in the database
   itself, which no article can talk the reader through.
   */
  public var helpAnchor: String? {
    switch self {
      case .schemaFromNewerBuild: HelpAnchor.dropboxNotInFinder.rawValue
      default: nil
    }
  }
}
