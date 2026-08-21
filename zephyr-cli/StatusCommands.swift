import ArgumentParser
import Foundation
import libZephyr

/// What `zephyr status` found, and its `--json` shape.
struct StatusReport: Encodable {
  let account: String
  let accountID: String
  let index: IndexState
  let files: UInt
  let folders: UInt
  /// Whether the account holds a delta cursor, and so can pick up remote
  /// changes without re-listing.
  let hasCursor: Bool
  /// Conditions stopping the whole account from syncing.
  let blockers: [Blocker]
  let syncIssueCount: UInt
  /// The issues listed, which `--limit` can make fewer than ``syncIssueCount``.
  let syncIssues: [Issue]

  /// How far the sync index has got.
  enum IndexState: String, Encodable {
    /// No index has been built yet.
    case missing

    /// The initial recursive listing is still running.
    case indexing

    /// The index mirrors the account and follows the change feed.
    case complete
  }

  /// A failure that stops the account syncing at all, rather than one item.
  struct Blocker: Encodable {
    let title: String
    let detail: String?
  }

  /// One item Dropbox and this Mac could not agree on.
  struct Issue: Encodable {
    let path: String
    let title: String
    let detail: String?
    let occurredAt: Date

    init(_ record: SyncErrorRecord) {
      path = record.path.displayPath
      title = record.title
      detail = record.detail
      occurredAt = record.occurredAt
    }
  }
}

struct StatusCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "status",
    abstract: "Show the account’s sync-index state and anything blocking it."
  )

  /// How many sync issues are listed when the user does not say.
  private static let defaultIssueLimit: UInt = 10

  private static let unauthenticated = StatusReport.Blocker(
    title: "Zephyr can’t authenticate as this account.",
    detail: "No refresh token is stored for it. Run “zephyr auth link” to relink."
  )

  @Flag(help: "List every sync issue, however many there are.")
  var all = false

  @Option(name: [.short, .customLong("limit")], help: "How many sync issues to list (default 10).")
  var limit: UInt?

  @Flag(help: "Emit JSON instead of a table.")
  var json = false

  @OptionGroup var accountOptions: AccountOptions

  private static func blocker(_ stopped: EngineErrorRecord) -> StatusReport.Blocker {
    StatusReport.Blocker(title: stopped.title, detail: stopped.detail)
  }

  /// Whether the CLI has no credential left for the account — the state a
  /// revoked token leaves behind, which no per-item retry can escape.
  private static func cannotAuthenticate(as account: AccountIdentifier) async throws -> Bool {
    let authenticatable = try await CLI.accountManager().authenticatableAccounts()
    return !authenticatable.contains(account)
  }

  private static func render(_ report: StatusReport) {
    Output.table(summaryRows(of: report))
    printBlockers(report.blockers)
    printIssues(report.syncIssues, of: report.syncIssueCount)
  }

  private static func summaryRows(of report: StatusReport) -> [[String]] {
    var rows = [["Account:", report.account]]
    switch report.index {
      case .missing:
        rows.append(["Index:", "not built yet (run “zephyr watch” or “zephyr rebuild-index”)"])
        return rows
      case .indexing:
        rows.append(["Index:", "initial listing in progress"])
      case .complete:
        rows.append(["Index:", "complete"])
    }
    rows.append(["Items:", "\(report.files) files, \(report.folders) folders"])
    rows.append(["Cursor:", report.hasCursor ? "current" : "none"])
    rows.append(["Sync issues:", "\(report.syncIssueCount)"])
    return rows
  }

  private static func printBlockers(_ blockers: [StatusReport.Blocker]) {
    guard !blockers.isEmpty else { return }
    print("")
    print("Blocked — nothing syncs until this is resolved:")
    for blocker in blockers {
      print("  ! \(blocker.title)")
      if let detail = blocker.detail { print("    \(detail)") }
    }
  }

  private static func printIssues(_ issues: [StatusReport.Issue], of total: UInt) {
    guard !issues.isEmpty else { return }
    print("")
    print(
      UInt(issues.count) == total
        ? "Sync issues:" : "Sync issues (\(issues.count) of \(total)):"
    )
    for issue in issues {
      print("  ! \(issue.path): \(issue.title)")
      if let detail = issue.detail { print("    \(detail)") }
    }
  }

  func run() async {
    await CLI.run {
      let listed = try issueLimit()
      let session = try await CLI.session(account: accountOptions.account)
      let report = try await report(for: session, listing: listed)
      if json {
        try Output.json(report)
      } else {
        Self.render(report)
      }
    }
  }

  /// How many issues to list; `nil` lists all of them.
  private func issueLimit() throws -> UInt? {
    guard !all else {
      guard limit == nil else { throw ValidationError("Pass either --all or --limit, not both.") }
      return nil
    }
    guard let limit else { return Self.defaultIssueLimit }
    guard limit >= 1 else { throw ValidationError("--limit must be at least 1.") }
    return limit
  }

  private func report(
    for session: AccountSession,
    listing limit: UInt?
  ) async throws -> StatusReport {
    let blockedByCredentials = try await Self.cannotAuthenticate(as: session.accountID)
    let credentialBlockers = blockedByCredentials ? [Self.unauthenticated] : []
    guard session.indexExists else {
      return StatusReport(
        account: session.configuration.email,
        accountID: session.accountID.rawValue,
        index: .missing,
        files: 0,
        folders: 0,
        hasCursor: false,
        blockers: credentialBlockers,
        syncIssueCount: 0,
        syncIssues: []
      )
    }
    let index = try await session.openIndex(mode: .readOnly)
    let counts = try await index.counts()
    let finished = try await index.didFinishInitialIndex()
    let cursor = try await index.currentCursor()
    let issues = try await index.syncErrors()
    let stopped = try await index.engineError().map(Self.blocker)
    let listedIssues = limit.map { Array(issues.prefix(Int($0))) } ?? issues
    return StatusReport(
      account: session.configuration.email,
      accountID: session.accountID.rawValue,
      index: finished ? .complete : .indexing,
      files: counts.files,
      folders: counts.folders,
      hasCursor: cursor != nil,
      blockers: credentialBlockers + (stopped.map { [$0] } ?? []),
      syncIssueCount: UInt(issues.count),
      syncIssues: listedIssues.map(StatusReport.Issue.init)
    )
  }
}

