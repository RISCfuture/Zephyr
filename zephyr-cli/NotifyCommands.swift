public import ArgumentParser
import Foundation
public import libZephyr

// `NotificationLevel` is Zephyr's, `ExpressibleByArgument` is ArgumentParser's,
// and this tool is the only place the two meet.
extension NotificationLevel: @retroactive ExpressibleByArgument {
  public static var allValueStrings: [String] { allCases.map(\.name) }

  public init?(argument: String) {
    self.init(name: argument)
  }
}

struct NotifyCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "notify",
    abstract: "Show or change Zephyr’s notification settings.",
    discussion: """
      These settings belong to the Mac rather than to one account: the app, the File Provider \
      extension, and this tool all read them from the shared app group, so a change here shows up \
      in the app immediately.
      """,
    subcommands: [Level.self, Snooze.self]
  )

  struct Level: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Show or set which events are worth a notification.",
      discussion: """
        Levels run from the most talkative to the least: file-changes, sync-issues, errors, none. \
        An event notifies when it is at or above the level you set.
        """
    )

    @Argument(help: "The level to set. Omit it to print the current level.")
    var level: NotificationLevel?

    func run() async {
      await CLI.run {
        var settings = NotificationSettings.load()
        guard let level else {
          print(settings.level.name)
          return
        }
        settings.level = level
        try settings.save()
        print("Notifying for: \(level.name).")
      }
    }
  }

  struct Snooze: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Silence notifications for a while.",
      discussion: """
        Snoozing suspends every notification, whatever the level, until the deadline passes. \
        Syncing itself carries on.
        """
    )

    @Argument(help: "How long to stay quiet: 30m, 4h, 1d. Omit it to print the deadline.")
    var duration: CommandDuration?

    @Flag(help: "End an active snooze now.")
    var cancel = false

    private static func deadline(_ snoozedUntil: Date?) -> String {
      guard let snoozedUntil else { return "not snoozed" }
      return "snoozed until \(Output.date(snoozedUntil))"
    }

    func run() async {
      await CLI.run {
        var settings = NotificationSettings.load()
        if cancel {
          guard duration == nil else {
            throw ValidationError("Pass a duration or --cancel, not both.")
          }
          settings.cancelSnooze()
          try settings.save()
          print("Notifications resumed.")
          return
        }
        guard let duration else {
          print(Self.deadline(settings.snoozedUntil))
          return
        }
        settings.snooze(for: duration.duration)
        try settings.save()
        print(Self.deadline(settings.snoozedUntil))
      }
    }
  }
}
