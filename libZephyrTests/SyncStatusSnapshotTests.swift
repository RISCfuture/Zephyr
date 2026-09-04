import Foundation
import Testing

@testable import libZephyr

@Suite
struct `Widget status snapshot` {
  private let environment: ZephyrEnvironment

  init() {
    environment = ZephyrEnvironment(
      baseDirectory: FileManager.default.temporaryDirectory
        .appendingPathComponent("zephyr-snapshot-tests-\(UUID().uuidString)")
    )
  }

  private static func status(
    errorCount: UInt = 0,
    issues: [SyncStatusSnapshot.SyncIssue] = [],
    failure: String? = nil
  ) -> SyncStatusSnapshot.AccountStatus {
    SyncStatusSnapshot.AccountStatus(
      id: "dbid:one",
      displayName: "Personal Dropbox",
      files: 6754,
      folders: 593,
      syncErrorCount: errorCount,
      latestChange: Date(timeIntervalSince1970: 1_700_000_000),
      pendingUploads: 12,
      syncIssues: issues,
      accountFailure: failure
    )
  }

  private static func issues(_ count: Int) -> [SyncStatusSnapshot.SyncIssue] {
    (0..<count).map {
      SyncStatusSnapshot.SyncIssue(
        id: "/file-\($0)",
        path: "/File-\($0).txt",
        title: "Couldn’t upload.",
        detail: "Insufficient space."
      )
    }
  }

  @Test
  func `A published snapshot survives the trip through the shared container`() throws {
    let snapshot = SyncStatusSnapshot(
      accounts: [Self.status(errorCount: 2, issues: Self.issues(2), failure: "Token revoked.")],
      capturedAt: Date(timeIntervalSince1970: 1_700_000_500)
    )
    try snapshot.write(to: environment)
    #expect(SyncStatusSnapshot.load(from: environment) == snapshot)
  }

  @Test
  func `An account whose every item is failing carries only the newest issues`() throws {
    let overflowing = Int(SyncStatusSnapshot.AccountStatus.maximumCarriedIssues) + 40
    let status = Self.status(errorCount: UInt(overflowing), issues: Self.issues(overflowing))
    #expect(status.syncIssues.count == Int(SyncStatusSnapshot.AccountStatus.maximumCarriedIssues))
    // The true total still reads, whether or not each one is listed.
    #expect(status.syncErrorCount == UInt(overflowing))

    try SyncStatusSnapshot(accounts: [status]).write(to: environment)
    let reloaded = try #require(SyncStatusSnapshot.load(from: environment))
    #expect(
      reloaded.accounts[0].syncIssues.count
        == Int(SyncStatusSnapshot.AccountStatus.maximumCarriedIssues)
    )
    #expect(reloaded.accounts[0].syncIssues.first?.path == "/File-0.txt")
  }

  @Test
  func `A snapshot that was never published reads as nothing, not as an empty account`() {
    #expect(SyncStatusSnapshot.load(from: environment) == nil)
  }

  @Test
  func `A truncated snapshot reads as nothing rather than throwing`() throws {
    try FileManager.default.createDirectory(
      at: environment.baseDirectory,
      withIntermediateDirectories: true
    )
    try Data("{ \"accounts\": [".utf8)
      .write(to: SyncStatusSnapshot.fileURL(in: environment))
    #expect(SyncStatusSnapshot.load(from: environment) == nil)
  }

  @Test
  func `Publishing over a previous snapshot replaces it whole`() throws {
    try SyncStatusSnapshot(accounts: [Self.status(), Self.status()]).write(to: environment)
    try SyncStatusSnapshot(accounts: [Self.status()]).write(to: environment)
    #expect(SyncStatusSnapshot.load(from: environment)?.accounts.count == 1)
  }

  @Test
  func `An account wants attention for a whole-account failure, not just failed files`() {
    #expect(Self.status().needsAttention == false)
    #expect(Self.status(errorCount: 1).needsAttention)
    #expect(Self.status(failure: "Token revoked.").needsAttention)
  }
}
