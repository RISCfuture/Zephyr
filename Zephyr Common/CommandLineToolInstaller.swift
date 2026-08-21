import AppKit
import Foundation
import Security
import libZephyr

/**
 Installs the bundled `zephyr` command-line tool by symlinking it into
 `/usr/local/bin`, using the system's symlink authorization so the app never
 needs raw write access there.

 That authorization is not always to be had — see ``canInstall`` — so callers
 ask before offering ``install()``, and fall back to ``manualInstallCommand``.
 */
enum CommandLineToolInstaller {
  /// Where the symlink is created.
  static let installedURL = URL(fileURLWithPath: "/usr/local/bin/zephyr")

  /// The entitlement that puts a build inside the App Sandbox.
  private static let appSandbox = "com.apple.security.app-sandbox"

  /// The entitlement, granted by Apple on request, that lets a sandboxed build
  /// obtain the authorization rights behind `FileManager(authorization:)`.
  private static let privilegedFileOperations =
    "com.apple.developer.security.privileged-file-operations"

  /**
   Whether macOS will let Zephyr lay the link down itself.

   Linking into `/usr/local/bin` goes through an authorization right the App
   Sandbox hands out only to a build entitled for privileged file operations.
   Withheld, it is withheld silently: the request never prompts, and the link
   fails afterwards as an ordinary permission error. A button that cannot
   succeed is worse than no button, so ``install()`` is offered only where the
   right can be had — which a build outside the sandbox always can.
   */
  static let canInstall = !hasEntitlement(appSandbox) || hasEntitlement(privilegedFileOperations)

  /**
   The bundled tool to link to, or `nil` in builds that omit it.

   Whether a tool is there at all is asked of the running copy, which is
   readable wherever macOS decided to run it from; the path handed back is the
   durable one. Under translocation those are one file reached two ways, and
   only the second way is still a file tomorrow.
   */
  static var bundledToolURL: URL? {
    let running = toolURL(inBundleAt: Bundle.main.bundleURL)
    guard FileManager.default.fileExists(atPath: running.path) else { return nil }
    return toolURL(inBundleAt: InstallLocation.applicationURL)
  }

  /// Whether `/usr/local/bin/zephyr` already points at this app's bundled tool.
  static var isInstalled: Bool {
    guard
      let destination = try? FileManager.default
        .destinationOfSymbolicLink(atPath: installedURL.path)
    else { return false }
    return destination == bundledToolURL?.path
  }

  /// The shell command for installing by hand, shown when authorization fails.
  static var manualInstallCommand: String {
    "sudo ln -sf \"\(bundledToolURL?.path ?? "")\" \(installedURL.path)"
  }

  /// Whether the running build's signature carries `name` as a true flag.
  private static func hasEntitlement(_ name: String) -> Bool {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode
    else { return false }
    var information: CFDictionary?
    guard
      SecCodeCopySigningInformation(
        staticCode,
        SecCSFlags(rawValue: kSecCSSigningInformation),
        &information
      ) == errSecSuccess,
      let entitlements = (information as? [String: Any])?["entitlements-dict"] as? [String: Any]
    else { return false }
    return entitlements[name] as? Bool ?? false
  }

  /// Where the command-line tool sits inside an app bundle.
  private static func toolURL(inBundleAt bundle: URL) -> URL {
    bundle.appending(components: "Contents", "Helpers", "zephyr-cli")
  }

  /**
   Creates the symlink after the user authorizes it in the system dialog.

   - Throws: when no tool is bundled, the user declines, or the link fails.
   */
  static func install() async throws {
    guard let bundledToolURL else {
      throw InstallationFailure.toolNotBundled
    }
    let authorization = try await NSWorkspace.shared.requestAuthorization(to: .createSymbolicLink)
    let fileManager = FileManager(authorization: authorization)
    try? fileManager.removeItem(at: installedURL)
    try fileManager.createSymbolicLink(at: installedURL, withDestinationURL: bundledToolURL)
  }

  /// Why installing the command-line tool failed.
  enum InstallationFailure: Error, LocalizedError {
    case toolNotBundled

    var errorDescription: String? {
      String(localized: "Couldn’t install the command-line tool.", bundle: #bundle)
    }

    var failureReason: String? {
      String(
        localized: "This build of Zephyr doesn’t include the zephyr command-line tool.",
        bundle: #bundle
      )
    }

    var helpAnchor: String? { HelpAnchor.commandLineToolInstall.rawValue }
  }
}
