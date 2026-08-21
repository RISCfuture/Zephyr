import AppKit
import FileProvider
import Foundation
import OSLog
import Observation
import WidgetKit
import libZephyr

/**
 The app's observable state: the linked Dropbox accounts, the in-progress link
 flow, and error presentation.
 */
@MainActor
@Observable
final class AppModel {
  /// The `UserDefaults` flag recording that an account has been linked;
  /// launches read it synchronously to decide whether onboarding presents.
  static let hasLinkedAccountsDefaultsKey = "hasLinkedAccounts"

  /// The `UserDefaults` flag recording that first-run setup finished.
  static let hasCompletedSetupDefaultsKey = "hasCompletedSetup"

  /// The `UserDefaults` flag recording that first-run setup was begun, which
  /// is what tells a half-finished run apart from one that never ran.
  static let hasStartedSetupDefaultsKey = "hasStartedSetup"

  /**
   Whether the setup assistant has a run to finish.

   Setup is over when it says so, not when an account appears. Linking is the
   third of its steps, and the ones after it — Finder, notifications, opening
   at login — are exactly what a run abandoned partway leaves undone; treating
   a linked account as the finish line retired the assistant at the moment it
   became useful and never brought it back, leaving Zephyr shut out of Finder
   and closed at login with nothing to say so.

   A Dropbox linked before the assistant existed still retires it. No run was
   ever started there, so there is none to finish.
   */
  private static var hasSetupToFinish: Bool {
    let defaults = UserDefaults.standard
    guard !defaults.bool(forKey: hasCompletedSetupDefaultsKey) else { return false }
    return defaults.bool(forKey: hasStartedSetupDefaultsKey)
      || !defaults.bool(forKey: hasLinkedAccountsDefaultsKey)
  }

  #if DEBUG
    /// The launch argument that swaps in canned accounts for UI tests; in
    /// that mode the model never touches the keychain, domains, or network.
    private static let sampleAccountsArgument = "--uitest-sample-accounts"

    /// The launch argument that keeps first-run setup out of the way, so a UI
    /// test lands on the window it came to drive.
    private static let skipSetupArgument = "--uitest-skip-setup"

    /// The launch argument that presents first-run setup whatever this Mac has
    /// already been through. Setup is otherwise a once-ever window, and the
    /// screenshot suite has to be able to open it again.
    private static let showSetupArgument = "--uitest-show-setup"

    /// The launch argument that presents the sync-issues window on its own.
    /// It is otherwise reached from the accounts window or the menu-bar panel,
    /// and a capture that takes in a window's shadow needs the window it frames
    /// to be the only one on screen.
    private static let showSyncIssuesArgument = "--uitest-show-sync-issues"

    /// What precedes the design-layer surface to present, as
    /// `--uitest-show-design=file-versions`. The subject follows an `=` rather
    /// than arriving as a token of its own, so nothing can read the argument
    /// after this one as its value.
    private static let showDesignArgumentPrefix = "--uitest-show-design="
  #endif

  /// How often the marks re-sample sync activity.
  private static let activitySamplingInterval: Duration = .seconds(60)

  /**
   How often Zephyr digests every account of its own accord.

   The digest otherwise runs only after a remote change arrives, which is
   exactly what stops arriving when the change watcher is failing. This is
   the clock that gets a stopped account, and the issues the File Provider
   extension recorded while nobody was looking, in front of the user without
   the menu being opened.
   */
  private static let digestInterval: Duration = .seconds(15 * 60)

  /// How many history rows a digest reads; more than a notification could
  /// ever summarize, and enough to count what arrived between two digests.
  private static let digestHistoryLimit: UInt = 50

  /// How long a passing credential check stands before Zephyr asks Dropbox
  /// again. Only the check itself reaches the network, so it runs on a much
  /// slower clock than the readouts it corrects.
  private static let credentialCheckInterval: TimeInterval = 15 * 60

  /// Whether this launch runs on canned UI-test accounts. Always `false` in a
  /// release build, which carries neither the launch arguments nor the data.
  static var launchesWithSampleAccounts: Bool {
    #if DEBUG
      ProcessInfo.processInfo.arguments.contains(sampleAccountsArgument)
    #else
      false
    #endif
  }

  /// Whether this launch was told to skip first-run setup.
  static var launchesWithSetupSuppressed: Bool {
    #if DEBUG
      launchesWithSampleAccounts
        || ProcessInfo.processInfo.arguments.contains(skipSetupArgument)
    #else
      false
    #endif
  }

  /// Whether this launch was told to present first-run setup regardless of
  /// what this Mac has already completed. Always `false` in a release build,
  /// which carries no such launch argument.
  static var launchesWithSetupPresented: Bool {
    #if DEBUG
      ProcessInfo.processInfo.arguments.contains(showSetupArgument)
    #else
      false
    #endif
  }

  /// Whether this launch was told to present the sync-issues window. Always
  /// `false` in a release build, which carries no such launch argument.
  static var launchesWithSyncIssuesPresented: Bool {
    #if DEBUG
      ProcessInfo.processInfo.arguments.contains(showSyncIssuesArgument)
    #else
      false
    #endif
  }

  #if DEBUG
    /**
     Which design-layer surface this launch was told to present, or `nil` when
     it was told to present none.

     An unrecognized subject is a mistake in the test rather than a reason to
     open an empty window and photograph it, so it stops the run.
     */
    static var presentedDesignSubject: DesignGallery.Subject? {
      guard
        let argument = ProcessInfo.processInfo.arguments
          .first(where: { $0.hasPrefix(showDesignArgumentPrefix) })
      else { return nil }
      let raw = String(argument.dropFirst(showDesignArgumentPrefix.count))
      guard let subject = DesignGallery.Subject(rawValue: raw) else {
        preconditionFailure("Unrecognized \(showDesignArgumentPrefix)\(raw).")
      }
      return subject
    }
  #endif

  /// Whether this launch was told to present a design-layer surface. Always
  /// `false` in a release build, which carries no such launch argument.
  static var launchesWithDesignPresented: Bool {
    #if DEBUG
      presentedDesignSubject != nil
    #else
      false
    #endif
  }

  /// Whether this launch is presenting a window of its own instead of the
  /// accounts window, which would otherwise open behind it.
  static var launchesWithAnotherWindowPresented: Bool {
    launchesWithSetupPresented || launchesWithSyncIssuesPresented
      || launchesWithDesignPresented
  }

  /// How far back a diagnostics report reaches into this process's log.
  nonisolated private static let diagnosticLogWindow: TimeInterval = 60 * 60

  /// The unified-logging subsystem every Zephyr process logs under.
  nonisolated private static let logSubsystemPrefix = "codes.tim.Zephyr"

