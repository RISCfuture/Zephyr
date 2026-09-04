public import Foundation

/**
 Which sync events warrant a notification.

 Raw values mirror Maestral's levels, and an event notifies when its severity
 is at or above the configured level.
 */
public enum NotificationLevel: Int, Sendable, CaseIterable, Identifiable, Codable {
  case fileChanges = 15

  case syncIssues = 30

  case errors = 40

  case none = 100

  public var id: Int { rawValue }

  /// The level's name in the user's language, for a menu or a picker.
  public var label: String {
    switch self {
      case .fileChanges: String(localized: "All file changes", bundle: #bundle)
      case .syncIssues: String(localized: "Sync issues", bundle: #bundle)
      case .errors: String(localized: "Errors only", bundle: #bundle)
      case .none: String(localized: "None", bundle: #bundle)
    }
  }

  /// The level's stable, unlocalized name, as typed on the command line.
  public var name: String {
    switch self {
      case .fileChanges: "file-changes"
      case .syncIssues: "sync-issues"
      case .errors: "errors"
      case .none: "none"
    }
  }

  /// Creates a level from its ``name``, or `nil` when no level goes by it.
  public init?(name: String) {
    guard let level = Self.allCases.first(where: { $0.name == name }) else { return nil }
    self = level
  }
}

/**
 The notification level and snooze deadline, stored beside the account registry
 in the app group so every Zephyr process reads the same values.

 ## Why a file and not `UserDefaults`

 `zephyr` is not sandboxed and the app is, and `UserDefaults(suiteName:)`
 resolves an app-group suite differently for each: the app's lands in the group
 container, the tool's in `~/Library/Preferences`. They are two files, so
 `zephyr notify snooze` would report a snooze the app never saw — telling
 somebody their notifications were off while they kept arriving. The group
 *container* is genuinely shared, so the settings live there instead, written
 atomically the way a configuration is.
 */
public struct NotificationSettings: Sendable, Equatable, Codable {
  /// The level applied until the user picks one.
  public static let defaultLevel = NotificationLevel.fileChanges

  /// The level at or above which an event notifies.
  public var level: NotificationLevel

  /**
   When notifications resume, or `nil` when they are not snoozed.

   A deadline that has passed reads as `nil` rather than being cleaned up:
   a snooze ends by expiring, and nothing should have to run for it to.
   */
  public var snoozedUntil: Date? {
    get { storedSnoozedUntil.flatMap { $0 > Date() ? $0 : nil } }
    set { storedSnoozedUntil = newValue }
  }

  private var storedSnoozedUntil: Date?

  /// Creates the settings, defaulting to notifying about everything and not snoozed.
  public init(level: NotificationLevel = Self.defaultLevel, snoozedUntil: Date? = nil) {
    self.level = level
    storedSnoozedUntil = snoozedUntil
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    // Settings that postdate a stored file decode as their defaults.
    level =
      try container.decodeIfPresent(NotificationLevel.self, forKey: .level) ?? Self.defaultLevel
    storedSnoozedUntil = try container.decodeIfPresent(Date.self, forKey: .storedSnoozedUntil)
  }

  /**
   The settings as they stand, or the defaults when none have been set.

   Unreadable settings read as the defaults rather than throwing: whether to
   notify is not a good enough reason to fail whatever was being done.
   */
  public static func load(from environment: ZephyrEnvironment = .standard) -> Self {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let data = try? Data(contentsOf: environment.notificationSettingsURL),
      let settings = try? decoder.decode(Self.self, from: data)
    else { return Self() }
    return settings
  }

  /**
   Stores the settings.

   Written atomically, which replaces the file rather than editing it — the
   same way a configuration is written.

   - Throws: Whatever writing the file failed with.
   */
  public func save(to environment: ZephyrEnvironment = .standard) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try FileManager.default.createDirectory(
      at: environment.baseDirectory,
      withIntermediateDirectories: true
    )
    try encoder.encode(self).write(to: environment.notificationSettingsURL, options: .atomic)
    ChangeSignal.notificationSettings.post()
  }

  /// Silences notifications for a duration, starting now.
  public mutating func snooze(for duration: Duration) {
    snoozedUntil = Date().addingTimeInterval(Double(duration.components.seconds))
  }

  /// Ends an active snooze.
  public mutating func cancelSnooze() {
    storedSnoozedUntil = nil
  }

  private enum CodingKeys: String, CodingKey {
    case level
    case storedSnoozedUntil = "snoozedUntil"
  }
}
