import ArgumentParser
import Foundation
import libZephyr

struct DiffCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "diff",
    abstract: "Compare two revisions of a Dropbox file.",
    discussion: """
      With no --rev, compares the two most recent revisions. With one --rev, compares it against \
      the latest. With two, compares them oldest-first. Revisions come from “zephyr revs”.
      """
  )

  @Argument(help: "The Dropbox file.", completion: .dropboxPath)
  var path: String

  @Option(help: ArgumentHelp("A revision to compare (repeatable, max twice).", valueName: "rev"))
  var rev: [String] = []

  @OptionGroup var accountOptions: AccountOptions

  private static func label(path: DropboxPath, of metadata: FileMetadata) -> String {
    "\(path.rawValue) (rev \(metadata.rev.rawValue), \(Output.date(metadata.serverModified)))"
  }

  /// Runs `diff -u`; exit status 1 (differences found) is a normal outcome.
  private static func runDiff(
    older: URL,
    newer: URL,
    olderLabel: String,
    newerLabel: String
  ) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/diff")
    process.arguments = [
      "-u", "--label", olderLabel, "--label", newerLabel, older.path, newer.path
    ]
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus == 0 {
      print("The revisions are identical.")
    } else if process.terminationStatus > 1 {
      throw ValidationError("diff failed with status \(process.terminationStatus).")
    }
  }

  func run() async {
    await CLI.run {
      guard rev.count <= 2 else {
        throw ValidationError("Pass --rev at most twice.")
      }
      let session = try await CLI.session(account: accountOptions.account)
      let dropboxPath = try CLI.dropboxPath(path)
      let revisions = try await resolveRevisions(session: session, path: dropboxPath)
      try await printDiff(session: session, path: dropboxPath, revisions: revisions)
    }
  }

  /// Resolves the pair to compare, ordered older revision first.
  private func resolveRevisions(
    session: AccountSession,
    path: DropboxPath
  ) async throws -> (older: FileMetadata, newer: FileMetadata) {
    let stored = try await session.revisions(
      of: await CLI.fileSpecifier(for: path, in: session),
      limit: CLI.revisionLimits.upperBound
    )
    func lookup(_ value: String) throws -> FileMetadata {
      guard let match = stored.first(where: { $0.rev.rawValue == value }) else {
        throw ValidationError("Revision \(value) is not among the stored revisions of \(path).")
      }
      return match
    }
    switch rev.count {
      case 2:
        let first = try lookup(rev[0])
        let second = try lookup(rev[1])
        return first.serverModified <= second.serverModified
          ? (first, second) : (second, first)
      case 1:
        guard let latest = stored.first else {
          throw ValidationError("\(path) has no stored revisions.")
        }
        return (try lookup(rev[0]), latest)
      default:
        guard stored.count >= 2 else {
          throw ValidationError("\(path) has only one stored revision; nothing to compare.")
        }
        return (stored[1], stored[0])
    }
  }

  private func printDiff(
    session: AccountSession,
    path: DropboxPath,
    revisions: (older: FileMetadata, newer: FileMetadata)
  ) async throws {
    let staging = FileManager.default.temporaryDirectory
      .appending(component: "zephyr-diff-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: staging) }

    let olderURL = staging.appending(component: "older")
    let newerURL = staging.appending(component: "newer")
    _ = try await session.download(path, revision: revisions.older.rev, to: olderURL)
    _ = try await session.download(path, revision: revisions.newer.rev, to: newerURL)

    try Self.runDiff(
      older: olderURL,
      newer: newerURL,
      olderLabel: Self.label(path: path, of: revisions.older),
      newerLabel: Self.label(path: path, of: revisions.newer)
    )
  }
}
