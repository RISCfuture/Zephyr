import Foundation

/**
 Paces transfer traffic to a byte rate by spacing out chunk sends: each
 acquisition reserves the next transmission slot, so sustained throughput
 converges on the configured rate while an idle throttle passes the first
 chunk through immediately.

 The rate is settable, because a bandwidth limit changed in the app or the
 CLI has to reach transfers running in a File Provider extension that may
 outlive many such changes.
 */
public actor BandwidthThrottle {
  private let clock = ContinuousClock()
  private var nextSlot: ContinuousClock.Instant?
  private var configuredRate: UInt64?
  private var ceiling: UInt64?

  /**
   The paced rate in bytes per second, or `nil` when traffic passes unpaced.

   The lower of the configured limit and any ceiling in force. A rate of zero
   — how a configured bandwidth limit spells “unlimited” — reads back as
   `nil`, and `nil` loses to a ceiling: unlimited means whatever is allowed,
   not more than everything.
   */
  public var bytesPerSecond: UInt64? {
    guard let configuredRate else { return ceiling }
    guard let ceiling else { return configuredRate }
    return min(configuredRate, ceiling)
  }

  /**
   Whether a rate is in force.

   A caller that pays for pacing — the download transport streams the
   response body chunk by chunk to pace it, rather than letting `URLSession`
   drain the socket — checks this first and takes its faster path when
   nothing is being paced.
   */
  public var isPacing: Bool { bytesPerSecond != nil }

  /**
   Creates a throttle pacing to `bytesPerSecond`, capped at `ceiling`; `nil`
   or zero paces nothing and caps nothing.
   */
  public init(bytesPerSecond: UInt64?, ceiling: UInt64? = nil) {
    configuredRate = Self.paced(bytesPerSecond)
    self.ceiling = Self.paced(ceiling)
  }

  private static func paced(_ bytesPerSecond: UInt64?) -> UInt64? {
    bytesPerSecond.flatMap { $0 > 0 ? $0 : nil }
  }

  /**
   The pacing schedule: a chunk starts at the later of now and the previously
   reserved slot, and pushes the next slot out by the chunk's transmission
   time at the paced rate.
   */
  static func reserve(
    byteCount: Int,
    bytesPerSecond: UInt64,
    nextSlot: ContinuousClock.Instant?,
    now: ContinuousClock.Instant
  ) -> (start: ContinuousClock.Instant, next: ContinuousClock.Instant) {
    let start = max(nextSlot ?? now, now)
    let transmission = Duration.seconds(Double(byteCount) / Double(bytesPerSecond))
    return (start, start + transmission)
  }

  /**
   Paces subsequent traffic to a new configured limit; `nil` or zero lets it
   through unpaced, subject to any ceiling.

   This is the limit the user set, and nothing but the user changes it.
   */
  public func adoptRate(_ bytesPerSecond: UInt64?) {
    let previous = self.bytesPerSecond
    configuredRate = Self.paced(bytesPerSecond)
    forgetReservation(ifChangedFrom: previous)
  }

  /**
   Caps subsequent traffic regardless of the configured limit; `nil` or zero
   lifts the cap.

   Kept apart from ``adoptRate(_:)`` so that a cap the conditions ask for and
   a limit the user set cannot overwrite each other: a Mac that leaves Low
   Data Mode goes back to the user's limit, not to the last cap it was under.
   */
  public func adoptCeiling(_ bytesPerSecond: UInt64?) {
    let previous = self.bytesPerSecond
    ceiling = Self.paced(bytesPerSecond)
    forgetReservation(ifChangedFrom: previous)
  }

  /// Drops the reservation made for a rate that no longer applies, so a
  /// raised limit takes effect on the next chunk rather than after the wait
  /// the old one had already scheduled.
  private func forgetReservation(ifChangedFrom previous: UInt64?) {
    guard bytesPerSecond != previous else { return }
    nextSlot = nil
  }

  /**
   Waits until `byteCount` bytes fit the paced rate, then reserves their
   transmission time. Call immediately before sending or consuming the bytes.
   */
  public func acquire(_ byteCount: Int) async throws {
    guard byteCount > 0, let bytesPerSecond else { return }
    let slot = Self.reserve(
      byteCount: byteCount,
      bytesPerSecond: bytesPerSecond,
      nextSlot: nextSlot,
      now: clock.now
    )
    nextSlot = slot.next
    if slot.start > clock.now {
      try await clock.sleep(until: slot.start, tolerance: .milliseconds(10))
    }
  }
}
