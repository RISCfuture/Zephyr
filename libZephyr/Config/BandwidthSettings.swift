import Foundation

/**
 The transfer bandwidth caps, stored beside the account registry in the app
 group so every Zephyr process reads the same values.

 These belong to the Mac rather than to one account. A cap exists because of
 the link this computer is on, and a link does not know which Dropbox is using
 it — so two accounts syncing at once draw on one budget between them rather
 than a copy of it each.

 ## Why a file and not `UserDefaults`

 `zephyr` is not sandboxed and the app is, and `UserDefaults(suiteName:)`
 resolves an app-group suite differently for each: the app's lands in the group
 container, the tool's in `~/Library/Preferences`. They are two files, so a
 limit set by one would be invisible to the other. The group *container* is
 genuinely shared — the tool already reads the account registry and the sync
 index out of it — so the settings live there too, written atomically the way a
 configuration is, which is also what lets a running File Provider extension
 watch them.
 */
public struct BandwidthSettings: Sendable, Equatable, Codable {
  /// What transfers run at on a metered network unless the user says
  /// otherwise: a background trickle that still delivers a file somebody
  /// opened, and the lowest stop the Settings slider offers.
  public static let defaultMeteredLimitBps: UInt64 = 250_000

  /// The upload cap in bytes per second; `0` means unlimited.
  public var uploadLimitBps: UInt64

  /// The download cap in bytes per second; `0` means unlimited.
  public var downloadLimitBps: UInt64

  /**
   The transfer cap in bytes per second while the network costs the user
   something — a personal hotspot, a metered connection, Low Data Mode; `0`
   means unlimited.

   It caps rather than replaces: whichever of this and the direction's own
   limit is lower decides.
   */
  public var meteredLimitBps: UInt64

  /**
   Whether Zephyr's own background work — the initial listing, delta pages,
   the change feed — may use a network macOS reads as expensive.

   Off by default, because a Mac on a tethered iPhone should not walk a whole
   Dropbox unasked. It exists because that reading is a heuristic and can be
   wrong: an unmetered connection macOS calls expensive is the user's to
   overrule. Low Data Mode is not, and holds background work back either way.
   */
  public var syncsOnExpensiveNetworks: Bool

  /// Creates the settings, defaulting each limit to what an unconfigured Mac uses.
  public init(
    uploadLimitBps: UInt64 = 0,
    downloadLimitBps: UInt64 = 0,
    meteredLimitBps: UInt64 = Self.defaultMeteredLimitBps,
    syncsOnExpensiveNetworks: Bool = false
  ) {
    self.uploadLimitBps = uploadLimitBps
    self.downloadLimitBps = downloadLimitBps
    self.meteredLimitBps = meteredLimitBps
    self.syncsOnExpensiveNetworks = syncsOnExpensiveNetworks
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    // Settings that postdate a stored file decode as their defaults.
    uploadLimitBps = try container.decodeIfPresent(UInt64.self, forKey: .uploadLimitBps) ?? 0
    downloadLimitBps = try container.decodeIfPresent(UInt64.self, forKey: .downloadLimitBps) ?? 0
    meteredLimitBps =
      try container.decodeIfPresent(UInt64.self, forKey: .meteredLimitBps)
      ?? Self.defaultMeteredLimitBps
    syncsOnExpensiveNetworks =
      try container.decodeIfPresent(Bool.self, forKey: .syncsOnExpensiveNetworks) ?? false
  }

  /**
   The limits as they stand, or the defaults when none have been set.

   Unreadable settings read as the defaults rather than throwing: a limit is
   a restraint on syncing, and failing to read one should not be a reason to
   stop syncing altogether.
   */
  public static func load(from environment: ZephyrEnvironment = .standard) -> Self {
    guard let data = try? Data(contentsOf: environment.bandwidthSettingsURL),
      let settings = try? JSONDecoder().decode(Self.self, from: data)
    else { return Self() }
    return settings
  }

  /**
   Stores the limits.

   Written atomically, which replaces the file rather than editing it — the
   same way a configuration is written, and what a watching extension needs in
   order to see the change.

   - Throws: Whatever writing the file failed with.
   */
  public func save(to environment: ZephyrEnvironment = .standard) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try FileManager.default.createDirectory(
      at: environment.baseDirectory,
      withIntermediateDirectories: true
    )
    try encoder.encode(self).write(to: environment.bandwidthSettingsURL, options: .atomic)
    ChangeSignal.transferLimits.post()
  }

  private enum CodingKeys: String, CodingKey {
    case uploadLimitBps = "uploadBandwidthLimit"
    case downloadLimitBps = "downloadBandwidthLimit"
    case meteredLimitBps = "meteredBandwidthLimit"
    case syncsOnExpensiveNetworks
  }
}
