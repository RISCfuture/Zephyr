import AppKit
import ArgumentParser
import Foundation

struct GUICommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "gui",
    abstract: "Open the Zephyr app."
  )

  private static let applicationBundleIdentifier = "codes.tim.Zephyr"

  /// The app bundle this tool ships inside, when it does.
  ///
  /// A copy installed on its own — in `/usr/local/bin`, say — has no
  /// containing bundle, so the search walks off the top and finds nothing.
  private static func containingApplication() -> URL? {
    var directory = Bundle.main.bundleURL
    while directory.pathComponents.count > 1 {
      if directory.pathExtension == "app" { return directory }
      directory.deleteLastPathComponent()
    }
    return nil
  }

  /// Where the app is: alongside this tool if it ships in the bundle, and
  /// otherwise wherever Launch Services has registered it.
  private static func applicationURL() throws -> URL {
    if let bundled = containingApplication() { return bundled }
    guard
      let registered = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: applicationBundleIdentifier
      )
    else { throw CLIFailure.applicationNotInstalled }
    return registered
  }

  func run() async {
    await CLI.run {
      let application = try Self.applicationURL()
      let configuration = NSWorkspace.OpenConfiguration()
      configuration.activates = true
      _ = try await NSWorkspace.shared.openApplication(
        at: application,
        configuration: configuration
      )
    }
  }
}