  /// The configurations of the accounts this app can authenticate, sorted by display name.
  var accounts: [AccountConfiguration] = []

  /// The notification level and snooze deadline, which every Zephyr process
  /// shares.
  var notificationSettings = NotificationSettings()

  /**
   The Mac's transfer limits, which every account's syncing shares.

   Held here rather than read straight from the file by the Settings pane so a
   canned-data launch shows the defaults instead of whatever this Mac actually
   syncs at — a screenshot should not depend on the machine that took it.
   */
  var bandwidth = BandwidthSettings()

  /// Per-account sync summaries, refreshed on menu open and after remote changes.
  var accountStatuses: [AccountIdentifier: AccountStatus] = [:]

  /**
   Linked accounts whose configuration wouldn't load.

   They are missing from ``accounts`` because nothing about them can be
   read — not their email, not their display name — so they get a row of
   their own rather than disappearing from the window.
   */
  var unreadableAccounts: [AccountIdentifier] = []

  /// A user-facing error to present in an alert, or `nil` when none is pending.
  var alertMessage: String?

  /// The approvals macOS is withholding, refreshed whenever a surface that
  /// reports them appears and whenever Zephyr comes back to the front.
  var withheldApprovals: [SystemApproval] = []

  /**
   What the accounts window's link sheet is open for, or `nil` when it is
   closed. The Account menu raises it as well as the window's own button.

   The sheet carries the intent rather than merely a flag, because what the
   user pressed is the only record of which account they meant: Dropbox's
   page approves whoever the browser is signed in as, and would otherwise
   re-authorize a healthy account under the heading of adding another or
   repairing a third.
   */
  var linkIntent: LinkIntent?

  /// When the marks last sampled sync activity. It advances on its own so a
  /// mark settles from syncing back to up to date as the last change ages,
  /// without waiting on a sync to redraw it.
  private(set) var activitySampleDate = Date()

  /// Whether the user has stopped syncing: every File Provider domain is
  /// disconnected, so Finder serves what it has and asks for nothing more.
  private(set) var isSyncPaused = false

  /// The link flow awaiting its authorization code, or `nil` when none is active.
  private(set) var pendingLink: PendingLink?

  /// What this edition is allowed to do.
  let featureFlags: FeatureFlags

  /// Checks GitHub for newer Zephyr releases, or `nil` in the App Store build,
  /// which the store keeps current. Settings drives its UI.
  let updates: (any UpdateChecking)?

  /**
   Whether first-run setup still owes the user its pages.

   Decided once, at launch: linking an account part-way through setup must
   not retire it early, and nothing else may raise a system prompt ahead of
   the page that explains it. An install that already has a linked account
   was set up before setup existed, so it counts as finished.
   */
  let isSetupPending: Bool

  private let manager: AccountManager
  private let watcher: DomainWatcher
  private let notifications = NotificationManager()

  /// Whether this model runs on canned data — UI tests and previews — and so
  /// never reaches for the keychain, the domains, or the network.
  private let usesSampleAccounts: Bool

  /// When Dropbox last confirmed an account's credentials, or `nil` before
  /// the first check.
  private var lastCredentialCheck: Date?

  /// How many items each account is still waiting to send to Dropbox, as the
  /// File Provider pending set reports it. An account whose pending set has
  /// never been read is absent, which reads as "not known" rather than zero.
  private var pendingUploads: [AccountIdentifier: UInt] = [:]

  /// One task per linked account, following what the File Provider extension
  /// commits to that account's index.
  private var indexWatchers: [AccountIdentifier: Task<Void, Never>] = [:]

  /// What the last credential check found wrong with each account; only
  /// accounts Dropbox refused appear.
  private var verifiedFailures: [AccountIdentifier: AccountFailure] = [:]

  /// When each account last lost touch with Dropbox; an account that is
  /// reaching it is absent. An outage is dated rather than counted so a wait
  /// that has gone on long enough to be worth naming can be told from the
  /// ordinary gap around a sleep.
  private var outagesSince: [AccountIdentifier: Date] = [:]

  /// Why each account is holding back, for the accounts that are. Unlike an
  /// outage this is not dated: it is a decision Zephyr is making right now,
  /// not a wait whose length says anything — so what it carries is the
  /// reason, which the user can act on.
  private var deferredAccounts: [AccountIdentifier: NetworkCostRefusal] = [:]

  init(
    featureFlags: FeatureFlags,
    updates: (any UpdateChecking)? = nil,
    usesSampleAccounts: Bool = AppModel.launchesWithSampleAccounts
  ) {
    self.featureFlags = featureFlags
    self.updates = updates
    self.usesSampleAccounts = usesSampleAccounts
    isSetupPending =
      Self.launchesWithSetupPresented
      || (!Self.launchesWithSetupSuppressed && Self.hasSetupToFinish)
    let manager = AccountManager(tokenStore: GroupKeychainTokenStore())
    self.manager = manager
    watcher = DomainWatcher(manager: manager)
    if !usesSampleAccounts {
      bandwidth = BandwidthSettings.load()
      notificationSettings = NotificationSettings.load()
      // Reaching the notification center at all needs a real app bundle, so
      // canned-data launches — previews, UI tests — stay away from it.
      notifications.setShowHandler { [weak self] target in
        await self?.show(target)
      }
      startClocks()
      watchPendingSet()
      watchStoredSettings()
      watchSyncPause()
    }
  }

  /// Formats an error for presentation: its general description plus the case-specific reason.
  /// An alert offers its own remedy, so it leaves the recovery suggestion out.
  static func alertText(for error: any Error) -> String {
    ErrorSentence.describe(error)
  }

  /**
   Stores a change to the notification settings, which every Zephyr process
   reads.

   A canned-data launch keeps its defaults, for the reason ``setBandwidth(_:)``
   does.
   */
  func setNotificationSettings(_ settings: NotificationSettings) {
    notificationSettings = settings
    guard !usesSampleAccounts else { return }
    do {
      try settings.save()
    } catch {
      alertMessage = Self.alertText(for: error)
    }
  }

  /**
   Stores a change to the Mac's transfer limits, and lets the sessions
   already running pick it up.

   A canned-data launch keeps its defaults: a UI test dragging a slider must
   not write the limits this Mac really syncs at.
   */
  func setBandwidth(_ settings: BandwidthSettings) {
    bandwidth = settings
    guard !usesSampleAccounts else { return }
    do {
      try settings.save()
    } catch {
      alertMessage = Self.alertText(for: error)
    }
  }

  /**
   Loads the linked accounts' configurations and, when the load succeeds,
   reconciles the File Provider domains and the change watchers.
   */
  func load() async {
    await refreshLinkedState()
  }

