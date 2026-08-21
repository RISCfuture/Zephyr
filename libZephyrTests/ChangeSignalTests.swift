import Foundation
import Testing

@testable import libZephyr

@Suite("Change signals")
struct ChangeSignalTests {
  /// How long a post that is already on its way is given to arrive.
  private static let deliveryTimeout = Duration.seconds(2)

  /// How long a post that must never arrive is waited out.
  private static let silenceTimeout = Duration.milliseconds(500)

  /// An account no other test posts about.
  ///
  /// A notify name is global to the machine and suites run in parallel, so a
  /// test that watched a name any other test writes — the transfer limits, say,
  /// which every suite that saves settings posts — would hear it.
  private static func unsharedAccount() throws -> AccountIdentifier {
    try AccountIdentifier(validating: "dbid:\(UUID().uuidString)")
  }

  private static func signalArrives(
    on stream: AsyncStream<Void>,
    within timeout: Duration = deliveryTimeout
  ) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
      group.addTask {
        for await _ in stream { return true }
        return false
      }
      group.addTask {
        try? await Task.sleep(for: timeout)
        return false
      }
      let arrived = await group.next() ?? false
      group.cancelAll()
      return arrived
    }
  }

  @Test("A post wakes a watcher of the same account")
  func aPostWakesAWatcherOfTheSameAccount() async throws {
    let signal = ChangeSignal.index(try Self.unsharedAccount())
    let commits = signal.signals()
    signal.post()
    #expect(await Self.signalArrives(on: commits))
  }

  @Test("A post about one account leaves another account's watcher alone")
  func aPostAboutOneAccountLeavesAnotherAccountsWatcherAlone() async throws {
    let commits = ChangeSignal.index(try Self.unsharedAccount()).signals()
    ChangeSignal.index(try Self.unsharedAccount()).post()
    #expect(await Self.signalArrives(on: commits, within: Self.silenceTimeout) == false)
  }

  @Test("A watcher of one file is deaf to a post about another")
  func aWatcherOfOneFileIsDeafToAPostAboutAnother() async throws {
    let account = try Self.unsharedAccount()
    let configuration = ChangeSignal.configuration(account).signals()
    ChangeSignal.index(account).post()
    #expect(await Self.signalArrives(on: configuration, within: Self.silenceTimeout) == false)
  }

  @Test("A run of posts is reported far fewer times than it is posted")
  func aRunOfPostsIsReportedFarFewerTimesThanItIsPosted() async throws {
    let signal = ChangeSignal.index(try Self.unsharedAccount())
    let posts = 20
    let reports = signal.coalescedSignals(within: .milliseconds(500))

    let counting = Task {
      var reported = 0
      for await _ in reports { reported += 1 }
      return reported
    }
    for _ in 0..<posts {
      signal.post()
      try await Task.sleep(for: .milliseconds(10))
    }
    try await Task.sleep(for: .milliseconds(100))
    counting.cancel()

    let reported = await counting.value
    #expect(reported >= 1, "a run of posts must still say something while it runs")
    #expect(reported < posts, "posts arriving inside one window must collapse")
  }
}
