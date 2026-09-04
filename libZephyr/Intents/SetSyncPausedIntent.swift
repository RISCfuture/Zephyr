public import AppIntents
import Foundation

/**
 Pauses or resumes syncing for every linked account, as a plain boolean.

 This is what Control Center's toggle runs: `ControlWidgetToggle` requires a
 `SetValueIntent` whose value is a `Bool`, and hands it the state the switch was
 moved to. The Shortcuts action is `PauseSyncingIntent` instead, which takes
 pause, resume, or toggle and so can flip syncing without being told which way
 it is now.

 Both are the same verb, so only one of them belongs in a shortcut's action
 list; this is the one that stays out of it.
 */
public struct SetSyncPausedIntent: SetValueIntent {
  /// The kind naming Zephyr's Control Center toggle to WidgetKit. The widget
  /// declares the control under it, and the app reloads the control by it after
  /// pausing from the menu bar.
  public static let controlKind = "codes.tim.Zephyr.PauseSyncingControl"

  /// What the toggle is called where controls are chosen.
  public static let title = LocalizedStringResource("Pause Syncing", bundle: .libZephyr)

  /// Nothing here needs a window, and a toggle that brought Zephyr forward
  /// would be taking the foreground away from whatever the reader was doing.
  public static let supportedModes: IntentModes = .background

  /// `PauseSyncingIntent` is the pause a shortcut lists. Offering this one
  /// beside it would put two actions for one verb in the same library.
  public static let isDiscoverable = false

  /// Whether syncing should end up paused.
  @Parameter(title: LocalizedStringResource("Paused", bundle: .libZephyr))
  public var value: Bool

  public init() {}

  /// Pauses or resumes every domain, and tells the other processes.
  public func perform() async throws -> some IntentResult {
    try await withIntentFailures {
      // A Mac with no domain registered has no syncing to pause, which is not
      // the same as syncing that is running — and is what a toggle offered
      // before Finder was ever set up would otherwise silently do nothing to.
      guard await DomainConnection.hasRegisteredDomains() else {
        throw ScriptingFailure.noSyncingToPause
      }
      if value {
        try await DomainConnection.disconnectAll()
      } else {
        try await DomainConnection.reconnectAll()
      }
    }
    ChangeSignal.syncPaused.post()
    return .result()
  }
}