  /// The sync state of one account, summarized for the menu-bar panel.
  struct AccountStatus: Sendable, Equatable {
    var files: UInt = 0
    var folders: UInt = 0
    /// Every item that couldn't sync, newest first.
    var syncErrors: [SyncErrorRecord] = []
    var latestChange: Date?
    /// What stopped the whole account, or `nil` while it syncs.
    var accountFailure: AccountFailure?
    /// When the account last lost touch with Dropbox, or `nil` while it can
    /// reach it. Being out of touch is a state and not a failure: it lifts on
    /// its own, so it reads in the account's activity rather than here.
    var offlineSince: Date?
    /// Why syncing is holding back over what the network costs, or `nil`
    /// while nothing is. Like an outage, a state rather than a failure — and
    /// unlike one, it can say why.
    var networkCostRefusal: NetworkCostRefusal?

    var isWaitingForCheaperNetwork: Bool { networkCostRefusal != nil }

    var syncErrorCount: UInt { UInt(syncErrors.count) }

    /// Whether anything about this account wants the user's attention.
    var needsAttention: Bool { accountFailure != nil || !syncErrors.isEmpty }
  }

  /**
   A failure that stops an account syncing altogether, as opposed to one item
   failing: a revoked token, an unreachable Dropbox, an index that won't open.

   It is built only from the fatal and authentication tiers, so an ordinary
   item failure can never be mistaken for one.
   */
  struct AccountFailure: Sendable, Equatable {
    /// What happened, in the error's own words.
    let title: String
    /// Why, when the error said.
    let detail: String?
    /// Whether linking the account again is what clears it.
    let isResolvedByRelinking: Bool

    /// Describes an error that halts an account, or fails to build from one
    /// that only concerns a single item.
    init?(_ error: any Error) {
      guard Self.haltsSyncing(error), !Self.resolvesWithoutUser(error) else { return nil }
      let localized = error as? any LocalizedError
      title =
        localized?.errorDescription
        ?? String(localized: "Syncing stopped.", bundle: #bundle)
      detail =
        [localized?.failureReason, localized?.recoverySuggestion]
        .compactMap(\.self)
        .joined(separator: " ")
        .nilIfEmpty
      isResolvedByRelinking = error is any AuthError
    }

    /// Describes the failure the File Provider extension recorded, which it
    /// already classified as account-wide before storing it.
    init(_ record: EngineErrorRecord) {
      title = record.title
      detail = record.detail
      // The extension stores the error's text, not its type; relinking is
      // offered by the app's own check, which still holds the error itself.
      isResolvedByRelinking = false
    }

    /**
     Describes a change watcher that has stopped hearing from Dropbox, or
     fails to build from a poll whose trouble is not the account's.

     A poll that failed only because nothing could reach Dropbox never builds
     one, however long the run: an outage lifts on its own and reads as the
     account's state instead. Of what remains, an error from the fatal tier
     stops the account the first time it is thrown, because waiting to be
     sure about a revoked token leaves the user staring at a Dropbox that
     silently gave up. Errors below that tier — a timeout, a rate limit — are
     weather on any one poll and mean nothing on their own; a run of them
     means nothing is reaching Dropbox at all, which stops the account
     whatever each individual error was.
     */
    init?(_ poll: DomainWatcher.PollFailure) {
      guard !poll.resolvesWithoutUser else { return nil }
      if let fatal = Self(poll.error) {
        self = fatal
        return
      }
      guard poll.isPersistent else { return nil }
      title = String(localized: "Zephyr isn’t hearing from Dropbox.", bundle: #bundle)
      detail =
        (poll.error as? any LocalizedError)?.failureReason
        ?? poll.error.localizedDescription
      isResolvedByRelinking = false
    }

    private static func haltsSyncing(_ error: any Error) -> Bool {
      if let fatal = error as? any SyncFatalError { return fatal.haltsSync }
      return error is any AuthError
    }

    /**
     Whether the error lifts on its own — the network being away — rather than
     needing the user to put something right.

     Nothing that lifts on its own is an account failure, whatever tier the
     error belongs to. A sleeping or roaming Mac must not spend the one
     notification kept for a Dropbox that has genuinely stopped, whichever path
     the error arrives by — a failed poll, the credential check, or a failed
     index read.
     */
    private static func resolvesWithoutUser(_ error: any Error) -> Bool {
      (error as? any SyncFatalError)?.resolvesWithoutUser ?? false
    }
  }

  /**
   An in-progress account link: both of the flows the link form offers, either
   of which the user may be the one to finish.

   Two flows rather than one swapped between, because the redirect style decides
   whether the authorization URL carries a `redirect_uri` and Dropbox holds the
   token exchange to the same one — so a flow begun in one style can never be
   finished in the other. Beginning both costs a PKCE verifier and a CSRF token
   and reaches nothing outside the process.
   */
  struct PendingLink {
    /// The flow the web authentication session runs, which Dropbox answers by
    /// redirecting back to the app.
    let session: LinkFlow

    /// The flow that ends in a code printed on dropbox.com for the user to
    /// paste, which the form offers under the other one.
    let code: LinkFlow
  }
}

// MARK: Loading

extension AppModel {
  /// Rereads which approvals macOS is withholding, so a grant made in System
  /// Settings clears its notice on the way back.
  func auditApprovals() async {
    guard !usesSampleAccounts else { return }
    withheldApprovals = await SystemApprovalAudit.withheldApprovals()
  }

  private func refreshLinkedState() async {
    #if DEBUG
      if usesSampleAccounts {
        accounts = PreviewHelper.sampleAccounts
        accountStatuses = PreviewHelper.sampleStatuses(for: accounts)
        return
      }
    #endif
    guard await refreshAccounts() else { return }
    UserDefaults.standard.set(!accounts.isEmpty, forKey: Self.hasLinkedAccountsDefaultsKey)
    await reconcileDomains()
    await watcher.setRemoteChangeHandler { [weak self] account in
      await self?.handleRemoteChanges(for: account)
    }
    await watcher.setPollFailureHandler { [weak self] account, failure in
      await self?.recordPollFailure(for: account, failure)
    }
    await watcher.setPollSuccessHandler { [weak self] account in
      await self?.recordPollSucceeded(for: account)
    }
    let linked = accounts.map(\.accountID)
    await watcher.watch(linked)
    watchIndexes(of: linked)
    // Setup asks for notifications on a page of its own, after explaining
    // why; a prompt raised from here would beat it to the screen.
    if !accounts.isEmpty, !isSetupPending {
      notifications.requestAuthorizationIfNeeded()
    }
    await refreshStatuses()
    await verifyCredentials()
    await auditApprovals()
  }

  /// Matches the registered File Provider domains to the loaded accounts.
  private func reconcileDomains() async {
    do {
      try await DomainManager.reconcile(with: accounts)
    } catch {
      alertMessage = Self.alertText(for: error)
    }
  }

