public import Foundation

/**
 How hard Zephyr's own background work should be holding back.

 Zephyr is a background utility, and being cheap on network, battery, and
 heat is part of being correct. The indexer walking a whole account and the
 change feed being held open are work nobody is waiting on, so a Mac that is
 tethered, in Low Data Mode, saving power, or hot has a claim on how fast
 they run.

 Holding back is never stopping. A suspended initial listing shows an empty
 Dropbox in Finder with nothing to explain it, which is the worst thing this
 app can do; the loops keep running and breathe between pages instead.

 The reading is taken fresh at each pause rather than observed, so nothing
 has to be unsubscribed and a Mac plugged in mid-listing speeds up at the
 next page.
 */
public enum BulkWorkPressure: Int, Sendable, Comparable {
  /// Nothing is asking for restraint.
  case none
  /// Something is: a path that looks metered, a battery being saved, a Mac
  /// running warm.
  case mild
  /// Something said so outright, or the Mac is in trouble: Low Data Mode, or
  /// a critical thermal state.
  case firm

  /// What the Mac is asking for as of now.
  public static var current: Self {
    let process = ProcessInfo.processInfo
    return Self(
      conditions: NetworkReachability.shared.conditions,
      isLowPowerModeEnabled: process.isLowPowerModeEnabled,
      thermalState: process.thermalState
    )
  }

  private static let mildDelay: Duration = .seconds(2)
  private static let firmDelay: Duration = .seconds(8)

  /// How long bulk work pauses between units of work — a listing page, a
  /// delta page, a longpoll that reported nothing.
  public var delayBetweenUnits: Duration {
    switch self {
      case .none: .zero
      case .mild: Self.mildDelay
      case .firm: Self.firmDelay
    }
  }

  /// How much longer a recurring interval runs for under each pressure.
  private var stretchFactor: Int {
    switch self {
      case .none: 1
      case .mild: 2
      case .firm: 4
    }
  }

  /// How a signpost names this pressure, where the raw value would read as a
  /// number with nothing to say.
  var signpostName: String {
    switch self {
      case .none: "none"
      case .mild: "mild"
      case .firm: "firm"
    }
  }

  /**
   Reads the pressure from what the Mac reports.

   The signals do not add up — three mild reasons to slow down are still one
   mild reason — so the firmest of them decides.
   */
  public init(
    conditions: NetworkConditions,
    isLowPowerModeEnabled: Bool,
    thermalState: ProcessInfo.ThermalState
  ) {
    self = max(
      Self(conditions: conditions),
      max(isLowPowerModeEnabled ? .mild : .none, Self(thermalState: thermalState))
    )
  }

  /// Low Data Mode was asked for; an expensive path was only inferred, so it
  /// weighs less. An unreachable path asks for nothing: the request fails on
  /// its own, and pacing a failure only delays noticing it.
  private init(conditions: NetworkConditions) {
    self =
      if conditions.isConstrained {
        .firm
      } else if conditions.isExpensive {
        .mild
      } else {
        .none
      }
  }

  private init(thermalState: ProcessInfo.ThermalState) {
    self =
      switch thermalState {
        case .nominal, .fair: .none
        case .serious: .mild
        case .critical: .firm
        @unknown default: .mild
      }
  }

  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

  /// `interval` as it should run under this pressure.
  public func stretching(_ interval: Duration) -> Duration { interval * stretchFactor }

  /// Pauses before the next unit of bulk work, returning at once when
  /// nothing is asking for restraint.
  public func pauseBetweenUnits() async throws {
    guard self > .none else { return }
    try await ContinuousClock().sleep(for: delayBetweenUnits)
  }
}
