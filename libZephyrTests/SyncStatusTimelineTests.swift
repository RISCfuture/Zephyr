import Foundation
import Testing
import WidgetKit

@testable import libZephyr

@Suite("Widget timeline provider")
struct SyncStatusTimelineTests {
  private let environment: ZephyrEnvironment
  private let provider: SyncStatusTimelineProvider

  init() {
    environment = ZephyrEnvironment(
      baseDirectory: FileManager.default.temporaryDirectory
        .appendingPathComponent("zephyr-timeline-tests-\(UUID().uuidString)")
    )
    provider = SyncStatusTimelineProvider(environment: environment)
  }

  private func publish(accountNamed displayName: String) throws {
    try SyncStatusSnapshot(
      accounts: [
        SyncStatusSnapshot.AccountStatus(
          id: "dbid:one",
          displayName: displayName,
          files: 6754,
          folders: 593,
          syncErrorCount: 0,
          latestChange: Date()
        )
      ]
    )
    .write(to: environment)
  }

  @Test("The entry reads whatever the app last published")
  func entryReadsTheContainer() throws {
    try publish(accountNamed: "Personal Dropbox")
    let entry = provider.currentEntry()
    #expect(entry.snapshot?.accounts.first?.displayName == "Personal Dropbox")
  }

  @Test("A republished snapshot is what the next entry carries")
  func entryFollowsRepublishing() throws {
    try publish(accountNamed: "Personal Dropbox")
    try publish(accountNamed: "Work Dropbox")
    #expect(provider.currentEntry().snapshot?.accounts.first?.displayName == "Work Dropbox")
  }

  @Test("Before the app has published, the entry carries nothing rather than a sample")
  func entryIsEmptyBeforeAnythingIsPublished() {
    #expect(provider.currentEntry().snapshot == nil)
  }
}
