import Foundation
import Testing
import WidgetKit

@testable import libZephyr

@Suite
struct `Widget timeline provider` {
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

  @Test
  func `The entry reads whatever the app last published`() throws {
    try publish(accountNamed: "Personal Dropbox")
    let entry = provider.currentEntry()
    #expect(entry.snapshot?.accounts.first?.displayName == "Personal Dropbox")
  }

  @Test
  func `A republished snapshot is what the next entry carries`() throws {
    try publish(accountNamed: "Personal Dropbox")
    try publish(accountNamed: "Work Dropbox")
    #expect(provider.currentEntry().snapshot?.accounts.first?.displayName == "Work Dropbox")
  }

  @Test
  func `Before the app has published, the entry carries nothing rather than a sample`() {
    #expect(provider.currentEntry().snapshot == nil)
  }
}
