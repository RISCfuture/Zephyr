import ArgumentParser
import Foundation
import libZephyr

/// What kind of item a search asks for, and what it reports having found.
enum FindItemKind: String, CaseIterable, ExpressibleByArgument, Encodable {
  case file

  case folder

  case symlink

  /// The indexed kind this names.
  var indexItemType: IndexItemType {
    switch self {
      case .file: .file
      case .folder: .folder
      case .symlink: .symlink
    }
  }

  init(_ itemType: IndexItemType) {
    switch itemType {
      case .file: self = .file
      case .folder: self = .folder
      case .symlink: self = .symlink
    }
  }
}

struct FindCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "find",
    abstract: "Find items anywhere in the account, by name or by what they are.",
    discussion: """
      The answer comes from the sync index, which describes the whole Dropbox rather than the part \
      of it whose contents are on this Mac — so a file nothing has ever downloaded is found \
      exactly like one that is fully materialized, and finding it costs no network at all. That is \
      the thing Spotlight and Finder’s own search box cannot do inside a File Provider folder.

      Text matches an item’s own name rather than its whole path: searching for “Budget” and \
      getting every file inside a folder called Budget would bury the one file you were looking \
      for. Case does not matter, and neither does whether an accent arrived composed or decomposed \
      — but an accent itself counts, so “resume” does not find “Résumé”, the same way it does not \
      in Dropbox. “%” and “_” are matched literally.

      Results come back best match first: an exact name, then a name that starts with the text, \
      then a name that merely contains it, with shallower paths ahead of deeper ones.

      Sizes are powers of 1024 and may be spelled “4096”, “500K”, “10M”, or “2G”. Spans are a \
      number and a unit, like “90s”, “30m”, “4h”, or “7d”, and are measured against the item’s \
      modification date. Folders carry no size, so a size bound leaves them out — and Dropbox \
      reports no modification date for one either, so the index stamps a folder with the date it \
      first saw it. A span matched against a folder says when Zephyr indexed it, not when anything \
      inside it changed.
      """
  )

  @Argument(help: "Text an item’s name must contain.")
  var text: String?

  @Option(help: "Restrict to a folder and everything beneath it.", completion: .dropboxFolder)
  var under: String?

  @Option(help: "Restrict to a kind of item. Repeat to allow more than one.")
  var type: [FindItemKind] = []

  @Option(help: "Restrict to items at least this large.")
  var minSize: ByteSize?

  @Option(help: "Restrict to items no larger than this.")
  var maxSize: ByteSize?

  @Option(help: "Restrict to items modified within this span.")
  var newerThan: CommandDuration?

  @Option(help: "Restrict to items not modified for at least this span.")
  var olderThan: CommandDuration?

  @Flag(help: "Include items excluded from syncing.")
  var includeExcluded = false

  @Option(name: [.short, .customLong("limit")], help: "How many items to show.")
  var limit: UInt = 50

  @Flag(help: "Emit JSON.")
  var json = false

  @OptionGroup var accountOptions: AccountOptions

  /// Whether the command line narrows the account at all. Answering with the
  /// first fifty items of a Dropbox is not what anyone meant by “find”.
  private var narrowsTheAccount: Bool {
    text?.isEmpty == false || under != nil || !type.isEmpty || minSize != nil || maxSize != nil
      || newerThan != nil || olderThan != nil
  }

  private static func render(_ items: [Item]) {
    guard !items.isEmpty else {
      print("Nothing in the sync index matches.")
      return
    }
    Output.table(
      [["PATH", "KIND", "SIZE", "MODIFIED"]]
        + items.map { item in
          [item.path, item.kind.rawValue, Output.bytes(item.size), Output.date(item.modified)]
        }
    )
  }

  func run() async {
    await CLI.run {
      guard limit >= 1 else { throw ValidationError("--limit must be at least 1.") }
      guard narrowsTheAccount else {
        throw ValidationError(
          """
          Give something to search for: text to match, or one of --under, --type, --min-size, \
          --max-size, --newer-than, or --older-than.
          """
        )
      }
      let session = try await CLI.session(account: accountOptions.account)
      let found = try await matches(in: session)
      if json { try Output.json(found) } else { Self.render(found) }
    }
  }

  /// What the index matches, or nothing at all when there is no index yet.
  private func matches(in session: AccountSession) async throws -> [Item] {
    guard session.indexExists else { return [] }
    let index = try await session.openIndex(mode: .readOnly)
    return try await index.items(matching: try query()).map(Item.init)
  }

  /// The command line as the index understands it.
  private func query() throws -> IndexQuery {
    let now = Date()
    return IndexQuery(
      nameContains: text,
      subtree: try under.map { try CLI.dropboxPath($0).normalized },
      itemTypes: type.isEmpty ? nil : Set(type.map(\.indexItemType)),
      minimumSize: minSize?.bytes,
      maximumSize: maxSize?.bytes,
      modifiedAfter: newerThan.map { now.addingTimeInterval(-TimeInterval($0.seconds)) },
      modifiedBefore: olderThan.map { now.addingTimeInterval(-TimeInterval($0.seconds)) },
      includesExcluded: includeExcluded,
      limit: limit
    )
  }

  /// One found item as the CLI reports it (also the `--json` shape).
  private struct Item: Encodable {
    let path: String
    let kind: FindItemKind
    let size: UInt64?
    let modified: Date?
    let excluded: Bool

    init(_ entry: IndexEntryRecord) {
      path = entry.pathCased.rawValue
      kind = FindItemKind(entry.itemType)
      size = entry.size
      modified = entry.clientModified
      excluded = entry.ignored
    }
  }
}
