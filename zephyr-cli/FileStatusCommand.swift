import ArgumentParser
import Foundation
import libZephyr

struct FileStatusCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "filestatus",
    abstract: "Say whether one item is synced, failing, excluded, or unknown.",
    discussion: """
      The answer comes from the sync index, so it reports what Zephyr and Dropbox last agreed on. \
      A folder answers for its whole subtree: it reports the newest failure recorded at or beneath \
      it, the way Finder badges a folder.

      Whether a file’s contents are on this Mac right now — downloading, materialized, or evicted \
      to save space — is macOS’s business rather than Zephyr’s, so no answer here says \
      “downloading”. Finder is where that state lives.
      """
  )

  @Argument(help: "The Dropbox path to report on.", completion: .dropboxPath)
  var path: String

  @Flag(help: "Emit JSON.")
  var json = false

  @OptionGroup var accountOptions: AccountOptions

  /// How an indexed status is reported.
  private static func reported(_ status: FileSyncStatus) -> Report.Status {
    switch status {
      case .synced: .synced
      case .ignored: .ignored
      case .failed: .error
      case .unknown: .unknown
    }
  }

  private static func failure(in status: FileSyncStatus) -> SyncErrorRecord? {
    guard case .failed(let record) = status else { return nil }
    return record
  }

  func run() async {
    await CLI.run {
      let session = try await CLI.session(account: accountOptions.account)
      let dropboxPath = try CLI.dropboxPath(path)
      let status = try await indexedStatus(of: dropboxPath, in: session)
      try report(status, at: dropboxPath)
    }
  }

  /// What the index says about a path, or `.unknown` when there is no index yet.
  private func indexedStatus(
    of path: DropboxPath,
    in session: AccountSession
  ) async throws -> FileSyncStatus {
    guard session.indexExists else { return .unknown }
    return try await session.openIndex(mode: .readOnly).status(ofPath: path.normalized)
  }

  private func report(_ status: FileSyncStatus, at path: DropboxPath) throws {
    let failure = Self.failure(in: status)
    guard !json else {
      try Output.json(
        Report(
          path: path.isRoot ? "/" : path.rawValue,
          status: Self.reported(status),
          title: failure?.title,
          detail: failure?.detail,
          occurredAt: failure?.occurredAt
        )
      )
      return
    }
    print(Self.reported(status).rawValue)
    guard let failure else { return }
    print("  \(failure.title)")
    if let detail = failure.detail { print("  \(detail)") }
    print("  at \(failure.path.displayPath), \(Output.date(failure.occurredAt))")
  }

  /// The `--json` shape.
  private struct Report: Encodable {
    let path: String
    let status: Status
    let title: String?
    let detail: String?
    let occurredAt: Date?

    /// The one-word answer, which is what a script branches on.
    enum Status: String, Encodable {
      /// The item is indexed and nothing failed against it — nor, for a
      /// folder, against anything beneath it.
      case synced

      /// The item is excluded from syncing.
      case ignored

      /// The item — or, for a folder, something beneath it — last failed to
      /// sync.
      case error

      /// Nothing at the path is indexed.
      case unknown
    }
  }
}
