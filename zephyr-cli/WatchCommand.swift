import ArgumentParser
import Foundation
import libZephyr

struct WatchCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "watch",
    abstract: "Mirror the account’s change feed into the sync index, printing changes live."
  )

  @OptionGroup var accountOptions: AccountOptions

  private static func timestamp() -> String {
    Date().formatted(date: .omitted, time: .standard)
  }

  private static func describe(_ entry: ItemMetadata) -> String {
    switch entry {
      case .file(let file):
        "~ \(file.pathDisplay?.rawValue ?? file.name) (\(Output.bytes(file.size)), rev \(file.rev.rawValue))"
      case .folder(let folder):
        "+ \(folder.pathDisplay?.rawValue ?? folder.name)/"
      case .deleted(let deleted):
        "- \(deleted.pathDisplay?.rawValue ?? deleted.name)"
    }
  }

  func run() async {
    await CLI.run {
      let session = try await CLI.session(account: accountOptions.account)
      let indexer = try await session.makeIndexer()
      print("Catching up with remote state…")
      try await indexer.catchUp()
      let index = try await session.openIndex(mode: .readOnly)
      let counts = try await index.counts()
      print(
        "Index has \(counts.files) files and \(counts.folders) folders. Watching (Ctrl-C to stop)…"
      )
      try await indexer.watch { entries in
        for entry in entries {
          print("\(Self.timestamp())  \(Self.describe(entry))")
        }
      }
    }
  }
}
