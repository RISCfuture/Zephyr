import ArgumentParser
import Foundation
import libZephyr

extension CompletionKind {
  /// Completes an account argument from every linked account, because a
  /// Dropbox account identifier is an opaque `dbid:` string nobody types
  /// from memory. This is the set `auth` acts on: an account whose
  /// credentials no longer work is still one you can inspect or unlink.
  static let linkedAccount = CompletionKind.custom { _, _, _ in
    let accounts = try? await CLI.accountManager().linkedAccounts()
    return accounts?.map(\.rawValue) ?? []
  }

  /// Completes an account argument from the accounts the command line can
  /// actually authenticate as, matching what ``CLI/session(account:)``
  /// resolves — suggesting any other account offers one the tool refuses.
  static let authenticatableAccount = CompletionKind.custom { _, _, _ in
    let accounts = try? await CLI.accountManager().authenticatableAccounts()
    return accounts?.map(\.rawValue) ?? []
  }

  /// Completes a Dropbox path — file or folder — from the account's sync
  /// index, which knows the whole account rather than the part of it whose
  /// contents happen to be on this Mac.
  static let dropboxPath = CompletionKind.custom { words, _, prefix in
    await CLI.pathCompletions(matching: prefix, inCommandLine: words, offering: .anyItem)
  }

  /// Completes a Dropbox path for an argument no file can answer, offering
  /// only the folders the sync index holds.
  static let dropboxFolder = CompletionKind.custom { words, _, prefix in
    await CLI.pathCompletions(matching: prefix, inCommandLine: words, offering: .folder)
  }
}

/// The account selector shared by the commands that operate on a Dropbox.
struct AccountOptions: ParsableArguments {
  @Option(
    help: "The account to operate on, when several are linked.",
    completion: .authenticatableAccount
  )
  var account: String?
}

extension CLI {
  /// How many revisions `files/list_revisions` will return at once.
  static let revisionLimits: ClosedRange<UInt> = 1...100

  /**
   How to address a Dropbox file for calls that follow its history.

   The sync index knows the file's Dropbox identifier, and an identifier
   survives the renames and moves that make a path stop answering for the
   same file. Without an index, or without an entry for the path, the path
   itself is the best available answer.
   */
  static func fileSpecifier(for path: DropboxPath, in session: AccountSession) async
    -> PathSpecifier
  {
    guard session.indexExists,
      let index = try? await session.openIndex(mode: .readOnly),
      let entry = try? await index.entry(forPath: path.normalized)
    else { return .path(path) }
    return .id(entry.dbxID)
  }
}

/// One folder entry as the CLI reports it (also the `--json` shape).
struct ListedEntry: Encodable {
  let kind: Kind
  let path: String
  let size: UInt64?
  let modified: Date?
  let revision: String?
  /// Whether the item is shared, or lives inside a shared folder. Absent for
  /// a deletion tombstone, which carries only a path.
  let shared: Bool?

  /// What the folder holds at a path.
  enum Kind: String, Encodable {
    /// A file, which carries a size, a modification date, and a revision.
    case file

    /// A folder, which a further listing enumerates.
    case folder

    /// A deletion tombstone, which carries only a path.
    case deleted
  }
}

struct ListCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "ls",
    abstract: "List a Dropbox folder."
  )

  @Argument(help: "The folder to list (default: the Dropbox root).", completion: .dropboxFolder)
  var path: String = "/"

  @Flag(name: .short, help: "Long format: size, date, revision, and sharing columns.")
  var long = false

  @Flag(help: "Include deletion tombstones.")
  var includeDeleted = false

  @Flag(help: "Emit JSON.")
  var json = false

  @OptionGroup var accountOptions: AccountOptions

  private static func listed(_ item: ItemMetadata) -> ListedEntry {
    switch item {
      case .file(let file):
        ListedEntry(
          kind: .file,
          path: file.pathDisplay?.rawValue ?? file.name,
          size: file.size,
          modified: file.serverModified,
          revision: file.rev.rawValue,
          shared: file.isShared
        )
      case .folder(let folder):
        ListedEntry(
          kind: .folder,
          path: folder.pathDisplay?.rawValue ?? folder.name,
          size: nil,
          modified: nil,
          revision: nil,
          shared: folder.isShared
        )
      case .deleted(let deleted):
        ListedEntry(
          kind: .deleted,
          path: deleted.pathDisplay?.rawValue ?? deleted.name,
          size: nil,
          modified: nil,
          revision: nil,
          shared: nil
        )
    }
  }

  /// The Shared column's cell: named only where it is true, so a listing of
  /// unshared items stays quiet.
  private static func sharing(_ shared: Bool?) -> String {
    shared == true ? "shared" : Output.missing
  }

  func run() async {
    await CLI.run {
      let session = try await CLI.session(account: accountOptions.account)
      var entries: [ListedEntry] = []
      for try await item in session.listFolder(
        try CLI.dropboxPath(path),
        includeDeleted: includeDeleted
      ) {
        entries.append(Self.listed(item))
      }
      entries.sort { $0.path.lowercased() < $1.path.lowercased() }
      if json {
        try Output.json(entries)
      } else if long {
        Output.table(
          entries.map { entry in
            [
              entry.kind.rawValue,
              Output.bytes(entry.size),
              Output.date(entry.modified),
              entry.revision ?? Output.missing,
              Self.sharing(entry.shared),
              entry.path
            ]
          }
        )
      } else {
        for entry in entries {
          print(entry.path + (entry.kind == .folder ? "/" : ""))
        }
      }
    }
  }
}

