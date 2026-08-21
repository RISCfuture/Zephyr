import Foundation
import Testing

@testable import libZephyr

@Suite
struct SyncActivityTests {
  private static let now = Date(timeIntervalSince1970: 1_800_000_000)
  private static let prolongedOutageSec: TimeInterval = 5 * 60

  private func activity(
    offlineSince: Date?,
    hasIssues: Bool = false,
    pendingUploads: UInt? = nil,
    canSync: Bool = true
  ) -> SyncActivity {
    SyncActivity(
      latestChange: nil,
      hasIssues: hasIssues,
      pendingUploads: pendingUploads,
      offlineSince: offlineSince,
      canSync: canSync,
      asOf: Self.now
    )
  }

  /// An account nobody can reach reads as offline however much it was doing
  /// when the connection went, because none of it is moving.
  @Test
  func unreachableOutranksABacklog() {
    let offline = activity(offlineSince: Self.now, pendingUploads: 12)
    #expect(offline.state == .offline(isProlonged: false))
  }

  /// Issues outlast an outage and still want the user, so they keep the
  /// reading — and with it the caution the menu-bar mark flies.
  @Test
  func issuesOutrankBeingUnreachable() {
    #expect(activity(offlineSince: Self.now, hasIssues: true).state == .issues)
  }

  /// Nothing set up to sync with outlasts an outage and outlasts a backlog
  /// nothing will ever carry, so it keeps the reading. Reading it as anything
  /// else is how an account that cannot sync at all comes to fly up to date.
  @Test
  func unfinishedSetupOutranksAnOutageAndABacklog() {
    let unset = activity(offlineSince: Self.now, pendingUploads: 12, canSync: false)
    #expect(unset.state == .needsSetup)
    #expect(activity(offlineSince: nil, canSync: false).state == .needsSetup)
  }

  /// Issues survive finishing setup, so they outrank it in turn.
  @Test
  func issuesOutrankUnfinishedSetup() {
    #expect(activity(offlineSince: nil, hasIssues: true, canSync: false).state == .issues)
  }

  /// A blip and an outage are the same state wearing different words: the
  /// wait is only worth naming as trouble once it has lasted.
  @Test
  func anOutageIsProlongedOnlyAfterFiveMinutes() {
    #expect(
      activity(offlineSince: Self.now.addingTimeInterval(-Self.prolongedOutageSec + 1))
        .state == .offline(isProlonged: false)
    )
    #expect(
      activity(offlineSince: Self.now.addingTimeInterval(-Self.prolongedOutageSec))
        .state == .offline(isProlonged: true)
    )
  }
}
