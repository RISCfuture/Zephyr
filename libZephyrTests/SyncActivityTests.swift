import Foundation
import Testing

@testable import libZephyr

@Suite
struct SyncActivityTests {
  private static let now = Date(timeIntervalSince1970: 1_800_000_000)

  private func activity(
    hasIssues: Bool = false,
    isPaused: Bool = false,
    canReachDropbox: Bool = true,
    pendingChanges: UInt? = nil
  ) -> SyncActivity {
    SyncActivity(
      latestChange: nil,
      hasIssues: hasIssues,
      isPaused: isPaused,
      canReachDropbox: canReachDropbox,
      pendingChanges: pendingChanges,
      asOf: Self.now
    )
  }

  /// Nothing a backlog describes is happening while syncing is stopped, so the
  /// pause takes the reading — and with it the badge, which otherwise went on
  /// flying whatever was true when the switch was thrown.
  @Test
  func `a pause outranks a backlog`() {
    #expect(activity(isPaused: true, pendingChanges: 128).state == .paused)
  }

  /// Issues outlast a pause and still want the user once syncing resumes, so
  /// they keep the reading — and with it the caution the mark flies.
  @Test
  func `issues outrank a pause`() {
    #expect(activity(hasIssues: true, isPaused: true).state == .issues)
  }

  /// A measured backlog is named for the one direction it describes; a reading
  /// with nothing measured can only say that something is happening.
  @Test
  func `a measured backlog is named as sending`() {
    #expect(activity(pendingChanges: 128).summary == activity(pendingChanges: 12).summary)
    #expect(activity(pendingChanges: 128).summary != activity(pendingChanges: 0).summary)
    #expect(activity(pendingChanges: 0).state == .upToDate)
  }

  /// "Sending" claims bytes are moving. A backlog on a path that will not
  /// carry it is still a backlog, and saying so is as far as the truth goes —
  /// which is what kept the panel from announcing a transfer over a network
  /// that was carrying none of it.
  @Test
  func `a backlog nothing is carrying does not read as sending`() {
    let held = activity(canReachDropbox: false, pendingChanges: 128)
    let moving = activity(pendingChanges: 128)
    #expect(held.state == moving.state)
    #expect(held.summary != moving.summary)
  }
}
