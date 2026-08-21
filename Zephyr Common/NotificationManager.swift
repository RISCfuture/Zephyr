import Foundation
import UserNotifications
import libZephyr

/**
 Posts user notifications for remote file changes, sync issues, and failures
 that stop an account outright, honoring the configured level and snooze
 window, and tracking per-account watermarks so each event notifies once.

 The level and the snooze silence a notification for different lengths of
 time and so dispose of it differently: a level set above an event drops it,
 and a snooze holds it until the snooze ends.

 Every notification names something the user can be taken to, so tapping the
 banner or its Show button lands on the file or the account it is about.
 */
@MainActor
final class NotificationManager: NSObject {
  /// The notification category carrying the Show button, registered before
  /// the first notification is posted.
  static let categoryIdentifier = "codes.tim.Zephyr.sync"

  private static let showActionIdentifier = "codes.tim.Zephyr.show"
  private static let historyWatermarkKeyPrefix = "notifiedHistoryID-",
    errorWatermarkKeyPrefix = "notifiedErrorTime-",
    failureWatermarkKeyPrefix = "notifiedFailure-"
  nonisolated private static let accountUserInfoKey = "account", pathUserInfoKey = "path"

  private let environment: ZephyrEnvironment
  private let defaults: UserDefaults
  private let deliver: @MainActor (SyncNotification) -> Void
  private var showTarget: (@MainActor (ShowTarget) async -> Void)?
  private var requestedAuthorization = false

  /// Read fresh each time rather than held: the level and the snooze are
  /// shared state, and the Settings pane, a shortcut, and `zephyr` all change
  /// them without telling this manager.
  private var settings: NotificationSettings { .load(from: environment) }

  private var level: NotificationLevel { settings.level }

  /**
   Whether notifications are being held.

   A snooze defers a digest rather than consuming it: the watermarks stay
   where they were, so everything the snooze silenced is still fresh when the
   snooze ends and notifies then. Advancing a watermark for something that was
   never delivered would throw the event away, not postpone it.
   */
  private var isSnoozed: Bool { settings.snoozedUntil != nil }

  /**
   Creates a manager over a preference source, a watermark store, and a
   delivery destination.

   - Parameters:
     - environment: Where the level and snooze deadline are stored, shared
       with the CLI through the app group.
     - defaults: Where the per-account watermarks live; they are this
       process's own bookkeeping, so they stay out of the shared suite.
     - deliver: Handed each composed notification; posts to the system by default.
   */
  init(
    environment: ZephyrEnvironment = .standard,
    defaults: UserDefaults = .standard,
    deliver: @escaping @MainActor (SyncNotification) -> Void =
      NotificationManager.postToNotificationCenter
  ) {
    self.environment = environment
    self.defaults = defaults
    self.deliver = deliver
    super.init()
  }

  private static func postToNotificationCenter(_ notification: SyncNotification) {
    let content = UNMutableNotificationContent()
    content.title = notification.title
    content.body = notification.body
    content.categoryIdentifier = categoryIdentifier
    content.interruptionLevel = notification.kind.interruptionLevel
    content.userInfo = notification.userInfo
    UNUserNotificationCenter.current().add(
      UNNotificationRequest(
        identifier: notification.identifier,
        content: content,
        trigger: nil
      )
    )
  }

