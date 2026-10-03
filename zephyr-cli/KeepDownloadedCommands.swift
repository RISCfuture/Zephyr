import ArgumentParser
import Foundation
import libZephyr

struct KeepDownloadedCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "keep-downloaded",
    abstract: "Inspect the items pinned to this Mac.",
    discussion: """
      A pinned item downloads as soon as Dropbox offers it, stays downloaded as remote changes \
      arrive, and is never evicted to reclaim space. Dropbox keeps no record of any of that, so \
      the sync index is the only place a pin is written down.

      Pin and unpin an item from Finder, through the item’s Quick Actions; the File Provider \
      extension owns those transfers.
      """,
    subcommands: [List.self],
    defaultSubcommand: List.self
  )

  struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "List the items pinned to this Mac, in path order."
    )

    @Flag(help: "Emit JSON.")
    var json = false

    @OptionGroup var accountOptions: AccountOptions

    private static func listed(_ entry: IndexEntryRecord) -> Entry {
      Entry(
        path: entry.pathCased.rawValue,
        kind: kind(of: entry.itemType),
        size: entry.size,
        modified: entry.clientModified
      )
    }

    private static func kind(of itemType: IndexItemType) -> Entry.Kind {
      switch itemType {
        case .file: .file
        case .folder: .folder
        case .symlink: .symlink
      }
    }

    func run() async {
      await CLI.run {
        let session = try await CLI.session(account: accountOptions.account)
        let entries = try await pinned(in: session)
        guard !json else {
          try Output.json(entries)
          return
        }
        guard !entries.isEmpty else {
          print("Nothing is pinned to this Mac.")
          return
        }
        Output.table(
          [["PATH", "KIND", "SIZE"]]
            + entries.map { entry in
              [entry.path, entry.kind.rawValue, Output.bytes(entry.size)]
            }
        )
      }
    }

    /// The pinned items, or none at all when the index has yet to be built.
    private func pinned(in session: AccountSession) async throws -> [Entry] {
      guard session.indexExists else { return [] }
      return try await session.openIndex(mode: .readOnly).keepDownloadedEntries().map(Self.listed)
    }

    /// One pinned item as the CLI reports it (also the `--json` shape).
    private struct Entry: Encodable {
      let path: String
      let kind: Kind
      let size: UInt64?
      let modified: Date?

      /// What a pinned item is.
      enum Kind: String, Encodable {
        /// A file.
        case file

        /// A folder, pinned along with everything beneath it.
        case folder

        /// A symbolic link.
        case symlink
      }
    }
  }
}
