import AppKit
import Foundation

/**
 Where Zephyr is installed, and whether macOS is running it from there.

 The two are not always the same place. Gatekeeper runs a quarantined app from
 a read-only copy of its own making, and a copy that macOS throws away is the
 wrong thing to point a symlink at, register an extension from, or name in an
 instruction to the user.
 */
enum InstallLocation {
  /// The directory macOS mounts a translocated copy under.
  private static let translocationDirectory = "AppTranslocation"

  /**
   Where Zephyr is installed, which is not always where it is running from.

   An app dragged out of a downloaded disk image carries a quarantine flag, and
   macOS runs a quarantined app from a read-only copy under a temporary
   `AppTranslocation` mount instead of from the folder the user put it in. The
   mount is not the app's address: it is discarded once nothing is using it and
   may be remade under a different name. Anything meant to outlive the process
   is built from the location Launch Services keeps — the one the user can
   point at.
   */
  static var applicationURL: URL {
    guard let bundleIdentifier = Bundle.main.bundleIdentifier,
      let registered = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: bundleIdentifier
      )
    else { return Bundle.main.bundleURL }
    return registered
  }

  /**
   Whether macOS is running Zephyr from a throwaway copy instead of from where
   it is installed.

   This is not cosmetic. macOS refuses to run a File Provider extension for a
   translocated process at all — `com.apple.FileProvider` says so in the log,
   and `NSFileProviderManager.add(domain:)` fails — so a translocated Zephyr
   can never put a Dropbox in Finder, however long it is left to try.

   The path is the only public sign of it: `SecTranslocate` ships no SDK
   header, and nothing else about the process gives it away.
   */
  static var isTranslocated: Bool {
    Bundle.main.bundleURL.pathComponents.contains(translocationDirectory)
  }
}