  /// Reloads `accounts`, returning whether the load succeeded; a failure
  /// surfaces its error and leaves the previous list untouched.
  private func refreshAccounts() async -> Bool {
    do {
      accounts = try await authenticatableConfigurations()
      return true
    } catch {
      alertMessage = Self.alertText(for: error)
      return false
    }
  }

  /**
   Loads every authenticatable account's configuration at once.

   A configuration that won't load costs only its own account, which is
   listed in ``unreadableAccounts``: one bad file must not take the whole
   load down and leave the window claiming nothing is linked.
   */
  private func authenticatableConfigurations() async throws -> [AccountConfiguration] {
    let authenticatable = try await manager.authenticatableAccounts()
    let loaded = await loadedConfigurations(of: authenticatable)
    unreadableAccounts = authenticatable.filter { loaded[$0] == nil }
    return loaded.values.sorted {
      $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
    }
  }

  /// Every configuration that loads, keyed by the account it belongs to; an
  /// account whose configuration won't load is absent.
  private func loadedConfigurations(
    of accounts: [AccountIdentifier]
  ) async -> [AccountIdentifier: AccountConfiguration] {
    await withTaskGroup(
      of: (account: AccountIdentifier, configuration: AccountConfiguration?).self
    ) { group in
      for account in accounts {
        group.addTask { (account, await self.loadedConfiguration(for: account)) }
      }
      var configurations: [AccountIdentifier: AccountConfiguration] = [:]
      for await loaded in group {
        configurations[loaded.account] = loaded.configuration
      }
      return configurations
    }
  }

  private func loadedConfiguration(for account: AccountIdentifier) async -> AccountConfiguration? {
    try? await manager.configuration(for: account)
  }
}

// MARK: Linking accounts

extension AppModel {
  /**
   Starts the link flows and exposes their authorization URLs for the form.

   Both flows carry ``linkIntent``, so whichever way the user completes the
   link — the redirect or the pasted code — an approval by the wrong account
   is refused. First-run setup shows the form with no sheet to set one, and
   the account it links is by definition the first.
   */
  func beginLink() async {
    let intent = linkIntent ?? .newAccount
    pendingLink = PendingLink(
      session: await manager.beginLink(redirect: .customScheme, for: intent),
      code: await manager.beginLink(redirect: .outOfBand, for: intent)
    )
  }

  /// Abandons the in-progress link flow.
  func cancelLink() {
    pendingLink = nil
  }

  /**
   Runs the in-progress link's authorization page in a web authentication
   session and links the account it comes back authorizing.

   - Throws: `CancellationError` when the user closes the page without
     approving, and the authorization or exchange failure otherwise. The flow
     stays active either way, so the form can offer another attempt.
   */
  func authorize() async throws {
    guard let flow = pendingLink?.session, let callbackScheme = flow.callbackScheme else { return }
    let callbackURL = try await WebAuthSession()
      .authorize(url: flow.authorizationURL, callbackScheme: callbackScheme)
    try await finishLink { try await flow.complete(callbackURL: callbackURL) }
  }

  /**
   Completes the in-progress link with the pasted authorization code.

   - Throws: when Dropbox rejects the code; the flow stays active for a retry.
   */
  func completeLink(code: String) async throws {
    guard let flow = pendingLink?.code else { return }
    try await finishLink { try await flow.complete(code: code) }
  }

  /**
   Retires the link flow that `link` completes, then refreshes the account list,
   the File Provider domains, and the change watchers.

   The flow is retired only once `link` has returned an account: a failure
   leaves it in place, which is what lets the form offer the same flow again
   rather than starting the user over.
   */
  private func finishLink(_ link: () async throws -> AccountSession) async throws {
    let session = try await link()
    pendingLink = nil
    await refreshLinkedState()
    // The domain now exists and its credentials are fresh, so any failure
    // the system is still reporting for it is stale.
    await DomainManager.signalErrorsResolved(for: session.accountID)
  }

  /// Unlinks an account: removes its File Provider domain, then revokes and forgets it.
  func unlink(_ account: AccountIdentifier) async {
    if usesSampleAccounts {
      accounts.removeAll { $0.accountID == account }
      return
    }
    do {
      try await DomainManager.removeDomain(for: account)
      try await manager.unlink(account)
    } catch {
      alertMessage = Self.alertText(for: error)
    }
    await refreshLinkedState()
  }
}

// MARK: Clocks

extension AppModel {
  /// Starts the model's two background clocks: the fast one that keeps the
  /// readouts honest, and the slow one that notifies without being asked.
  private func startClocks() {
    schedule(every: Self.activitySamplingInterval) { model in
      model.activitySampleDate = Date()
      await model.verifyCredentialsIfStale()
      // The mark reports what macOS is withholding, and macOS is switched in
      // System Settings rather than here. Without this the mark would carry a
      // grant that had been revoked until something else happened to ask.
      await model.auditApprovals()
    }
    schedule(every: Self.digestInterval) { await $0.digestEveryAccount() }
  }

  /// Runs `work` on a fixed period until the model goes away.
  private func schedule(
    every interval: Duration,
    _ work: @escaping @Sendable @MainActor (AppModel) async -> Void
  ) {
    Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: interval)
        guard let self else { return }
        await work(self)
      }
    }
  }
}

// MARK: Sync status

extension AppModel {
  /// When every account went out of touch, or `nil` unless they all are. One
  /// account being unreachable while another syncs is that account's story,
  /// not the Mac's, and the menu-bar mark speaks for the Mac.
  private var sharedOutageSince: Date? {
    let outages = accountStatuses.values.map(\.offlineSince)
    guard !outages.isEmpty, outages.allSatisfy({ $0 != nil }) else { return nil }
    return outages.compactMap(\.self).max()
  }

  /// Whether every account is holding back over what the network costs. One
  /// account waiting while another syncs is that account's story, and the
  /// menu-bar mark speaks for the Mac.
  private var isEveryAccountWaitingForCheaperNetwork: Bool {
    !accountStatuses.isEmpty
      && accountStatuses.values.allSatisfy(\.isWaitingForCheaperNetwork)
  }

  /// Whether anything is in place to sync with: an account to sync, and a
  /// Finder that macOS will let Zephyr serve it to. Every other reading
  /// assumes both, and would otherwise call an account that cannot sync at
  /// all up to date.
  private var canSync: Bool {
    !accounts.isEmpty && !withheldApprovals.contains(.finderExtension)
  }

