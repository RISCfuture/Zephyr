import AppIntents
import Foundation
import libZephyr

/**
 Stops or starts syncing for every linked account, the way the menu bar item's
 own Pause Syncing row does.

 Zephyr offers the same verb in three places, and they are deliberately not the
 same type. This is the one a shortcut reaches for, so it takes a
 ``SyncPauseAction`` and can toggle without being told which way. Control
 Center's toggle hands WidgetKit a boolean instead, which is
 `SetSyncPausedIntent`. Both end up in `DomainConnection`.
 */
public struct PauseSyncingIntent: AppIntent {
  /// The name Shortcuts lists this action under.
  public static let title = LocalizedStringResource(
    "Pause or Resume Syncing",
    bundle: .zephyrCommon
  )

  // periphery:ignore - App Intents reads this out of the extracted metadata; it has a
  // default, so nothing in Zephyr calls it and the dead-code check can't see the system.
  /// What the action does, shown beneath its name.
  public static let description = IntentDescription(
    LocalizedStringResource(
      "Stops or starts syncing for every Dropbox account Zephyr is keeping in Finder.",
      bundle: .zephyrCommon
    )
  )

  /// Nothing here needs a window, and Zephyr has no Dock icon to come forward
  /// to: a shortcut that paused syncing by activating the app would be taking
  /// the foreground away from whatever the reader was doing.
  public static let supportedModes: IntentModes = .background

  /// Whether to pause, resume, or flip whichever way syncing is now.
  @Parameter(title: LocalizedStringResource("Action", bundle: .zephyrCommon))
  public var action: SyncPauseAction

  public init() {}

  /// What the shortcut says it did.
  private static func dialog(isPaused: Bool) -> IntentDialog {
    isPaused
      ? IntentDialog(LocalizedStringResource("Syncing is paused.", bundle: .zephyrCommon))
      : IntentDialog(LocalizedStringResource("Syncing is running.", bundle: .zephyrCommon))
  }

  /// Pauses or resumes every domain, and reports where syncing ended up.
  public func perform() async throws -> some IntentResult & ReturnsValue<Bool> & ProvidesDialog {
    let isPaused = try await withIntentFailures {
      // A Mac with no domain registered is neither paused nor running, and
      // `areAllDisconnected()` calls that not-paused. Left alone, pausing
      // would report syncing as running when there is no syncing at all.
      guard await DomainConnection.hasRegisteredDomains() else {
        throw ScriptingFailure.noSyncingToPause
      }
      let wasPaused = await DomainConnection.areAllDisconnected()
      if action.pausing(whenPaused: wasPaused) {
        try await DomainConnection.disconnectAll()
      } else {
        try await DomainConnection.reconnectAll()
      }
      return await DomainConnection.areAllDisconnected()
    }
    ChangeSignal.syncPaused.post()
    return .result(value: isPaused, dialog: Self.dialog(isPaused: isPaused))
  }
}

/// What a shortcut asks ``PauseSyncingIntent`` to do.
public enum SyncPauseAction: String, AppEnum {
  /// Stop syncing, whatever it is doing now.
  case pause

  /// Start syncing again, whatever it is doing now.
  case resume

  /// Stop syncing if it is running, and start it if it is paused.
  case toggle

  /// The name Shortcuts gives this choice.
  public static let typeDisplayRepresentation = TypeDisplayRepresentation(
    name: LocalizedStringResource("Syncing Action", bundle: .zephyrCommon)
  )

  /// How each choice reads in the picker.
  public static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
    .pause: DisplayRepresentation(title: LocalizedStringResource("Pause", bundle: .zephyrCommon)),
    .resume: DisplayRepresentation(title: LocalizedStringResource("Resume", bundle: .zephyrCommon)),
    .toggle: DisplayRepresentation(title: LocalizedStringResource("Toggle", bundle: .zephyrCommon))
  ]

  /// Whether syncing should end up paused, given where it is now.
  public func pausing(whenPaused isPaused: Bool) -> Bool {
    switch self {
      case .pause: true
      case .resume: false
      case .toggle: !isPaused
    }
  }
}