struct GetCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "get",
    abstract: "Download a file from Dropbox, verifying its content hash."
  )

  @Argument(help: "The Dropbox file to download.", completion: .dropboxPath)
  var dropboxPath: String

  @Argument(help: "Where to put it (default: the file’s name in the working directory).")
  var localPath: String?

  @Option(name: .customLong("rev"), help: "Download a specific revision.")
  var revision: String?

  @OptionGroup var accountOptions: AccountOptions

  func run() async {
    await CLI.run {
      let session = try await CLI.session(account: accountOptions.account)
      let source = try CLI.dropboxPath(dropboxPath)
      var destination = URL(
        fileURLWithPath: localPath ?? source.basename,
        relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      )
      var isDirectory: ObjCBool = false
      if FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory),
        isDirectory.boolValue
      {
        destination.append(component: source.basename)
      }
      let metadata = try await session.download(
        source,
        revision: revision.map { try FileRevision(validating: $0) },
        to: destination
      )
      print(
        "Downloaded \(metadata.name) (\(Output.bytes(metadata.size)), rev \(metadata.rev.rawValue))."
      )
    }
  }
}

struct PutCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "put",
    abstract: "Upload a file to Dropbox."
  )

  @Argument(help: "The local file to upload.")
  var localPath: String

  @Argument(help: "The Dropbox destination path.", completion: .dropboxPath)
  var dropboxPath: String

  @Flag(help: "Replace whatever is at the destination unconditionally.")
  var overwrite = false

  @Option(
    name: .customLong("update-rev"),
    help: "Update only if the destination is still at this revision."
  )
  var updateRevision: String?

  @OptionGroup var accountOptions: AccountOptions

  func run() async {
    await CLI.run {
      let session = try await CLI.session(account: accountOptions.account)
      let mode: WriteMode =
        if overwrite {
          .overwrite
        } else if let updateRevision {
          .update(try FileRevision(validating: updateRevision))
        } else {
          .add
        }
      let metadata = try await session.upload(
        URL(fileURLWithPath: localPath),
        to: try CLI.dropboxPath(dropboxPath),
        mode: mode
      )
      print(
        "Uploaded \(metadata.pathDisplay?.rawValue ?? metadata.name) (rev \(metadata.rev.rawValue))."
      )
    }
  }
}

struct RemoveCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "rm",
    abstract: "Delete a file or folder in Dropbox."
  )

  @Argument(help: "The Dropbox path to delete.", completion: .dropboxPath)
  var path: String

  @OptionGroup var accountOptions: AccountOptions

  func run() async {
    await CLI.run {
      let session = try await CLI.session(account: accountOptions.account)
      let deleted = try await session.delete(try CLI.dropboxPath(path))
      print("Deleted \(deleted.pathDisplay?.rawValue ?? deleted.name).")
    }
  }
}

struct MakeDirectoryCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "mkdir",
    abstract: "Create a folder in Dropbox."
  )

  @Argument(help: "The folder to create.", completion: .dropboxFolder)
  var path: String

  @OptionGroup var accountOptions: AccountOptions

  func run() async {
    await CLI.run {
      let session = try await CLI.session(account: accountOptions.account)
      let folder = try await session.createFolder(at: try CLI.dropboxPath(path))
      print("Created \(folder.pathDisplay?.rawValue ?? folder.name)/.")
    }
  }
}

struct MoveCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "mv",
    abstract: "Move or rename a file or folder in Dropbox (server-side)."
  )

  @Argument(help: "The source path.", completion: .dropboxPath)
  var source: String

  @Argument(help: "The destination path.", completion: .dropboxPath)
  var destination: String

  @OptionGroup var accountOptions: AccountOptions

  func run() async {
    await CLI.run {
      let session = try await CLI.session(account: accountOptions.account)
      let moved = try await session.move(
        from: try CLI.dropboxPath(source),
        to: try CLI.dropboxPath(destination)
      )
      print("Moved to \(moved.pathDisplay?.rawValue ?? moved.name).")
    }
  }
}

