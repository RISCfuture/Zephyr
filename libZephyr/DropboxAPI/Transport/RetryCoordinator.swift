import Foundation

/**
 Tracks the account-wide backoff Dropbox requests via longpoll `backoff` fields
 and rate-limit responses, so every request waits it out before hitting the API.

 Mirrors Maestral's `_backoff_until` handling, including the safety pad it adds
 on top of server-requested backoff.
 */
actor RetryCoordinator {
  /// Extra delay added on top of a server-requested backoff.
  private static let safetyPad: Duration = .seconds(5)

  /// The widest a waiter's own extra wait after a backoff gets, in
  /// milliseconds.
  private static let releaseSpreadMilliseconds = 2000

  private var backoffUntil: ContinuousClock.Instant?
  private let clock = ContinuousClock()

  /// Creates a coordinator with no backoff pending. Share one per account, so
  /// that every request through that account's clients observes the same backoff.
  init() {}

  private static func releaseSpread() -> Duration {
    .milliseconds(Int.random(in: 0..<releaseSpreadMilliseconds))
  }

  /**
   Suspends until any server-requested backoff has elapsed, honoring
   extensions reported while waiting.

   Every waiter shares the one deadline, so each adds a random wait of its own
   once the deadline passes: released together, they would reach Dropbox in
   the same instant and be rate-limited together again.
   */
  func waitIfBackedOff() async throws {
    var waited = false
    while let backoffUntil, backoffUntil > clock.now {
      try await clock.sleep(until: backoffUntil)
      waited = true
    }
    if waited { try await clock.sleep(for: Self.releaseSpread()) }
  }

  /// Records a server-requested backoff of `duration`, plus a safety pad.
  func reportServerBackoff(_ duration: Duration) {
    let until = clock.now + duration + Self.safetyPad
    if backoffUntil.map({ until > $0 }) ?? true {
      backoffUntil = until
    }
  }
}