  /**
   Refreshes every account's menu-bar summary from its index, read-only, and
   republishes the widget's snapshot.

   A refresh cancelled partway has read an account it could not finish
   reading, and summarizes it as empty. Publishing that would empty the menu
   bar and the widget over a panel the user merely closed, so a cancelled
   refresh leaves the last good summaries standing.
   */
  func refreshStatuses() async {
    guard !usesSampleAccounts else { return }
    let statuses = await statusesOfEveryAccount()
    guard !Task.isCancelled else { return }
    accountStatuses = statuses
    isSyncPaused = await DomainConnection.areAllDisconnected()
    publishWidgetSnapshot()
  }

  /// One account's sync activity: what it still owes Dropbox, and whether any
  /// of its items couldn't sync.
  func activity(for account: AccountIdentifier, asOf now: Date = Date()) -> SyncActivity {
    let status = accountStatuses[account]
    return SyncActivity(
      latestChange: status?.latestChange,
      hasIssues: status?.needsAttention ?? false,
      pendingUploads: pendingUploads[account],
      offlineSince: status?.offlineSince,
      isWaitingForCheaperNetwork: status?.isWaitingForCheaperNetwork ?? false,
      canSync: canSync,
      asOf: now
    )
  }

  /// The reading the menu-bar mark flies: everything every account still owes
  /// Dropbox, and caution whenever any account has something wrong with it.
  func activity(asOf now: Date = Date()) -> SyncActivity {
    SyncActivity(
      latestChange: accountStatuses.values.compactMap(\.latestChange).max(),
      hasIssues: !unreadableAccounts.isEmpty
        || accountStatuses.values.contains(where: \.needsAttention),
      pendingUploads: totalPendingUploads,
      offlineSince: sharedOutageSince,
      isWaitingForCheaperNetwork: isEveryAccountWaitingForCheaperNetwork,
      canSync: canSync,
      asOf: now
    )
  }

  /// Summarizes every account at once: each summary opens and reads that
  /// account's index, and one slow index must not hold up the rest.
  private func statusesOfEveryAccount() async -> [AccountIdentifier: AccountStatus] {
    await withTaskGroup(of: (account: AccountIdentifier, status: AccountStatus).self) { group in
      for account in accounts.map(\.accountID) {
        group.addTask { (account, await self.status(of: account)) }
      }
      var statuses: [AccountIdentifier: AccountStatus] = [:]
      for await summary in group {
        statuses[summary.account] = summary.status
      }
      return statuses
    }
  }

  /// Writes the widget's snapshot to the shared container and reloads its timeline.
  private func publishWidgetSnapshot() {
    let summaries = accounts.map { account in
      let status = accountStatuses[account.accountID]
      return SyncStatusSnapshot.AccountStatus(
        id: account.accountID.rawValue,
        displayName: account.displayName,
        files: status?.files ?? 0,
        folders: status?.folders ?? 0,
        syncErrorCount: status?.syncErrorCount ?? 0,
        latestChange: status?.latestChange,
        pendingUploads: pendingUploads[account.accountID],
        syncIssues: (status?.syncErrors ?? []).map(SyncStatusSnapshot.SyncIssue.init),
        accountFailure: status?.accountFailure?.title
      )
    }
    try? SyncStatusSnapshot(accounts: summaries).write()
    WidgetCenter.shared.reloadTimelines(ofKind: SyncStatusSnapshot.widgetKind)
  }

  /**
   Summarizes one account from its index, keeping the failure that stopped
   the whole account apart from the items that couldn't sync.

   The credentials this reads through — and the index itself — can fail in
   ways that are nothing to do with any one file, and those must not read as
   an empty account.
   */
  private func status(of account: AccountIdentifier) async -> AccountStatus {
    var status = AccountStatus(
      accountFailure: verifiedFailures[account],
      offlineSince: outagesSince[account],
      networkCostRefusal: deferredAccounts[account]
    )
    do {
      guard let store = try await readOnlyIndex(for: account) else { return status }
      (status.files, status.folders) = try await store.counts()
      status.syncErrors = try await store.syncErrors()
      status.latestChange = try await store.recentHistory(limit: 1).first?.recordedAt
      // The app's own check reaches the network and is the fresher answer;
      // this is what the extension saw while the app was not looking.
      if status.accountFailure == nil,
        let stopped = try await store.engineError()
      {
        status.accountFailure = AccountFailure(stopped)
      }
    } catch {
      status.accountFailure = AccountFailure(error) ?? status.accountFailure
    }
    return status
  }

  private func readOnlyIndex(for account: AccountIdentifier) async throws -> SyncIndexStore? {
    let session = try await manager.session(for: account)
    guard session.indexExists else { return nil }
    return try await session.openIndex(mode: .readOnly)
  }
}

// MARK: Revealing in Finder

extension AppModel {
  /// Reveals an account's File Provider domain root in Finder.
  func revealInFinder(_ account: AccountIdentifier) async {
    guard let domain = try? await DomainManager.domain(for: account),
      let manager = NSFileProviderManager(for: domain),
      let url = try? await manager.getUserVisibleURL(for: .rootContainer)
    else { return }
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  /// Reveals the item an issue is about, so the user can look at it.
  func revealItem(atPath path: NormalizedDropboxPath, in account: AccountIdentifier) async {
    guard let store = try? await readOnlyIndex(for: account),
      let entry = try? await store.entry(forPath: path)
    else {
      await revealInFinder(account)
      return
    }
    await reveal(entry.dbxID, in: account)
  }

  private func reveal(_ item: DropboxFileIdentifier, in account: AccountIdentifier) async {
    guard
      let url = await DomainManager.userVisibleURL(
        of: NSFileProviderItemIdentifier(item.rawValue),
        in: account
      )
    else {
      await revealInFinder(account)
      return
    }
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }
}

// MARK: Change digests

extension AppModel {
  /**
   Runs after the watcher signals a remote change.

   A signal that arrives is proof that the account authenticates and Dropbox
   is reachable, so it retires whatever failure was standing. Reading the
   index is left to ``watchIndexes(of:)``, which hears about the pages once
   the extension has actually applied them.
   */
  private func handleRemoteChanges(for account: AccountIdentifier) async {
    await recordCredentialsVerified(for: account)
  }

  /**
   Digests every account without waiting for a remote change to arrive.

   Remote changes are what usually drives the digest, and they stop arriving
   for exactly the accounts worth notifying about: one whose watcher can no
   longer reach Dropbox never signals again, and the issues the File Provider
   extension recorded in the meantime would otherwise wait for the user to
   open the menu.
   */
  private func digestEveryAccount() async {
    guard !usesSampleAccounts else { return }
    await refreshStatuses()
    await withTaskGroup(of: Void.self) { group in
      for account in accounts.map(\.accountID) {
        group.addTask { await self.digest(account) }
      }
    }
  }

