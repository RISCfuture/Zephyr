public import Foundation

/**
 How often Zephyr looks for a new release on its own.

 Mirrors the cadences the update checker supports. The framework keeps its own
 enum because the checker lives only in the downloadable build: the shared UI
 cannot name the library's type, and a local enum also lets the picker's labels
 go through the String Catalog.
 */
public enum UpdateCheckCadence: String, CaseIterable, Identifiable, Sendable {
  case hourly
  case daily
  case weekly
  case never

  public var id: Self { self }

  /// The picker label for this cadence.
  public var label: String {
    switch self {
      case .hourly: String(localized: "Hourly", bundle: #bundle)
      case .daily: String(localized: "Daily", bundle: #bundle)
      case .weekly: String(localized: "Weekly", bundle: #bundle)
      case .never: String(localized: "Never", bundle: #bundle)
    }
  }
}

/**
 Zephyr's ability to check for a newer release, and the preferences governing it.

 Only the downloadable build can update itself, so `AppModel.updates` is `nil`
 in the App Store build — as it is in previews and UI tests. The shared menu item
 and Settings section appear only when it is non-`nil`, which keeps the update
 library out of the App Store binary entirely.

 Conformers forward to observable storage, so SwiftUI tracks these properties
 through the existential the same way it would the underlying object.
 */
@MainActor
public protocol UpdateChecking: AnyObject {

  /// Whether a check can start now; `false` while one is already running.
  var canCheckForUpdates: Bool { get }

  /// When the last check finished, or `nil` if none has run.
  var lastCheckDate: Date? { get }

  /// How often Zephyr checks on its own.
  var cadence: UpdateCheckCadence { get set }

  /**
   Checks for a newer release and presents the result — the update offer, a
   confirmation that Zephyr is current, or an error.
   */
  func checkForUpdatesAndShowUI() async
}
