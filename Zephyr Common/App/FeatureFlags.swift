import Foundation

/**
 What this build of Zephyr is allowed to do.

 The two editions share every line of their interface; they differ only in the
 dependencies their entry point injects. App Store policy forbids an app both
 updating itself and installing a tool onto the user's `PATH`, so the App Store
 build ships without either and the shared UI points at the downloadable build
 instead.
 */
public struct FeatureFlags: Sendable {
  /// The project's site.
  public static let websiteURL = URL(string: "https://riscfuture.github.io/Zephyr/")!

  /// What Zephyr sends and what it keeps — the only account of it the running
  /// app gives.
  public static let privacyURL = URL(string: "https://riscfuture.github.io/Zephyr/privacy.html")!

  /// Where to report a problem.
  public static let issuesURL = URL(string: "https://github.com/RISCfuture/Zephyr/issues")!

  /**
   Whether this is the sandboxed Mac App Store build.

   Set by the edition's entry point. The shared UI reads it to disable the
   controls that edition cannot offer and explain where they went.
   */
  public var isAppStoreBuild: Bool

  /// The running version, as `CFBundleShortVersionString` reports it.
  public var version: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
  }

  /**
   Creates the flags for one edition.

   - Parameter isAppStoreBuild: Whether this is the sandboxed Mac App Store build.
   */
  public init(isAppStoreBuild: Bool) {
    self.isAppStoreBuild = isAppStoreBuild
  }
}