  /// Hands one account's recent history, standing sync issues, and failure to
  /// the notifier, which decides what is worth saying.
  private func digest(_ account: AccountIdentifier) async {
    guard let store = try? await readOnlyIndex(for: account) else { return }
    let history = (try? await store.recentHistory(limit: Self.digestHistoryLimit)) ?? []
    let errors = (try? await store.syncErrors()) ?? []
    notifications.digest(
      account: account,
      history: history,
      errors: errors,
      failure: accountStatuses[account]?.accountFailure,
      changedBy: await collaboratorNames(behind: history, for: account)
    )
  }

  /// Names the collaborators a digest's changes can be attributed to. The
  /// account's own changes are not attributed: a notification that tells the
  /// user they changed a file themselves says nothing.
  private func collaboratorNames(
    behind history: [HistoryEventRecord],
    for account: AccountIdentifier
  ) async -> [AccountIdentifier: String] {
    let collaborators = history.compactMap(\.modifiedBy).filter { $0 != account }
    guard !collaborators.isEmpty,
      let session = try? await manager.session(for: account)
    else { return [:] }
    return await session.displayNames(ofAccounts: collaborators)
  }
}

// MARK: Outbound backlog

extension AppModel {
  /// Everything every account is waiting to send, or `nil` until at least one
  /// account's pending set has been read.
  var totalPendingUploads: UInt? {
    pendingUploads.isEmpty ? nil : pendingUploads.values.reduce(0, +)
  }

  /**
   Follows the File Provider pending set, so the marks report the backlog the
   system measured rather than the age of the last change they saw.

   The pending set is the outbound half of syncing and the only half the app
   can see: it holds the items the system has taken from disk and not yet
   handed to the extension. Content coming the other way is materialized
   inside the extension, which reports its progress to Finder and to nobody
   else.

   The system posts its notification once the set has settled — never at the
   moment an item becomes pending — so this is a readout, not a trigger.
   */
  private func watchPendingSet() {
    Task { [weak self] in
      await self?.refreshPendingUploads()
      let changes = NotificationCenter.default.notifications(
        named: .fileProviderPendingSetDidChange
      )
      for await _ in changes {
        guard let self else { return }
        await refreshPendingUploads()
      }
    }
  }

  /**
   Follows what the File Provider extension commits to each account's index,
   and retires the watchers of accounts that are no longer linked.

   The extension is the only process that writes an index, so this is how the
   app hears what only the extension discovers: a sync error, an upload Finder
   started, a delta page that landed between two digests. Without it such a
   change waits for the panel to be opened or for the digest clock.

   The signals arrive coalesced, because an account being indexed for the
   first time commits a page at a time and each refresh here reads every
   account's index.
   */
  private func watchIndexes(of linked: [AccountIdentifier]) {
    for (account, watcher) in indexWatchers where !linked.contains(account) {
      watcher.cancel()
      indexWatchers[account] = nil
    }
    for account in linked where indexWatchers[account] == nil {
      let commits = ChangeSignal.index(account).coalescedSignals()
      indexWatchers[account] = Task { [weak self] in
        for await _ in commits {
          guard let self else { return }
          await refreshStatuses()
          await digest(account)
        }
      }
    }
  }

  /**
   Follows the settings other processes change: `zephyr notify` and the Snooze
   intent write the notification level, `zephyr bandwidth-limit` writes the
   transfer limits. The app reads both once at launch, so without this its
   Settings pane goes on showing what they said then.

   Each adopts only a value that differs from the one on screen, so the app's
   own write — which posts the same signal — does not churn the view that made
   it.
   */
  private func watchStoredSettings() {
    Task { [weak self] in
      for await _ in ChangeSignal.notificationSettings.signals() {
        guard let self else { return }
        let stored = NotificationSettings.load()
        guard stored != notificationSettings else { continue }
        notificationSettings = stored
      }
    }
    Task { [weak self] in
      for await _ in ChangeSignal.transferLimits.signals() {
        guard let self else { return }
        let stored = BandwidthSettings.load()
        guard stored != bandwidth else { continue }
        bandwidth = stored
      }
    }
  }

  /**
   Follows syncing being paused from outside the panel: Control Center's toggle
   and the Pause Syncing shortcut both disconnect the domains themselves rather
   than routing through this model.

   Without it the panel's Pause Syncing row goes on showing what syncing was
   doing when it was last refreshed, which for a menu that opens on demand can
   be a long time after the reader paused it somewhere else.
   */
  private func watchSyncPause() {
    Task { [weak self] in
      for await _ in ChangeSignal.syncPaused.signals() {
        guard let self else { return }
        let paused = await DomainConnection.areAllDisconnected()
        guard paused != isSyncPaused else { continue }
        isSyncPaused = paused
      }
    }
  }

  /// Re-reads every account's pending set and republishes the marks.
  private func refreshPendingUploads() async {
    guard !usesSampleAccounts else { return }
    pendingUploads = await DomainManager.pendingItemCounts()
    activitySampleDate = Date()
  }
}

// MARK: Credentials

extension AppModel {
  /**
   Asks Dropbox to confirm every account, so a revoked token or a dead
   network reads as one account-wide failure rather than as an account that
   simply has nothing to report.

   This is the only status work that reaches the network. Confirming an
   account also retires the failure the File Provider latched onto its
   domain, which nothing else takes back.
   */
  func verifyCredentials() async {
    guard !usesSampleAccounts else { return }
    lastCredentialCheck = Date()
    verifiedFailures = await failuresOfEveryAccount()
    await refreshStatuses()
    notifyOfAccountFailures()
  }

  /// Re-checks the accounts once the last check has aged out, and always
  /// while one of them is failing — a failure the user has since fixed
  /// should clear on its own.
  func verifyCredentialsIfStale() async {
    guard let lastCredentialCheck else {
      await verifyCredentials()
      return
    }
    let isStale =
      Date().timeIntervalSince(lastCredentialCheck) >= Self.credentialCheckInterval
    guard isStale || !verifiedFailures.isEmpty else { return }
    await verifyCredentials()
  }

  /// Asks Dropbox about every account at once, keeping only the accounts it
  /// refused.
  private func failuresOfEveryAccount() async -> [AccountIdentifier: AccountFailure] {
    await withTaskGroup(of: (account: AccountIdentifier, failure: AccountFailure?).self) { group in
      for account in accounts.map(\.accountID) {
        group.addTask { (account, await self.failureConfirming(account)) }
      }
      var failures: [AccountIdentifier: AccountFailure] = [:]
      for await confirmation in group {
        failures[confirmation.account] = confirmation.failure
      }
      return failures
    }
  }

  /// What Dropbox found wrong with one account, or `nil` — in which case the
  /// failure the File Provider latched onto the account's domain is retired
  /// on the way past, since nothing else takes it back.
  private func failureConfirming(_ account: AccountIdentifier) async -> AccountFailure? {
    do {
      _ = try await manager.session(for: account).accountInfo()
      await DomainManager.signalErrorsResolved(for: account)
      return nil
    } catch {
      return AccountFailure(error)
    }
  }

