import os

/**
 The unified-logging loggers used throughout Zephyr, all under the
 `codes.tim.Zephyr` subsystem so `log stream` and the CLI's `log show` can
 filter on one predicate. The app, the File Provider extension, the share
 extension, and the widget each run in their own process and their own
 security context; the unified log is the only place their behavior
 correlates, so every process logs here rather than to a private logger.

 ## Privacy

 Every sysdiagnose captures the whole unified log, so treat each interpolation
 as something a stranger may end up reading:

 - Anything drawn from the user's Dropbox — paths, file and folder names,
   account display names, tokens, and error values that interpolate them (as
   ``ItemSyncFailure``'s descriptions do) — is `privacy: .private`. It still
   renders in a live `log stream` on the developer's own machine and is
   redacted in captured logs.
 - Identifiers that only need to correlate lines — account, domain, and
   Dropbox item identifiers — are `privacy: .private(mask: .hash)`: equal
   values hash alike within a capture, so a report stays readable without
   naming the account or the item.
 - Only values that say nothing about the user stay `privacy: .public`: route
   names, HTTP statuses, retry counts and delays, page and entry counts, and
   fixed message text.

 An interpolation without an explicit privacy level is private for strings and
 public for numbers; state the level anyway, so the choice is visible where the
 line is written.
 */
public enum ZephyrLog {
  /// The subsystem every Zephyr process logs under, and the one a `log show`
  /// predicate filters on.
  public static let subsystem = "codes.tim.Zephyr"

  /// HTTP traffic to the Dropbox API: retries, backoff, and rate limiting.
  public static let transport = logger(.transport)
  /// Account linking, token refresh, and credential storage.
  public static let auth = logger(.auth)
  /// Reads and writes against the on-disk sync index.
  public static let index = logger(.index)
  /// Sync engine progress: initial indexing, delta application, and cursor resets.
  public static let engine = logger(.engine)
  /// File uploads and downloads, including chunked session transfers.
  public static let transfers = logger(.transfers)
  /// The File Provider extension's requests from `fileproviderd`, which
  /// records nothing of its own about why one failed.
  public static let provider = logger(.provider)
  /// The app-side longpoll watcher that signals domains when Dropbox changes.
  public static let watcher = logger(.watcher)

  /**
   Interval instrumentation for the work whose cost is invisible from outside
   the process: the indexer's pages, the extension's answers to
   `fileproviderd`, and chunked transfers.

   Signposts are filed under Points of Interest rather than a category of
   their own, so a trace spanning the app and `fileproviderd` reads without
   an instrument having to be configured, and the interval names are what
   tell the areas apart. The same privacy rule applies as to the loggers, and
   more strictly: an interval carries counts, sizes, and offsets only, never
   a path, a filename, or an account identifier.
   */
  public static let signposter = OSSignposter(
    subsystem: subsystem,
    category: OSLog.Category.pointsOfInterest.rawValue
  )

  private static func logger(_ category: Category) -> Logger {
    Logger(subsystem: subsystem, category: category.rawValue)
  }

  /**
   The categories Zephyr's loggers are filed under.

   Enumerating them is what lets `zephyr log --category` offer and validate
   the set, rather than restating it and drifting when one is added here.
   */
  public enum Category: String, CaseIterable, Sendable {
    case transport
    case auth
    case index
    case engine
    case transfers
    case provider
    case watcher
  }
}
