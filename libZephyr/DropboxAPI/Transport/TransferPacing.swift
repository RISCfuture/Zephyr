import Foundation
import Synchronization

/**
 The pace every transfer in this process runs at: one upload throttle, one
 download throttle, and one expensive-network policy, shared by every account.

 Shared rather than per-account because that is what a limit means. The cap
 exists because of the link this Mac is on, and two Dropboxes syncing at once
 are two claims on one pipe — so they draw on one budget between them rather
 than a copy of it each.

 The values come from ``BandwidthSettings`` in the app group, so the app, the
 File Provider extension, and `zephyr` all pace to the same numbers.
 ``start()`` applies them and keeps applying them as they change.
 */
enum TransferPacing {
  /// What uploads run at, whichever account is uploading.
  static let uploadThrottle = BandwidthThrottle(
    bytesPerSecond: storedSettings.uploadLimitBps,
    ceiling: ceilingBps(under: storedSettings)
  )

  /// What downloads run at, whichever account is downloading.
  static let downloadThrottle = BandwidthThrottle(
    bytesPerSecond: storedSettings.downloadLimitBps,
    ceiling: ceilingBps(under: storedSettings)
  )

  /// Whether Zephyr's own background work may use a network macOS reads as
  /// expensive.
  static let expensiveNetworkPolicy = ExpensiveNetworkPolicy(
    isAllowed: storedSettings.syncsOnExpensiveNetworks
  )

  private static let watchers = Watchers()

  /// The limits as they stand on disk.
  private static var storedSettings: BandwidthSettings { .load() }

  /**
   Applies the stored limits, and follows them and the network conditions from
   here on.

   Calling this more than once is harmless: the first call installs the
   watchers and every later one only re-applies what is already stored.
   */
  static func start() {
    watchers.start()
    Task { await applyStoredSettings() }
  }

  /// Takes whatever the stored limits now say, including the cap the current
  /// network imposes on top of them.
  static func applyStoredSettings() async {
    let settings = storedSettings
    expensiveNetworkPolicy.adopt(settings.syncsOnExpensiveNetworks)
    await uploadThrottle.adoptRate(settings.uploadLimitBps)
    await downloadThrottle.adoptRate(settings.downloadLimitBps)
    await applyNetworkCeiling()
  }

  /// Re-reads what the current path costs and caps both directions to match.
  static func applyNetworkCeiling() async {
    let ceiling = ceilingBps(under: storedSettings)
    await uploadThrottle.adoptCeiling(ceiling)
    await downloadThrottle.adoptCeiling(ceiling)
  }

  /// The cap the metered limit imposes given what the path costs, or `nil`
  /// where the path costs nothing.
  private static func ceilingBps(under settings: BandwidthSettings) -> UInt64? {
    guard NetworkReachability.shared.conditions.isMetered else { return nil }
    return settings.meteredLimitBps
  }

  /// Watches the two things that move a transfer's pace: the stored limits,
  /// and the network under them.
  private final class Watchers: Sendable {
    private let settingsWatcher = Mutex<Task<Void, Never>?>(nil)
    private let conditionsWatcher = Mutex<Task<Void, Never>?>(nil)

    func start() {
      settingsWatcher.withLock { watcher in
        guard watcher == nil else { return }
        watcher = Task {
          for await _ in ChangeSignal.transferLimits.signals() {
            await TransferPacing.applyStoredSettings()
          }
        }
      }
      conditionsWatcher.withLock { watcher in
        guard watcher == nil else { return }
        watcher = Task {
          for await _ in await NetworkReachability.shared.conditionsStream() {
            await TransferPacing.applyNetworkCeiling()
          }
        }
      }
    }
  }
}