  /// Notes that an account just did something only a working account can do.
  private func recordCredentialsVerified(for account: AccountIdentifier) async {
    guard verifiedFailures.removeValue(forKey: account) != nil else { return }
    await DomainManager.signalErrorsResolved(for: account)
  }

  /**
   Records a failed longpoll as the account's failure.

   The watcher reaches Dropbox every thirty seconds, so this is what makes a
   revoked token visible long before the credential check comes around again.
   A poll that failed only for want of a network is not that, and takes the
   quiet path instead — as does one the network refused to carry, which is
   quieter still: nothing failed, and the app can say exactly why.
   */
  private func recordPollFailure(
    for account: AccountIdentifier,
    _ poll: DomainWatcher.PollFailure
  ) async {
    if let refusal = poll.networkCostRefusal {
      await recordDeferral(refusal, for: account)
      return
    }
    guard !poll.resolvesWithoutUser else {
      await recordOutage(for: account)
      return
    }
    guard let failure = AccountFailure(poll), verifiedFailures[account] != failure else {
      return
    }
    verifiedFailures[account] = failure
    await refreshStatuses()
    notifyOfAccountFailures()
  }

  /**
   Notes that an account is out of touch, dating the outage from the first
   poll that couldn't reach Dropbox.

   Nothing is notified here, at any duration. A Mac that has gone to sleep or
   wandered off its network has nothing wrong with it that its owner could
   put right, and spending the one notification reserved for an account that
   has genuinely stopped would teach them to ignore the one that matters.
   */
  private func recordOutage(for account: AccountIdentifier) async {
    guard outagesSince[account] == nil else { return }
    outagesSince[account] = Date()
    await refreshStatuses()
  }

  /**
   Notes that an account is waiting for a network that costs the user less.

   Nothing is notified, for the same reason an outage isn't and then some:
   the Mac is doing exactly what it should, the files the user opens still
   download, and the wait ends by itself the moment the path changes.
   */
  private func recordDeferral(
    _ refusal: NetworkCostRefusal,
    for account: AccountIdentifier
  ) async {
    guard deferredAccounts.updateValue(refusal, forKey: account) != refusal else { return }
    await refreshStatuses()
  }

  /// Notes that an account is back in touch. A longpoll is unauthenticated,
  /// so this retires the outage and nothing else: whatever the credential
  /// check found wrong stands until it runs again.
  private func recordPollSucceeded(for account: AccountIdentifier) async {
    let wasOffline = outagesSince.removeValue(forKey: account) != nil
    let wasDeferred = deferredAccounts.removeValue(forKey: account) != nil
    guard wasOffline || wasDeferred else { return }
    await refreshStatuses()
  }

  private func notifyOfAccountFailures() {
    for (account, status) in accountStatuses {
      notifications.digestAccountFailure(account: account, failure: status.accountFailure)
    }
  }
}

// MARK: Sync issues

extension AppModel {
  /// Every account that has something to report, paired with its issues, so
  /// the sync-issues list can be built without reopening any index.
  var accountsWithIssues: [(account: AccountConfiguration, status: AccountStatus)] {
    accounts.compactMap { account in
      guard let status = accountStatuses[account.accountID], status.needsAttention else {
        return nil
      }
      return (account, status)
    }
  }

  /**
   Clears one recorded failure, which is how a user puts away an issue whose
   cause they have dealt with.

   The index is otherwise opened read-only here; dismissing is the app's one
   write, and the next attempt at the item records a fresh failure if it
   fails again.
   */
  func dismissSyncIssue(_ issue: SyncErrorRecord, for account: AccountIdentifier) async {
    guard !usesSampleAccounts else {
      accountStatuses[account]?.syncErrors.removeAll { $0 == issue }
      return
    }
    do {
      try await manager.session(for: account).dismissSyncError(at: issue.pathNormalized)
      await refreshStatuses()
    } catch {
      alertMessage = Self.alertText(for: error)
    }
  }
}

// MARK: Ignored items

extension AppModel {
  /// The items the user has taken out of syncing, newest path order, or an
  /// empty list when the account has none.
  func ignoredItems(for account: AccountIdentifier) async -> [IndexEntryRecord] {
    guard !usesSampleAccounts, let store = try? await readOnlyIndex(for: account) else {
      return []
    }
    return (try? await store.ignoredEntries()) ?? []
  }

  /// Every account's ignored items at once: each read opens that account's
  /// index, and one slow index must not hold up the rest.
  func ignoredItemsOfEveryAccount() async -> [AccountIdentifier: [IndexEntryRecord]] {
    await withTaskGroup(
      of: (account: AccountIdentifier, items: [IndexEntryRecord]).self
    ) { group in
      for account in accounts.map(\.accountID) {
        group.addTask { (account, await self.ignoredItems(for: account)) }
      }
      var itemsByAccount: [AccountIdentifier: [IndexEntryRecord]] = [:]
      for await ignored in group {
        itemsByAccount[ignored.account] = ignored.items
      }
      return itemsByAccount
    }
  }

  /**
   Puts an ignored item back into syncing.

   The work belongs to the File Provider extension — it re-uploads whatever
   was edited while the item was out of sync — so the app asks for it the
   same way Finder does, by clearing the item's `com.dropbox.ignored`
   marker and letting the system carry the change to the extension.
   */
  func resumeSync(of item: IndexEntryRecord, in account: AccountIdentifier) async {
    guard !usesSampleAccounts else { return }
    guard
      let url = await DomainManager.userVisibleURL(
        of: NSFileProviderItemIdentifier(item.dbxID.rawValue),
        in: account
      )
    else {
      alertMessage = String(
        localized: "Zephyr couldn’t find “\(item.name)” in Finder.",
        bundle: #bundle
      )
      return
    }
    guard clearIgnoreMarker(at: url) else {
      alertMessage = String(
        localized: "Zephyr couldn’t resume “\(item.name)”. Try it from Finder’s Dropbox menu.",
        bundle: #bundle
      )
      return
    }
    await DomainManager.signalWorkingSet(for: account)
  }

  private func clearIgnoreMarker(at url: URL) -> Bool {
    let isScoped = url.startAccessingSecurityScopedResource()
    defer { if isScoped { url.stopAccessingSecurityScopedResource() } }
    let removed = url.withUnsafeFileSystemRepresentation { path in
      path.map { removexattr($0, DropboxIgnoreMarker.syncableXattrName, 0) } ?? -1
    }
    // The marker being gone already is the state the caller asked for.
    return removed == 0 || errno == ENOATTR
  }
}

// MARK: Repair

extension AppModel {
  /**
   Throws away an account's index and builds it again from a fresh listing
   of the whole Dropbox, then has the system re-enumerate the domain.

   The signal has to come from here: `zephyr` runs under its own bundle
   identifier and is entitled only to the app group, so File Provider
   domains are not visible to it.
   */
  func rebuildIndex(for account: AccountIdentifier) async {
    guard !usesSampleAccounts else { return }
    do {
      try await manager.session(for: account).rebuildIndex()
      await DomainManager.signalWorkingSet(for: account)
      await refreshStatuses()
    } catch {
      alertMessage = Self.alertText(for: error)
    }
  }

