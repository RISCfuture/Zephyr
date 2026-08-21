import AppIntents
import Foundation
import libZephyr

/**
 Silences Zephyr's notifications for a while, or ends a snooze early.

 Nothing here needs the app: the deadline is a value in the shared container
 that every Zephyr process reads, so this is correct with the app closed and
 stays correct after it is opened again.

 It sits beside ``PauseSyncingIntent`` for company rather than necessity —
 `NotificationSettings` is in `libZephyr` and this would work equally well
 there. Only pausing genuinely has to be in this framework.
 */
public struct SnoozeNotificationsIntent: AppIntent {
  /// The name Shortcuts lists this action under.
  public static let title = LocalizedStringResource(
    "Snooze Zephyr Notifications",
    bundle: .zephyrCommon
  )

  // periphery:ignore - App Intents reads this out of the extracted metadata; it has a
  // default, so nothing in Zephyr calls it and the dead-code check can't see the system.
  /// What the action does, shown beneath its name.
  public static let description = IntentDescription(
    LocalizedStringResource(
      """
      Holds every Zephyr notification, including sync errors, until the snooze ends. Syncing \
      itself carries on.
      """,
      bundle: .zephyrCommon
    )
  )

  public static let supportedModes: IntentModes = .background

  /// How long to stay quiet.
  @Parameter(title: LocalizedStringResource("Duration", bundle: .zephyrCommon))
  public var duration: SnoozeDuration

  public init() {}

  /// What the shortcut says it did.
  private static func dialog(until deadline: Date?) -> IntentDialog {
    guard let deadline else {
      return IntentDialog(
        LocalizedStringResource("Zephyr notifications are on.", bundle: .zephyrCommon)
      )
    }
    return IntentDialog(
      LocalizedStringResource(
        "Zephyr notifications are snoozed until \(deadline, format: .dateTime.hour().minute()).",
        bundle: .zephyrCommon
      )
    )
  }

  // A snooze is one write to the shared container; App Intents declares
  // `perform()` async and there is nothing here to wait for.
  // swiftlint:disable async_without_await
  /// Starts or ends the snooze, and says when notifications come back.
  public func perform() async throws -> some IntentResult & ProvidesDialog {
    var settings = NotificationSettings.load()
    if let interval = duration.interval {
      settings.snooze(for: interval)
    } else {
      settings.cancelSnooze()
    }
    try settings.save()
    return .result(dialog: Self.dialog(until: settings.snoozedUntil))
  }
  // swiftlint:enable async_without_await
}

/**
 How long notifications stay quiet for.

 One list, read by both surfaces that offer a snooze: the menu bar panel's
 row of buttons and the shortcut's picker. Two lists would be two places for
 the offered windows to drift apart.
 */
public enum SnoozeDuration: String, AppEnum, CaseIterable, Identifiable {
  /// Half an hour.
  case thirtyMinutes

  /// One hour.
  case oneHour

  /// Eight hours.
  case eightHours

  /// Not at all: end a snooze already running.
  case off

  /// The windows of quiet, without the way out of one. The panel offers these
  /// as buttons and shows its own Resume separately; a shortcut has one
  /// parameter for both, so it keeps ``off``.
  public static let timed: [Self] = [.thirtyMinutes, .oneHour, .eightHours]

  /// The name Shortcuts gives this choice.
  public static let typeDisplayRepresentation = TypeDisplayRepresentation(
    name: LocalizedStringResource("Snooze Duration", bundle: .zephyrCommon)
  )

  /// How each choice reads in a shortcut's picker, which has room to spell
  /// the units out where the panel does not.
  public static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
    .thirtyMinutes: DisplayRepresentation(
      title: LocalizedStringResource("30 minutes", bundle: .zephyrCommon)
    ),
    .oneHour: DisplayRepresentation(
      title: LocalizedStringResource("1 hour", bundle: .zephyrCommon)
    ),
    .eightHours: DisplayRepresentation(
      title: LocalizedStringResource("8 hours", bundle: .zephyrCommon)
    ),
    .off: DisplayRepresentation(
      title: LocalizedStringResource("Turn snooze off", bundle: .zephyrCommon)
    )
  ]

  public var id: Self { self }

  /// How long this is, or `nil` for ending a snooze rather than starting one.
  public var interval: Duration? {
    switch self {
      case .thirtyMinutes: .seconds(30 * 60)
      case .oneHour: .seconds(60 * 60)
      case .eightHours: .seconds(8 * 60 * 60)
      case .off: nil
    }
  }

  /// How each choice reads on the menu bar panel, where the row is narrow.
  var label: LocalizedStringResource {
    switch self {
      case .thirtyMinutes: LocalizedStringResource("30 min", bundle: #bundle)
      case .oneHour: LocalizedStringResource("1 hr", bundle: #bundle)
      case .eightHours: LocalizedStringResource("8 hr", bundle: #bundle)
      case .off: LocalizedStringResource("Resume", bundle: #bundle)
    }
  }

  /// The choice's stable, unlocalized name, for the accessibility identifier a
  /// UI test would reach it by.
  var name: String {
    switch self {
      case .thirtyMinutes: "30m"
      case .oneHour: "1h"
      case .eightHours: "8h"
      case .off: "off"
    }
  }
}
