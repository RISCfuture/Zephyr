import Foundation
import Testing
import libZephyr

@testable import ZephyrCommon

/// An error from no tier at all: neither fatal nor authentication, so it is
/// the kind a single poll says nothing about.
private struct UnclassifiedFailure: Error {}

@Suite
@MainActor
struct AccountFailureTests {
  private func failure(
    _ error: any Error,
    failedPolls: Int
  ) -> AppModel.AccountFailure? {
    AppModel.AccountFailure(DomainWatcher.PollFailure(error: error, failedPolls: failedPolls))
  }

  /// A lost connection comes back on its own, so no run of them is long
  /// enough to make it the account's failure: it is reported as a state
  /// instead, and never as something the user has to fix.
  @Test
  func `a lost connection never becomes an account failure`() {
    let lost = EngineFailure.connection(detail: "The network connection was lost.")
    #expect(failure(lost, failedPolls: 1) == nil)
    #expect(failure(lost, failedPolls: 10) == nil)
  }

  /// A revoked token is the account's failure the first time it is seen —
  /// waiting to be sure would leave the user staring at a Dropbox that
  /// silently stopped.
  @Test
  func `a revoked token stops the account at once`() throws {
    let revoked = try #require(failure(AuthenticationFailure.tokenRevoked, failedPolls: 1))
    #expect(revoked.isResolvedByRelinking)
  }

  /// The credential check hands its error straight to the initializer rather
  /// than through a poll, and the poll's guard never ran for it. A connection
  /// it could not make says no more about the account by that door than by the
  /// other one.
  @Test
  func `a lost connection is no account failure from the credential check either`() {
    let lost = EngineFailure.connection(detail: "The network connection was lost.")
    #expect(AppModel.AccountFailure(lost) == nil)
  }

  /// An error from no tier is weather until it keeps happening: three polls
  /// in a row failing is the account's trouble, one is not.
  @Test
  func `an unclassified error has to keep happening`() {
    #expect(failure(UnclassifiedFailure(), failedPolls: 1) == nil)
    #expect(failure(UnclassifiedFailure(), failedPolls: 2) == nil)
    #expect(failure(UnclassifiedFailure(), failedPolls: 3) != nil)
  }

  /// The extension's record outlives the outage that caused it: a connection
  /// lost as the Mac went to sleep is still in the index when it wakes. This
  /// is the one door where the error's type is gone, so the verdict stored
  /// beside the words is all that stops it being read back as a stoppage.
  @Test
  func `a recorded outage is no account failure when it is read back`() {
    let outage = EngineErrorRecord(
      title: "Syncing stopped.",
      detail: "Cannot connect to Dropbox. The network connection was lost.",
      resolvesWithoutUser: true
    )
    #expect(AppModel.AccountFailure(outage) == nil)

    let revoked = EngineErrorRecord(
      title: "Dropbox authentication failed.",
      detail: "Access to Dropbox was revoked.",
      resolvesWithoutUser: false
    )
    #expect(AppModel.AccountFailure(revoked) != nil)
  }
}
