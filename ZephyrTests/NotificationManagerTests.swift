import Foundation
import Testing
import libZephyr

@testable import ZephyrCommon

@Suite
@MainActor
struct NotificationManagerTests {
  private static let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)

  private func makeAccount() throws -> AccountIdentifier {
    try AccountIdentifier(validating: "dbid:AAH4f99T0taONIb")
  }

  private func remoteChange(
    id: Int64,
    path: String,
    changeType: HistoryEventRecord.ChangeType = .modified,
    modifiedBy: AccountIdentifier? = nil
  ) throws -> HistoryEventRecord {
    var event = HistoryEventRecord(
      dbxID: nil,
      path: try DropboxPath(validating: path),
      itemType: .file,
      changeType: changeType,
      direction: .down,
      size: nil,
      revision: nil,
      contentHash: nil,
      modifiedBy: modifiedBy
    )
    event.id = id
    return event
  }

  private func localChange(id: Int64, path: String) throws -> HistoryEventRecord {
    var event = HistoryEventRecord(
      dbxID: nil,
      path: try DropboxPath(validating: path),
      itemType: .file,
      changeType: .modified,
      direction: .up,
      size: nil,
      revision: nil,
      contentHash: nil
    )
    event.id = id
    return event
  }

  /// A recorded issue stamped a fixed distance past ``referenceDate``, so a
  /// fixture rebuilt for a later digest keeps the timestamp it had before.
  private func syncIssue(path: String, at offset: TimeInterval) throws -> SyncErrorRecord {
    let dropboxPath = try DropboxPath(validating: path)
    return SyncErrorRecord(
      pathNormalized: dropboxPath.normalized,
      path: dropboxPath,
      title: "Couldn’t upload",
      detail: "Your Dropbox is out of space.",
      occurredAt: Self.referenceDate.addingTimeInterval(offset)
    )
  }

  /// Silences notifications for the rest of the test.
  private func snooze(in environment: ZephyrEnvironment) throws {
    var settings = NotificationSettings.load(from: environment)
    settings.snooze(for: .seconds(3600))
    try settings.save(to: environment)
  }

  /// Sets the level the manager notifies at.
  private func setLevel(_ level: NotificationLevel, in environment: ZephyrEnvironment) throws {
    var settings = NotificationSettings.load(from: environment)
    settings.level = level
    try settings.save(to: environment)
  }

  /// Runs a body against a manager over a throwaway container and defaults, so
  /// neither the settings nor the watermarks touch the machine's real ones.
  private func withManager(
    _ body: (NotificationManager, DeliveryLog, ZephyrEnvironment) throws -> Void
  ) rethrows {
    let suiteName = "NotificationManagerTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("zephyr-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let environment = ZephyrEnvironment(baseDirectory: directory)
    let log = DeliveryLog()
    let manager = NotificationManager(environment: environment, defaults: defaults) {
      log.record($0)
    }
    try body(manager, log, environment)
  }

  @Test
  func `the first digest for an account only records watermarks`() throws {
    try withManager { manager, log, _ in
      let account = try makeAccount()
      manager.digest(
        account: account,
        history: [try remoteChange(id: 1, path: "/a.txt"), try remoteChange(id: 2, path: "/b.txt")],
        errors: [
          try syncIssue(path: "/big.mov", at: 0),
          try syncIssue(path: "/huge.mov", at: 60)
        ],
        failure: nil
      )

      // Linking an account with a backlog must not greet the user with a burst
      // of notifications — neither for changes nor for pre-existing issues.
      #expect(log.notifications.isEmpty)

      // Replaying the same backlog stays quiet: the watermarks were recorded.
      manager.digest(
        account: account,
        history: [try remoteChange(id: 1, path: "/a.txt"), try remoteChange(id: 2, path: "/b.txt")],
        errors: [
          try syncIssue(path: "/big.mov", at: 0),
          try syncIssue(path: "/huge.mov", at: 60)
        ],
        failure: nil
      )
      #expect(log.notifications.isEmpty)

      // What arrives after the watermarks does notify.
      manager.digest(
        account: account,
        history: [try remoteChange(id: 3, path: "/Docs/c.txt")],
        errors: [try syncIssue(path: "/late.mov", at: 120)],
        failure: nil
      )
      #expect(log.notifications.count == 2)
      #expect(log.notifications[0].body == "“c.txt” was updated.")
      #expect(log.notifications[1].identifier == "issue-\(account.rawValue)-/late.mov")
    }
  }

  @Test
  func `changes summarize into one notification while each issue notifies separately`() throws {
    try withManager { manager, log, _ in
      let account = try makeAccount()
      manager.digest(account: account, history: [], errors: [], failure: nil)

      manager.digest(
        account: account,
        history: [
          try remoteChange(id: 10, path: "/Docs/report.txt"),
          try remoteChange(id: 11, path: "/Docs/notes.txt"),
          try remoteChange(id: 12, path: "/photo.jpg"),
          // A file this Mac uploaded is not news to the person who uploaded it.
          try localChange(id: 13, path: "/Docs/mine.txt")
        ],
        errors: [
          try syncIssue(path: "/big.mov", at: 0),
          try syncIssue(path: "/huge.mov", at: 60)
        ],
        failure: nil
      )

      #expect(log.notifications.count == 3)
      let summary = try #require(log.notifications.first)
      #expect(summary.title == "Dropbox files changed")
      #expect(summary.body == "“report.txt” and 2 more changed.")
      // One identifier per account collapses successive digests into one banner.
      #expect(summary.identifier == "changes-\(account.rawValue)")

      let issues = Array(log.notifications.dropFirst())
      #expect(issues.map(\.title) == ["Couldn’t sync “big.mov”", "Couldn’t sync “huge.mov”"])
      #expect(issues.allSatisfy { $0.body == "Your Dropbox is out of space." })
      #expect(
        issues.map(\.identifier) == [
          "issue-\(account.rawValue)-/big.mov", "issue-\(account.rawValue)-/huge.mov"
        ]
      )
    }
  }

  @Test
  func `two accounts failing on the same path each get their own banner`() throws {
    try withManager { manager, log, _ in
      let personal = try makeAccount()
      let work = try AccountIdentifier(validating: "dbid:AAH4f99T0taONIb-work")
      let shared = "/Camera Uploads/IMG_0001.mov"
      let normalized = try syncIssue(path: shared, at: 60).pathNormalized.rawValue
      for account in [personal, work] {
        manager.digest(account: account, history: [], errors: [], failure: nil)
      }

      for account in [personal, work] {
        manager.digest(
          account: account,
          history: [],
          errors: [try syncIssue(path: shared, at: 60)],
          failure: nil
        )
      }

      // The identifier is the request's, and the system replaces a request
      // matching one already delivered. A path shared into both Dropboxes --
      // or a camera roll under the same name -- would otherwise cost one of
      // the two failures its banner, and leave the survivor's Show button
      // opening the wrong account.
      #expect(
        log.notifications.map(\.identifier) == [
          "issue-\(personal.rawValue)-\(normalized)",
          "issue-\(work.rawValue)-\(normalized)"
        ]
      )
      #expect(
        log.notifications.map(\.target) == [
          .item(account: personal, path: shared),
          .item(account: work, path: shared)
        ]
      )
    }
  }

  @Test
  func `a snooze holds a digest and releases it when the window closes`() throws {
    try withManager { manager, log, environment in
      let account = try makeAccount()
      let failure = try #require(AppModel.AccountFailure(AuthenticationFailure.tokenRevoked))
      try snooze(in: environment)

      // Even snoozed, the backlog an account arrives with is not news: the
      // first digest still records its watermarks.
      manager.digest(
        account: account,
        history: [try remoteChange(id: 19, path: "/old.txt")],
        errors: [try syncIssue(path: "/old.mov", at: -60)],
        failure: nil
      )

      manager.digest(
        account: account,
        history: [try remoteChange(id: 20, path: "/a.txt")],
        errors: [try syncIssue(path: "/big.mov", at: 0)],
        failure: failure
      )
      #expect(log.notifications.isEmpty)

      // A snooze defers; it does not consume. Everything it silenced is still
      // owed to the user when the window closes — and nothing that predates
      // the account's first digest comes with it.
      var resumed = NotificationSettings.load(from: environment)
      resumed.cancelSnooze()
      try resumed.save(to: environment)
      manager.digest(
        account: account,
        history: [try remoteChange(id: 20, path: "/a.txt")],
        errors: [try syncIssue(path: "/big.mov", at: 0)],
        failure: failure
      )
      #expect(
        log.notifications.map(\.identifier) == [
          "changes-\(account.rawValue)",
          "issue-\(account.rawValue)-/big.mov",
          "failure-\(account.rawValue)"
        ]
      )
    }
  }

  @Test
  func `the level silences everything less severe than itself`() throws {
    try withManager { manager, log, environment in
      let account = try makeAccount()
      try setLevel(.syncIssues, in: environment)
      manager.digest(account: account, history: [], errors: [], failure: nil)

      manager.digest(
        account: account,
        history: [try remoteChange(id: 30, path: "/a.txt")],
        errors: [try syncIssue(path: "/big.mov", at: 0)],
        failure: nil
      )

      // File changes sit below the sync-issue threshold; the issue clears it.
      #expect(log.notifications.map(\.identifier) == ["issue-\(account.rawValue)-/big.mov"])

      // The level is a standing preference, not a window: what it silenced is
      // gone, and lowering it later doesn't replay yesterday's changes.
      try setLevel(.fileChanges, in: environment)
      manager.digest(
        account: account,
        history: [try remoteChange(id: 30, path: "/a.txt")],
        errors: [try syncIssue(path: "/big.mov", at: 0)],
        failure: nil
      )
      #expect(log.notifications.map(\.identifier) == ["issue-\(account.rawValue)-/big.mov"])
    }
  }

  @Test
  func `a lone change is described by what actually happened to it`() throws {
    try withManager { manager, log, _ in
      let account = try makeAccount()
      manager.digest(account: account, history: [], errors: [], failure: nil)

      manager.digest(
        account: account,
        history: [try remoteChange(id: 50, path: "/Docs/gone.txt", changeType: .removed)],
        errors: [],
        failure: nil
      )
      manager.digest(
        account: account,
        history: [try remoteChange(id: 51, path: "/Docs/new.txt", changeType: .added)],
        errors: [],
        failure: nil
      )

      #expect(log.notifications.map(\.body) == ["“gone.txt” was deleted.", "“new.txt” was added."])
      // The banner has to lead somewhere: the file it is about.
      #expect(
        log.notifications.first?.target == .item(account: account, path: "/Docs/gone.txt")
      )
    }
  }

  @Test
  func `changes one collaborator made are attributed to them and mixed ones are not`() throws {
    try withManager { manager, log, _ in
      let account = try makeAccount()
      let scully = try AccountIdentifier(validating: "dbid:AAH4f99T0taONIc")
      let mulder = try AccountIdentifier(validating: "dbid:AAH4f99T0taONId")
      let names = [scully: "Dana Scully", mulder: "Fox Mulder"]
      manager.digest(account: account, history: [], errors: [], failure: nil)

      manager.digest(
        account: account,
        history: [
          try remoteChange(id: 60, path: "/Case/x.txt", changeType: .added, modifiedBy: scully)
        ],
        errors: [],
        failure: nil,
        changedBy: names
      )

      manager.digest(
        account: account,
        history: [
          try remoteChange(id: 61, path: "/Case/notes.txt", modifiedBy: scully),
          try remoteChange(id: 62, path: "/Case/tape.mov", modifiedBy: scully)
        ],
        errors: [],
        failure: nil,
        changedBy: names
      )

      // Two people's work is nobody's in particular, and neither is a change
      // Dropbox would not name anyone for.
      manager.digest(
        account: account,
        history: [
          try remoteChange(id: 63, path: "/Case/file.txt", modifiedBy: scully),
          try remoteChange(id: 64, path: "/Case/photo.jpg", modifiedBy: mulder)
        ],
        errors: [],
        failure: nil,
        changedBy: names
      )

      manager.digest(
        account: account,
        history: [try remoteChange(id: 65, path: "/Case/anonymous.txt")],
        errors: [],
        failure: nil,
        changedBy: names
      )

      #expect(
        log.notifications.map(\.body) == [
          "Dana Scully added “x.txt”.",
          "Dana Scully changed “notes.txt” and 1 more.",
          "“file.txt” and 1 more changed.",
          "“anonymous.txt” was updated."
        ]
      )
    }
  }

  @Test
  func `the errors level delivers what stopped the account and nothing below it`() throws {
    try withManager { manager, log, environment in
      let account = try makeAccount()
      try setLevel(.errors, in: environment)
      manager.digest(account: account, history: [], errors: [], failure: nil)

      let failure = try #require(AppModel.AccountFailure(AuthenticationFailure.tokenRevoked))
      manager.digest(
        account: account,
        history: [try remoteChange(id: 40, path: "/a.txt")],
        errors: [try syncIssue(path: "/big.mov", at: 0)],
        failure: failure
      )

      // A level that delivers nothing at all would be worse than not offering
      // it: file changes and one item's failure both sit below "Errors only",
      // but a revoked token does not.
      #expect(log.notifications.count == 1)
      let delivered = try #require(log.notifications.first)
      #expect(delivered.kind == .accountFailure)
      #expect(delivered.body == failure.detail)
      #expect(delivered.identifier == "failure-\(account.rawValue)")
      #expect(delivered.target == .account(account))
    }
  }

  @Test
  func `a failure notifies once and says so again only after the account recovers`() throws {
    try withManager { manager, log, _ in
      let account = try makeAccount()
      let failure = try #require(AppModel.AccountFailure(AuthenticationFailure.tokenRevoked))

      manager.digestAccountFailure(account: account, failure: failure)
      #expect(log.notifications.count == 1)

      // Every status refresh reports the same standing failure; it must not
      // become a banner every minute.
      manager.digestAccountFailure(account: account, failure: failure)
      #expect(log.notifications.count == 1)

      // Once the account works again, the next failure is news.
      manager.digestAccountFailure(account: account, failure: nil)
      manager.digestAccountFailure(account: account, failure: failure)
      #expect(log.notifications.count == 2)
    }
  }

  /// Records what a manager would have posted, in the order it composed it.
  @MainActor
  private final class DeliveryLog {
    private(set) var notifications: [NotificationManager.SyncNotification] = []

    func record(_ notification: NotificationManager.SyncNotification) {
      notifications.append(notification)
    }
  }
}
