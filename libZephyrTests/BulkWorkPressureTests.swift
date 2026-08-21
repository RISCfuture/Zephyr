import Foundation
import Testing

@testable import libZephyr

@Suite("Bulk work pressure")
struct BulkWorkPressureTests {
  private static let cheapPath = NetworkConditions()

  @Test
  func aCheapCoolMacOnMainsPowerAsksForNothing() {
    let pressure = BulkWorkPressure(
      conditions: Self.cheapPath,
      isLowPowerModeEnabled: false,
      thermalState: .nominal
    )
    #expect(pressure == BulkWorkPressure.none)
    #expect(pressure.delayBetweenUnits == .zero)
    #expect(pressure.stretching(.seconds(60)) == .seconds(60))
  }

  /// Low Data Mode was switched on deliberately; an expensive path is the
  /// system's guess. The first outranks the second.
  @Test
  func lowDataModeAsksForMoreThanAPathThatMerelyLooksExpensive() {
    let expensive = BulkWorkPressure(
      conditions: NetworkConditions(isExpensive: true),
      isLowPowerModeEnabled: false,
      thermalState: .nominal
    )
    let constrained = BulkWorkPressure(
      conditions: NetworkConditions(isConstrained: true),
      isLowPowerModeEnabled: false,
      thermalState: .nominal
    )
    #expect(expensive < constrained)
    #expect(expensive.delayBetweenUnits < constrained.delayBetweenUnits)
  }

  /// Three mild reasons to slow down are still one mild reason: the firmest
  /// signal decides rather than the signals adding up.
  @Test
  func theFirmestSignalDecidesRatherThanTheSignalsAddingUp() {
    let stacked = BulkWorkPressure(
      conditions: NetworkConditions(isExpensive: true),
      isLowPowerModeEnabled: true,
      thermalState: .serious
    )
    let single = BulkWorkPressure(
      conditions: Self.cheapPath,
      isLowPowerModeEnabled: true,
      thermalState: .nominal
    )
    #expect(stacked == single)

    let critical = BulkWorkPressure(
      conditions: Self.cheapPath,
      isLowPowerModeEnabled: false,
      thermalState: .critical
    )
    #expect(critical > stacked)
  }

  /// A request over a path that isn't there fails on its own. Pacing the
  /// failure would only delay noticing it, and delay the catch-up that
  /// follows the route coming back.
  @Test
  func anUnreachablePathAsksForNothing() {
    let pressure = BulkWorkPressure(
      conditions: NetworkConditions(isSatisfied: false),
      isLowPowerModeEnabled: false,
      thermalState: .nominal
    )
    #expect(pressure == BulkWorkPressure.none)
  }
}