/// One synced change as the CLI reports it (also the `--json` shape).
struct HistoryEvent: Encodable {
  let recordedAt: Date
  let change: Change
  let direction: Direction
  let path: String
  let size: UInt64?
  let revision: String?

  init(_ record: HistoryEventRecord) {
    recordedAt = record.recordedAt
    change =
      switch record.changeType {
        case .added: .added
        case .modified: .modified
        case .removed: .removed
      }
    direction =
      switch record.direction {
        case .up: .up
        case .down: .down
      }
    path = record.path.displayPath
    size = record.size
    revision = record.revision?.rawValue
  }

  /// What happened to the item.
  enum Change: String, Encodable {
    /// The item appeared at the path.
    case added

    /// The item was already there, and its contents changed.
    case modified

    /// The item went away.
    case removed
  }

  /// Which way a change travelled.
  enum Direction: String, Encodable {
    /// This Mac sent the change to Dropbox.
    case up

    /// This Mac received the change from Dropbox.
    case down
  }
}

struct HistoryCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "history",
    abstract: "Show recently synced changes.",
    discussion: """
      History covers the last week. Given a path, only changes at or beneath it are shown. The \
      direction column says which way a change travelled: “up” for one this Mac sent to Dropbox, \
      “down” for one it received.
      """
  )

  @Argument(
    help: "Restrict to a Dropbox path and everything beneath it.",
    completion: .dropboxPath
  )
  var path: String?

  @Option(name: [.short, .customLong("limit")], help: "How many events to show.")
  var limit: UInt = 30

  @Flag(help: "Emit JSON instead of a table.")
  var json = false

  @OptionGroup var accountOptions: AccountOptions

  /// Whether a recorded event happened at a path or beneath it.
  private static func isAtOrUnder(_ scope: NormalizedDropboxPath, _ path: DropboxPath) -> Bool {
    guard !scope.isRoot else { return true }
    let path = path.normalized
    return path.rawValue == scope.rawValue || path.rawValue.hasPrefix(scope.rawValue + "/")
  }

  private static func render(_ events: [HistoryEvent], of scope: String?) {
    guard !events.isEmpty else {
      print(
        scope.map { "Nothing at or beneath \($0) has synced in the last week." }
          ?? "No sync history yet."
      )
      return
    }
    Output.table(
      [["DATE", "DIRECTION", "CHANGE", "PATH"]]
        + events.map {
          [Output.date($0.recordedAt), $0.direction.rawValue, $0.change.rawValue, $0.path]
        }
    )
  }

  func run() async {
    await CLI.run {
      guard limit >= 1 else { throw ValidationError("--limit must be at least 1.") }
      let session = try await CLI.session(account: accountOptions.account)
      guard session.indexExists else {
        if json { try Output.json([HistoryEvent]()) } else { print("No sync history yet.") }
        return
      }
      let events = try await events(from: try await session.openIndex(mode: .readOnly))
      if json {
        try Output.json(events)
      } else {
        Self.render(events, of: path)
      }
    }
  }

  /**
   The events to report, newest first.

   The index answers with the newest events across the whole account, so a
   path filter is applied here, over the week of history the index keeps.
   */
  private func events(from index: SyncIndexStore) async throws -> [HistoryEvent] {
    guard let path else {
      return try await index.recentHistory(limit: limit).map(HistoryEvent.init)
    }
    let scope = try CLI.dropboxPath(path).normalized
    let matching = try await index.recentHistory(limit: .max)
      .filter { Self.isAtOrUnder(scope, $0.path) }
    return matching.prefix(Int(limit)).map(HistoryEvent.init)
  }
}

struct RebuildIndexCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "rebuild-index",
    abstract: "Drop and rebuild the sync index from the current remote state.",
    discussion: """
      Finder tags, favorite ranks, last-used dates, extended attributes, and the excluded-item \
      marks survive a rebuild. The record of synced changes does not: Dropbox’s change feed never \
      replays an event it has already delivered, so “zephyr history” starts over empty.
      """
  )

  @Flag(name: [.customShort("Y"), .customLong("yes")], help: "Skip the confirmation prompt.")
  var assumeYes = false

  @OptionGroup var accountOptions: AccountOptions

  func run() async {
    await CLI.run {
      let session = try await CLI.session(account: accountOptions.account)
      let question = """
        Rebuild the index for \(session.configuration.email)? This discards the record of synced \
        changes, which Dropbox cannot replay.
        """
      guard try CLI.confirm(question, assumeYes: assumeYes) else { return }
      print("Rebuilding index…")
      try await session.rebuildIndex()
      let index = try await session.openIndex(mode: .readOnly)
      let counts = try await index.counts()
      print("Indexed \(counts.files) files and \(counts.folders) folders.")
      print(
        """
        Open the Zephyr app so Finder re-enumerates the folder: “zephyr” is entitled only to the \
        app group, so it cannot signal the File Provider domain itself.
        """
      )
    }
  }
}
