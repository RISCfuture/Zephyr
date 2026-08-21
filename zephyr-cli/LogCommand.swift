import ArgumentParser
import Foundation
import libZephyr

// `ZephyrLog.Category` is Zephyr's, `ExpressibleByArgument` is ArgumentParser's,
// and this tool is the only place the two meet.
extension ZephyrLog.Category: @retroactive ExpressibleByArgument {}

struct LogCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "log",
    abstract: "Read Zephyr’s messages from the unified log.",
    subcommands: [Show.self],
    defaultSubcommand: Show.self
  )

  struct Show: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Show recent messages from every Zephyr process.",
      discussion: """
        The app, the File Provider extension, the share extension, the widget, and this tool each \
        run in their own process; the unified log is the one place their behavior correlates. This \
        command is “log show” with the predicate already written.

        Paths, file names, and account details are logged privately, so a stranger reading a \
        sysdiagnose cannot read your Dropbox. That redaction applies to you too: until you lift it \
        on this Mac, those values print as <private>:

            sudo log config --mode "private_data:on" --subsystem \(ZephyrLog.subsystem)

        Put it back with private_data:off when you are done. The same command takes level:debug to \
        have macOS keep Zephyr’s debug messages, which it otherwise discards within moments.

        Zephyr writes no log file of its own; the unified log’s classification is what keeps a \
        captured diagnostic from carrying your file names.
        """
    )

    private static let executable = URL(fileURLWithPath: "/usr/bin/log")

    @Option(
      name: [.customLong("last")],
      help: "How far back to look, as a count and a unit: 30m, 4h, 2d."
    )
    var last = CommandDuration.hour

    @Option(help: "Show only one category’s messages.")
    var category: ZephyrLog.Category?

    @Flag(help: "Emit JSON.")
    var json = false

    /// The `NSPredicate` that selects Zephyr's messages, and only Zephyr's.
    private static func predicate(category: ZephyrLog.Category?) -> String {
      let subsystem = "subsystem == \"\(ZephyrLog.subsystem)\""
      guard let category else { return subsystem }
      return "\(subsystem) && category == \"\(category.rawValue)\""
    }

    /// Runs `log`, letting it write straight to this tool's own streams.
    private static func showLog(_ arguments: [String]) async throws -> Int32 {
      let process = Process()
      process.executableURL = executable
      process.arguments = arguments
      return try await withCheckedThrowingContinuation { continuation in
        process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
        do {
          try process.run()
        } catch {
          process.terminationHandler = nil
          continuation.resume(throwing: error)
        }
      }
    }

    func run() async {
      await CLI.run {
        var arguments = [
          "show",
          "--predicate", Self.predicate(category: category),
          "--last", "\(last.wholeMinutes)m",
          "--info",
          "--debug"
        ]
        arguments += json ? ["--style", "json"] : ["--style", "compact"]
        let status = try await Self.showLog(arguments)
        guard status == 0 else { Foundation.exit(status) }
      }
    }
  }
}
