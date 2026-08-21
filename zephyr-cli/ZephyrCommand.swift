import ArgumentParser

@main
struct ZephyrCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "zephyr",
    abstract: "An open-source sync client for Dropbox.",
    discussion: """
      Shell completion is built in: “zephyr --generate-completion-script zsh” writes a script that \
      completes subcommands, options, linked accounts, and Dropbox paths. Bash and fish are \
      spelled the same way. Paths come from the sync index, so a folder whose contents are not on \
      this Mac completes as readily as one whose contents are.
      """,
    version: CLI.version,
    subcommands: [
      AuthCommand.self,
      ListCommand.self,
      GetCommand.self,
      PutCommand.self,
      RemoveCommand.self,
      MakeDirectoryCommand.self,
      MoveCommand.self,
      RevisionsCommand.self,
      RestoreCommand.self,
      DiffCommand.self,
      BandwidthLimitCommand.self,
      ShareLinkCommand.self,
      StatusCommand.self,
      FileStatusCommand.self,
      FindCommand.self,
      IgnoredCommand.self,
      HistoryCommand.self,
      RebuildIndexCommand.self,
      WatchCommand.self,
      NotifyCommand.self,
      LogCommand.self,
      GUICommand.self
    ]
  )
}