/// One stored revision as the CLI reports it (also the `--json` shape).
struct ListedRevision: Encodable {
  let revision: String
  let modified: Date
  let size: UInt64

  init(_ metadata: FileMetadata) {
    revision = metadata.rev.rawValue
    modified = metadata.serverModified
    size = metadata.size
  }
}

struct RevisionsCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "revs",
    abstract: "List a file’s stored revisions.",
    discussion: """
      Revisions are listed newest first. A file indexed on this Mac is followed through the \
      renames and moves it survived, so its history does not stop at its current name.
      """
  )

  @Argument(help: "The Dropbox file.", completion: .dropboxPath)
  var path: String

  @Option(name: [.short, .customLong("limit")], help: "How many revisions to list (1–100).")
  var limit: UInt = 10

  @Flag(help: "Emit JSON.")
  var json = false

  @OptionGroup var accountOptions: AccountOptions

  func run() async {
    await CLI.run {
      guard CLI.revisionLimits.contains(limit) else {
        throw ValidationError(
          """
          --limit must be between \(CLI.revisionLimits.lowerBound) and \
          \(CLI.revisionLimits.upperBound).
          """
        )
      }
      let session = try await CLI.session(account: accountOptions.account)
      let dropboxPath = try CLI.dropboxPath(path)
      let listed = try await session.revisions(
        of: await CLI.fileSpecifier(for: dropboxPath, in: session),
        limit: limit
      )
      .map(ListedRevision.init)
      if json {
        try Output.json(listed)
      } else {
        Output.table(listed.map { [$0.revision, Output.date($0.modified), Output.bytes($0.size)] })
      }
    }
  }
}

struct RestoreCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "restore",
    abstract: "Restore a file to an earlier revision.",
    discussion: """
      With no --rev, and a terminal to ask on, Zephyr lists the file’s stored revisions and asks \
      which one to restore. Finder shows no version history for a Dropbox folder, so this is where \
      Zephyr’s lives.
      """
  )

  /// How many revisions the picker offers: enough to reach past a burst of
  /// edits, few enough to read without scrolling the terminal back.
  private static let pickerDepth: UInt = 20

  @Argument(help: "The Dropbox file.", completion: .dropboxPath)
  var path: String

  @Option(help: "The revision to restore (see “zephyr revs”). Omit to choose one.")
  var rev: String?

  @OptionGroup var accountOptions: AccountOptions

  /// Offers the revisions on the terminal and reads back a choice.
  private static func pick(from revisions: [FileMetadata], of path: DropboxPath) -> FileRevision? {
    print("Revisions of \(path.rawValue), newest first:")
    Output.table(
      revisions.enumerated().map { position, revision in
        [
          "\(position + 1))",
          Output.date(revision.serverModified),
          Output.bytes(revision.size),
          revision.rev.rawValue
        ]
      }
    )
    while true {
      guard
        let answer = Output.ask("Restore which revision? [1–\(revisions.count), or q to cancel]"),
        answer.lowercased() != "q"
      else { return nil }
      if let choice = Int(answer), revisions.indices.contains(choice - 1) {
        return revisions[choice - 1].rev
      }
      print("Enter a number between 1 and \(revisions.count), or q to cancel.")
    }
  }

  func run() async {
    await CLI.run {
      let session = try await CLI.session(account: accountOptions.account)
      let dropboxPath = try CLI.dropboxPath(path)
      guard let revision = try await chosenRevision(of: dropboxPath, in: session) else {
        print("Cancelled.")
        return
      }
      let restored = try await session.restore(dropboxPath, to: revision)
      print("Restored \(restored.name) to rev \(restored.rev.rawValue).")
    }
  }

  /// The revision to restore: the one named on the command line, or the one
  /// the user picks. `nil` means they declined to pick.
  private func chosenRevision(
    of path: DropboxPath,
    in session: AccountSession
  ) async throws -> FileRevision? {
    if let rev { return try FileRevision(validating: rev) }
    guard Output.isInteractive else {
      throw ValidationError("Pass --rev: there is no terminal to choose a revision on.")
    }
    let revisions = try await session.revisions(
      of: await CLI.fileSpecifier(for: path, in: session),
      limit: Self.pickerDepth
    )
    guard !revisions.isEmpty else {
      throw ValidationError("\(path.rawValue) has no stored revisions.")
    }
    return Self.pick(from: revisions, of: path)
  }
}