  /// The category whose Show button opens what a notification is about.
  private static func makeCategory() -> UNNotificationCategory {
    UNNotificationCategory(
      identifier: categoryIdentifier,
      actions: [
        UNNotificationAction(
          identifier: showActionIdentifier,
          title: String(localized: "Show", bundle: #bundle),
          options: [.foreground]
        )
      ],
      intentIdentifiers: []
    )
  }

  /// The one person every change in a digest belongs to, when the digest has
  /// one and their name is known. Changes several people made are nobody's in
  /// particular, and a digest is not the place to list them.
  private static func collaborator(
    behind events: [HistoryEventRecord],
    named names: [AccountIdentifier: String]
  ) -> String? {
    guard let account = events.first?.modifiedBy,
      events.allSatisfy({ $0.modifiedBy == account })
    else { return nil }
    return names[account]
  }

  /// Installs what a notification's Show button does, and makes tapping the
  /// banner itself do the same.
  func setShowHandler(_ handler: @escaping @MainActor (ShowTarget) async -> Void) {
    showTarget = handler
    UNUserNotificationCenter.current().delegate = self
    UNUserNotificationCenter.current().setNotificationCategories([Self.makeCategory()])
  }

  /// Requests notification authorization once per launch, unless the level is off.
  func requestAuthorizationIfNeeded() {
    guard !requestedAuthorization, level != .none else { return }
    requestedAuthorization = true
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
  }

  /**
   Notifies about an account's activity since the last digest: a summary for
   newly recorded remote changes, one notification per new sync issue, and
   one for a failure that has stopped the account.

   The first digest for an account only records watermarks — the backlog of
   history and sync issues predating the account's first digest must not
   flood the user.

   - Parameter changedBy: Display names for the collaborators a shared file's
     changes belong to, as ``AccountSession/displayNames(ofAccounts:)`` gives
     them. A change nobody can be named for is reported unattributed.
   */
  func digest(
    account: AccountIdentifier,
    history: [HistoryEventRecord],
    errors: [SyncErrorRecord],
    failure: AppModel.AccountFailure?,
    changedBy names: [AccountIdentifier: String] = [:]
  ) {
    digestChanges(account: account, history: history, changedBy: names)
    digestSyncIssues(account: account, errors: errors)
    digestAccountFailure(account: account, failure: failure)
  }

  /**
   Notifies about a failure that stopped the whole account, and forgets the
   last one once the account recovers so the next failure notifies again.

   This is the arm that makes the "Errors only" level mean something: it is
   the only one that posts at ``NotificationLevel/errors``, and it posts time
   sensitively, because nothing syncs until the user acts.
   */
  func digestAccountFailure(account: AccountIdentifier, failure: AppModel.AccountFailure?) {
    let key = Self.failureWatermarkKeyPrefix + account.rawValue
    guard let failure else {
      defaults.removeObject(forKey: key)
      return
    }
    let summary = [failure.title, failure.detail].compactMap(\.self).joined(separator: " ")
    guard defaults.string(forKey: key) != summary else { return }
    guard !isSnoozed else { return }
    defaults.set(summary, forKey: key)
    guard notifies(at: .errors) else { return }
    deliver(
      SyncNotification(
        title: failure.title,
        body: failure.detail
          ?? String(localized: "Syncing has stopped for this account.", bundle: #bundle),
        identifier: "failure-\(account.rawValue)",
        kind: .accountFailure,
        target: .account(account)
      )
    )
  }

  private func digestChanges(
    account: AccountIdentifier,
    history: [HistoryEventRecord],
    changedBy names: [AccountIdentifier: String]
  ) {
    let key = Self.historyWatermarkKeyPrefix + account.rawValue
    let isFirstDigest = defaults.object(forKey: key) == nil
    let watermark = Int64(defaults.integer(forKey: key))
    let latestChangeID = history.compactMap(\.id).max() ?? 0
    // The backlog an account arrives with is never news, snoozed or not, so
    // the first digest records its watermark before anything else is decided.
    guard !isFirstDigest else {
      defaults.set(latestChangeID, forKey: key)
      return
    }
    guard !isSnoozed else { return }
    defaults.set(latestChangeID, forKey: key)
    let fresh = history.filter { ($0.id ?? 0) > watermark && $0.direction == .down }
    guard let newest = fresh.first, notifies(at: .fileChanges) else { return }
    deliver(
      SyncNotification(
        title: String(localized: "Dropbox files changed", bundle: #bundle),
        body: changeSummary(for: fresh, changedBy: names),
        identifier: "changes-\(account.rawValue)",
        kind: .fileChanges,
        target: .item(account: account, path: newest.path.rawValue)
      )
    )
  }

  /// What changed, in the words of the change itself: a digest that says
  /// "updated" about a file Dropbox deleted is worse than saying nothing.
  /// Changes that all belong to one collaborator say whose they are.
  private func changeSummary(
    for events: [HistoryEventRecord],
    changedBy names: [AccountIdentifier: String]
  ) -> String {
    guard let first = events.first else { return "" }
    let name = URL(filePath: first.path.displayPath).lastPathComponent
    guard let collaborator = Self.collaborator(behind: events, named: names) else {
      return unattributedSummary(of: first, named: name, among: events.count)
    }
    return attributedSummary(of: first, named: name, among: events.count, by: collaborator)
  }

  private func unattributedSummary(
    of event: HistoryEventRecord,
    named name: String,
    among count: Int
  ) -> String {
    guard count == 1 else {
      return String(
        localized: "“\(name)” and \(count - 1) more changed.",
        bundle: #bundle
      )
    }
    return switch event.changeType {
      case .added: String(localized: "“\(name)” was added.", bundle: #bundle)
      case .modified: String(localized: "“\(name)” was updated.", bundle: #bundle)
      case .removed: String(localized: "“\(name)” was deleted.", bundle: #bundle)
    }
  }

  private func attributedSummary(
    of event: HistoryEventRecord,
    named name: String,
    among count: Int,
    by collaborator: String
  ) -> String {
    guard count == 1 else {
      return String(
        localized: "\(collaborator) changed “\(name)” and \(count - 1) more.",
        bundle: #bundle
      )
    }
    return switch event.changeType {
      case .added: String(localized: "\(collaborator) added “\(name)”.", bundle: #bundle)
      case .modified:
        String(localized: "\(collaborator) updated “\(name)”.", bundle: #bundle)
      case .removed:
        String(localized: "\(collaborator) deleted “\(name)”.", bundle: #bundle)
    }
  }

  private func digestSyncIssues(account: AccountIdentifier, errors: [SyncErrorRecord]) {
    let key = Self.errorWatermarkKeyPrefix + account.rawValue
    let isFirstDigest = defaults.object(forKey: key) == nil
    let watermark = defaults.double(forKey: key)
    let latestFailure = errors.map(\.occurredAt.timeIntervalSince1970).max() ?? 0
    guard !isFirstDigest else {
      defaults.set(latestFailure, forKey: key)
      return
    }
    guard !isSnoozed else { return }
    defaults.set(latestFailure, forKey: key)
    let fresh = errors.filter { $0.occurredAt.timeIntervalSince1970 > watermark }
    guard !fresh.isEmpty, notifies(at: .syncIssues) else { return }
    for error in fresh {
      deliver(
        SyncNotification(
          title: String(
            localized: "Couldn’t sync “\(URL(filePath: error.path.displayPath).lastPathComponent)”",
            bundle: #bundle
          ),
          body: error.detail ?? error.title,
          // Scoped to the account like every other arm's: the identifier is
          // the request's, and the system replaces a request that matches
          // one already delivered. Two accounts sharing a path — a folder
          // shared into both, a camera upload — would otherwise collapse into
          // one banner, whose Show button would open the wrong Dropbox.
          identifier: "issue-\(account.rawValue)-\(error.pathNormalized.rawValue)",
          kind: .syncIssue,
          target: .item(account: account, path: error.path.rawValue)
        )
      )
    }
  }

  /**
   Whether the configured level carries an event of this severity.

   A level set above an event silences it for good — the user has said they
   never want to hear about it — which is why a digest the level silences
   still consumes its watermark. Only a snooze defers.
   */
  private func notifies(at severity: NotificationLevel) -> Bool {
    level.rawValue <= severity.rawValue
  }

  /// What a notification is about, and how loudly it says so.
  enum Kind: Sendable, Equatable {
    /// Files arrived from Dropbox.
    case fileChanges
    /// One item couldn't sync.
    case syncIssue
    /// Nothing is syncing for the account until the user acts.
    case accountFailure

    var interruptionLevel: UNNotificationInterruptionLevel {
      self == .accountFailure ? .timeSensitive : .active
    }
  }

  /// What a notification's Show button opens.
  enum ShowTarget: Sendable, Equatable {
    /// One item in Finder, addressed by the path Dropbox knows it by.
    case item(account: AccountIdentifier, path: String)
    /// The account itself, when no one item is at fault.
    case account(AccountIdentifier)
  }

  /// One notification composed for delivery.
  struct SyncNotification: Equatable, Sendable {
    let title: String
    let body: String
    let identifier: String
    let kind: Kind
    /// What the Show button opens.
    let target: ShowTarget

    /// The target, flattened into the string pairs a delivered notification
    /// can carry and be read back from.
    var userInfo: [String: String] {
      switch target {
        case let .item(account, path):
          [
            NotificationManager.accountUserInfoKey: account.rawValue,
            NotificationManager.pathUserInfoKey: path
          ]
        case .account(let account):
          [NotificationManager.accountUserInfoKey: account.rawValue]
      }
    }
  }
}

// MARK: Responding to a delivered notification

extension NotificationManager: UNUserNotificationCenterDelegate {
  /// Reads back what ``SyncNotification/userInfo`` wrote, or `nil` when the
  /// notification came from somewhere else.
  nonisolated private static func showTarget(in userInfo: [AnyHashable: Any]) -> ShowTarget? {
    guard let rawAccount = userInfo[accountUserInfoKey] as? String,
      let account = try? AccountIdentifier(validating: rawAccount)
    else { return nil }
    guard let path = userInfo[pathUserInfoKey] as? String else { return .account(account) }
    return .item(account: account, path: path)
  }

  // The delegate declares this one async; there is nothing here to await.
  // swiftlint:disable async_without_await
  /// Shows Zephyr's banners even while Zephyr is the frontmost app: a change
  /// that arrived from Dropbox is news whatever window is open.
  nonisolated func userNotificationCenter(
    _: UNUserNotificationCenter,
    willPresent _: UNNotification
  ) async -> UNNotificationPresentationOptions {
    [.banner, .list]
  }
  // swiftlint:enable async_without_await

  nonisolated func userNotificationCenter(
    _: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse
  ) async {
    guard let target = Self.showTarget(in: response.notification.request.content.userInfo) else {
      return
    }
    await show(target)
  }

  /// Hands a target to the installed handler, on the actor that owns it.
  private func show(_ target: ShowTarget) async {
    await showTarget?(target)
  }
}