  /// Stops or starts syncing for every account, the way Dropbox's own menu
  /// bar item does. Finder keeps serving what it already holds either way.
  func setSyncPaused(_ paused: Bool) async {
    guard !usesSampleAccounts else {
      isSyncPaused = paused
      return
    }
    do {
      if paused {
        try await DomainConnection.disconnectAll()
      } else {
        try await DomainConnection.reconnectAll()
      }
      isSyncPaused = await DomainConnection.areAllDisconnected()
      ControlCenter.shared.reloadControls(ofKind: SetSyncPausedIntent.controlKind)
    } catch {
      alertMessage = Self.alertText(for: error)
    }
  }
}

// MARK: Notification routing

extension AppModel {
  /// Opens whatever a notification's Show button was about.
  private func show(_ target: NotificationManager.ShowTarget) async {
    switch target {
      case let .item(account, path):
        guard let path = try? DropboxPath(validating: path) else {
          await revealInFinder(account)
          return
        }
        await revealItem(atPath: path.normalized, in: account)
      case .account(let account):
        await revealInFinder(account)
    }
  }
}

// MARK: Diagnostics

extension AppModel {
  /// The machine's transfer limits, in one line of the report.
  private static func diagnosticLimits() -> String {
    let settings = BandwidthSettings.load()
    let describe = { (bps: UInt64) in bps == 0 ? "unlimited" : "\(bps) B/s" }
    return "up \(describe(settings.uploadLimitBps)), "
      + "down \(describe(settings.downloadLimitBps)), "
      + "metered \(describe(settings.meteredLimitBps)), "
      + "indexes when metered: \(settings.syncsOnExpensiveNetworks)"
  }

  /// Where a collected report is written: inside Zephyr's own shared
  /// container, named for the moment it was taken.
  private static func diagnosticsURL() -> URL {
    let stamp = Date().formatted(.iso8601.dateSeparator(.dash).timeSeparator(.omitted))
    return ZephyrEnvironment.standard.baseDirectory
      .appending(components: "Diagnostics", "zephyr-diagnostics-\(stamp).txt")
  }

  /// This process's own entries from the unified log, read off the main
  /// actor because the store walks the whole archive to find them.
  private static func recentLogLines() async -> [String] {
    await Task.detached(priority: .userInitiated) { logLines() }.value
  }

  nonisolated private static func logLines() -> [String] {
    let window = Date().addingTimeInterval(-Self.diagnosticLogWindow)
    do {
      let store = try OSLogStore(scope: .currentProcessIdentifier)
      return
        try store
        .getEntries(at: store.position(date: window))
        .compactMap { $0 as? OSLogEntryLog }
        .filter { $0.subsystem.hasPrefix(Self.logSubsystemPrefix) }
        .map { "  \($0.date.formatted(.iso8601)) [\($0.category)] \($0.composedMessage)" }
    } catch {
      return ["  (unavailable: \(error.localizedDescription))"]
    }
  }

  /**
   Writes a report of what Zephyr can see about itself — accounts, domains,
   indexes, failures, and this process's own log — and answers with the file
   so the caller can show it to the user.

   This is not the unified log, and on current macOS it is the only one of the
   two that names anything: Zephyr classifies everything drawn from the user's
   Dropbox as private, and the `log config` switch that used to reveal it is
   gone — private data now takes a configuration profile. So the report is
   where a sync problem has to be legible.
   */
  func collectDiagnostics() async -> URL? {
    do {
      let report = await diagnosticsReport()
      let url = Self.diagnosticsURL()
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try Data(report.utf8).write(to: url, options: .atomic)
      return url
    } catch {
      alertMessage = Self.alertText(for: error)
      return nil
    }
  }

  private func diagnosticsReport() async -> String {
    var lines = [
      "Zephyr diagnostics",
      "Collected: \(Date().formatted(.iso8601))",
      "Version: \(featureFlags.version)",
      "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
      "Syncing paused: \(isSyncPaused)",
      "Notifications: \(NotificationSettings.load().level.name)",
      "Limits: \(Self.diagnosticLimits())",
      "Withheld approvals: \(withheldApprovals.map(\.id).joined(separator: ", ").nilIfEmpty ?? "none")",
      ""
    ]
    for account in unreadableAccounts {
      lines.append("Account \(account.rawValue): configuration unreadable")
    }
    lines.append(contentsOf: await diagnosticLinesForEveryAccount())
    lines.append("")
    lines.append("This process’s recent log:")
    lines.append(contentsOf: await Self.recentLogLines())
    return lines.joined(separator: "\n") + "\n"
  }

  /// Every account's block of the report, collected at once and put back into
  /// the order the accounts are listed in.
  private func diagnosticLinesForEveryAccount() async -> [String] {
    await withTaskGroup(of: (position: Int, lines: [String]).self) { group in
      for (position, account) in accounts.enumerated() {
        group.addTask { (position, await self.diagnosticLines(for: account)) }
      }
      var blocks: [(position: Int, lines: [String])] = []
      for await block in group { blocks.append(block) }
      return blocks.sorted { $0.position < $1.position }.flatMap(\.lines)
    }
  }

  private func diagnosticLines(for account: AccountConfiguration) async -> [String] {
    let status = accountStatuses[account.accountID]
    var lines = [
      "Account \(account.accountID.rawValue)",
      "  root: \(account.rootType.rawValue) (\(account.rootNamespaceID.rawValue))",
      "  linked: \(account.linkedAt.formatted(.iso8601))",
      "  domain: \(await DomainManager.domain(forDiagnostics: account.accountID))",
      "  items: \(status?.files ?? 0) files, \(status?.folders ?? 0) folders",
      "  account failure: \(status?.accountFailure?.title ?? "none")"
    ]
    for issue in status?.syncErrors ?? [] {
      lines.append("  issue \(issue.path.displayPath): \(issue.title) \(issue.detail ?? "")")
    }
    for ignored in await ignoredItems(for: account.accountID) {
      lines.append("  ignored \(ignored.pathCased.rawValue)")
    }
    return lines
  }
}

private extension String {
  /// The string itself, unless it has nothing in it.
  var nilIfEmpty: Self? { isEmpty ? nil : self }
}
