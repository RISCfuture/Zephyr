import ArgumentParser
import Foundation
import libZephyr

struct IgnoredCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "ignored",
    abstract: "Inspect the items excluded from syncing.",
    discussion: """
      Excluding an item deletes Dropbox’s copy and keeps this Mac’s, so a listing of the account — \
      “zephyr ls” — cannot show excluded items even in principle: as far as Dropbox is concerned \
      they are gone. The sync index is the only record that they exist.

      Exclude and resume an item from Finder, through the item’s Quick Actions; the File Provider \
      extension owns those transfers.
      """,
    subcommands: [List.self],
    defaultSubcommand: List.self
  )

  struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "List the items excluded from syncing, in path order."
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
        let entries = try await excluded(in: session)
        guard !json else {
          try Output.json(entries)
          return
        }
        guard !entries.isEmpty else {
          print("Nothing is excluded from syncing.")
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

    /// The excluded items, or none at all when the index has yet to be built.
    private func excluded(in session: AccountSession) async throws -> [Entry] {
      guard session.indexExists else { return [] }
      return try await session.openIndex(mode: .readOnly).ignoredEntries().map(Self.listed)
    }

    /// One excluded item as the CLI reports it (also the `--json` shape).
    private struct Entry: Encodable {
      let path: String
      let kind: Kind
      let size: UInt64?
      let modified: Date?

      /// What an excluded item is.
      enum Kind: String, Encodable {
        /// A file.
        case file

        /// A folder, excluded along with everything beneath it.
        case folder

        /// A symbolic link.
        case symlink
      }
    }
  }
}
