import Foundation
import Sentry
import os

/**
 Crash and error reporting for a shipped launch.

 Zephyr runs as six processes — the app, the File Provider extension, the File
 Provider UI extension, the Share extension, the widget, and `zephyr` — and
 each starts reporting for itself, tagged with which one it is. Four of them
 are hosted out of the user's sight, by `fileproviderd`, by the Finder, by the
 share sheet, and by WidgetKit; when one of those dies there is no window to
 show it and nobody who would think to report it. This is the only account of
 it that reaches anyone.

 What goes out is what Zephyr's privacy policy describes and nothing else:
 `sendDefaultPii` stays off, so the SDK attaches no IP address, device name, or
 account name, and every string is put through `ReportRedaction` on the way
 out, so no path, file name, or credential leaves the Mac. The only thing about
 the user that a report carries is `installationIdentifier`.

 There is deliberately no `edition` tag. Zephyr's two editions ship under one
 bundle identifier and embed the same four extensions built once, so an
 extension could not answer which one it is running inside; the component is
 the axis a crash here actually differs along.
 */
public enum CrashReporting {

  /// The Zephyr project in the `timcodes` Sentry organization. A DSN is a
  /// write-only address rather than a credential — it is readable in every
  /// copy of the app, and all it authorizes is sending an event.
  private static let dsn =
    "https://22bafef514d62f4eaaf59e59329a2ba6@o4510156629475328.ingest.us.sentry.io/4511968263798784"

  /// How much of a long-lived process's work is traced and profiled. A fifth
  /// is enough to see where time goes across a user base and cheap enough to
  /// leave on in a sync client that runs all day.
  private static let performanceSampleRate: Float = 0.2

  /**
   Whether this call is the first in its process.

   The File Provider extension builds one `FileProviderExtension` per linked
   domain inside one process, so `start` is reached once per account.
   `SentrySDK.start` tears down whatever client is already running and replaces
   it, losing anything it had not yet sent.
   */
  private static let hasStarted = OSAllocatedUnfairLock(initialState: false)

  /**
   Whether a launch of this build reports at all.

   Only a release build does. Every other way Zephyr runs is a Debug build —
   the SwiftUI previews, the unit tests, and the UI test suite all build Debug
   — and none of them has telemetry worth sending. A debugger also parks the
   main thread long enough to trip the app-hang watchdog, so a development run
   would report hangs that no user could ever experience.
   */
  private static var reports: Bool {
    #if DEBUG
      false
    #else
      true
    #endif
  }

  /**
   The identifier repeated reports from this Mac are attributed to, and the
   only thing about the user a report carries.

   Generated on first need and kept beside the sync index in the app group
   container, so that all five processes report as one installation and
   deleting the container forgets it. Nothing about it derives from the Dropbox
   account, the Apple Account, or any hardware serial number.

   `nil` when this process has no app group container, which means a build
   signed without entitlements — one that never reports anyway.
   */
  private static var installationIdentifier: String? {
    guard let environment = ZephyrEnvironment.shared else { return nil }
    if let stored = storedIdentifier(at: environment.installationIdentifierURL) { return stored }

    try? FileManager.default.createDirectory(
      at: environment.baseDirectory,
      withIntermediateDirectories: true
    )
    let minted = UUID().uuidString
    do {
      // Refusing to overwrite settles a race between two Zephyr processes
      // launching at once: the loser reads the winner's identifier back rather
      // than replacing it, and both go on reporting as one installation.
      try Data(minted.utf8).write(
        to: environment.installationIdentifierURL,
        options: .withoutOverwriting
      )
      return minted
    } catch {
      return storedIdentifier(at: environment.installationIdentifierURL)
    }
  }

  /**
   Starts reporting for this process.

   Safe to call more than once; only the first call in a process starts
   anything.

   - Parameter component: Which Zephyr process this is. Every event it sends
     carries it as the `component` tag.
   */
  public static func start(as component: Component) {
    guard reports, claimTheOneStart() else { return }

    SentrySDK.start { options in configure(options, for: component) }
    SentrySDK.configureScope { scope in
      scope.setTag(value: component.rawValue, key: "component")
      if let installationIdentifier { scope.setUser(User(userId: installationIdentifier)) }
    }
  }

  /// Whether this call won the right to start the SDK.
  private static func claimTheOneStart() -> Bool {
    hasStarted.withLock { started in
      defer { started = true }
      return !started
    }
  }

  /// The identifier already on disk, if there is a usable one.
  private static func storedIdentifier(at url: URL) -> String? {
    guard let stored = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func configure(_ options: Sentry.Options, for component: Component) {
    options.dsn = dsn

    // The SDK's own diagnostics belong in development, not in a shipped
    // process's console.
    options.debug = false

    // Zephyr has no accounts, and its privacy policy promises that reports are
    // not linked to identity — so never let the SDK attach the IP address,
    // device name, or account name it would otherwise infer.
    options.sendDefaultPii = false

    options.beforeSend = { ReportRedaction.redacting($0) }
    options.beforeBreadcrumb = { ReportRedaction.redacting($0) }

    guard component.runsForLong else {
      // A share sheet, a widget refresh, and a `zephyr` invocation are over in
      // seconds. Profiling one costs more than the spans would say, and a
      // session counted per widget refresh would make the session count mean
      // nothing at all.
      options.enableAutoSessionTracking = false
      options.enableAppHangTracking = false
      return
    }

    options.tracesSampleRate = NSNumber(value: performanceSampleRate)
    options.configureProfiling = {
      $0.sessionSampleRate = performanceSampleRate
      $0.lifecycle = .trace
    }

    // The watchdog watches a main thread. The File Provider extension's is a
    // run loop waiting on `fileproviderd`, where a long wait is the job rather
    // than a fault.
    options.enableAppHangTracking = component == .app
  }
}

extension CrashReporting {
  /**
   Which Zephyr process a report came from.

   The six share one framework, one version, and one bundle identifier, and a
   crash in the code they have in common looks alike from all of them. This is
   what tells them apart.
   */
  public enum Component: String, Sendable {
    /// The menu bar app.
    case app

    /// The File Provider extension, which is where syncing happens.
    case fileProvider = "file_provider"

    /// The File Provider UI extension's version-history sheet.
    case fileProviderUI = "file_provider_ui"

    /// The Share extension's upload sheet.
    case shareExtension = "share_extension"

    /// The widget's timeline provider.
    case widget

    /// The `zephyr` command-line tool.
    case commandLineTool = "command_line_tool"

    /// Whether the process lives long enough for tracing and profiling to
    /// describe anything.
    fileprivate var runsForLong: Bool {
      switch self {
        case .app, .fileProvider: true
        case .fileProviderUI, .shareExtension, .widget, .commandLineTool: false
      }
    }
  }
}
