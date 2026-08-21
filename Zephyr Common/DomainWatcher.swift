import Foundation
import libZephyr
import os

/**
 Longpolls Dropbox for remote changes to each watched account and signals the
 account's File Provider domain when changes arrive.

 The watcher lives in the app process because the extension must never
 longpoll — the system reaps idle extensions. Each account's task waits on the
 extension's persisted delta cursor without ever advancing it (only the
 extension calls `list_folder/continue`), then pokes the working-set
 enumerator so Finder re-enumerates.

 It is also where an account is noticed to have moved between a personal
 Dropbox and a team space: the watcher re-resolves each account's path root
 as it takes the account up, and again whenever Dropbox refuses the root it
 is sending.
 */
actor DomainWatcher {
  private static let indexCheckInterval: Duration = .seconds(60),
    errorRetryInterval: Duration = .seconds(30),
    changeSettleDelay: Duration = .seconds(2)

  /// The backstop between polls the path refused to carry. Long, because
  /// nothing about the refusal changes until the path does.
  private static let refusedRetryInterval: Duration = .seconds(300)

  /// How many polls in a row have to fail before the watcher's trouble is the
  /// account's trouble. Below it a failure is weather — a timeout, a rate
  /// limit — that the next poll clears on its own. A lost connection never
  /// gets here at all: it is reported as an outage however long it lasts.
  private static let persistentFailureCount = 3

  private let manager: AccountManager
  private var watchTasks: [AccountIdentifier: Task<Void, Never>] = [:]
  private var remoteChangeHandler: (@Sendable (AccountIdentifier) async -> Void)?
  private var pollFailureHandler: (@Sendable (AccountIdentifier, PollFailure) async -> Void)?
  private var pollSuccessHandler: (@Sendable (AccountIdentifier) async -> Void)?

  /// How many polls in a row have failed for each account; an account that
  /// has just polled cleanly is absent.
  private var failedPolls: [AccountIdentifier: Int] = [:]

  init(manager: AccountManager) {
    self.manager = manager
  }

  /// Installs a callback run after each remote-change signal, once the
  /// enumerator has been poked.
  func setRemoteChangeHandler(_ handler: @escaping @Sendable (AccountIdentifier) async -> Void) {
    remoteChangeHandler = handler
  }

  /**
   Installs a callback run when a poll fails, so an account the watcher can
   no longer reach — a revoked token above all — reads as stopped in the UI
   instead of only in the log. Whether that is a failure or merely an outage
   is the handler's to decide, from ``PollFailure/resolvesWithoutUser``.
   */
  func setPollFailureHandler(
    _ handler: @escaping @Sendable (AccountIdentifier, PollFailure) async -> Void
  ) {
    pollFailureHandler = handler
  }

  /**
   Installs a callback run when a poll succeeds, which is how an account that
   was out of touch is noticed to be reachable again.

   A poll carries no proof of anything else: the longpoll route is
   unauthenticated by design, so reaching it says the network is back and
   says nothing at all about the account's credentials.
   */
  func setPollSuccessHandler(_ handler: @escaping @Sendable (AccountIdentifier) async -> Void) {
    pollSuccessHandler = handler
  }

  /**
   Watches exactly `accounts`: spawns a task per newly watched account and
   cancels the tasks of accounts no longer listed.
   */
  func watch(_ accounts: [AccountIdentifier]) {
    cancelWatchers(except: Set(accounts))
    for account in accounts where watchTasks[account] == nil {
      watchTasks[account] = Task { await self.watchForChanges(to: account) }
    }
  }

  private func cancelWatchers(except accounts: Set<AccountIdentifier>) {
    for (account, task) in watchTasks where !accounts.contains(account) {
      task.cancel()
      watchTasks[account] = nil
    }
  }

  private func watchForChanges(to account: AccountIdentifier) async {
    await confirmPathRoot(of: account)
    while !Task.isCancelled {
      do {
        if try await pollOnce(for: account) { await recordReachedDropbox(account) }
      } catch {
        guard !Task.isCancelled else { return }
        await reportPollFailure(error, for: account)
        await waitBeforeRetrying(after: error)
      }
    }
  }

  /// Notes a poll that actually reached Dropbox, retiring both the failure
  /// streak and whatever the app was saying about the outage. A poll that
  /// only waited — on an index the extension has yet to build — reached
  /// nothing and leaves both standing.
  private func recordReachedDropbox(_ account: AccountIdentifier) async {
    failedPolls[account] = nil
    await pollSuccessHandler?(account)
  }

  /**
   Waits out the retry interval, cutting it short the moment the path can
   answer the failure that caused the wait.

   Most outages the watcher sees end at a lid opening, and making the user
   wait out the rest of the interval after that would be the app's own delay
   on top of the network's. An outage the system never noticed — a route that
   stayed up and still couldn't carry a request — simply waits the interval.

   A poll refused over what the path costs is the one failure that must not
   be retried on the ordinary interval. The route is up and the refusal is
   instant, so asking again every half minute would replace one held
   connection with a poll that never rests — spending more of the battery
   the refusal was saving. That wait runs long, and ends on a cheaper path
   rather than on any route at all.
   */
  private func waitBeforeRetrying(after error: any Error) async {
    let isRefusal = (error as? EngineFailure)?.networkCostRefusal != nil
    await withTaskGroup(of: Void.self) { group in
      group.addTask { [interval = self.retryInterval(refused: isRefusal)] in
        try? await Task.sleep(for: interval)
      }
      group.addTask {
        if isRefusal {
          await NetworkReachability.shared.waitForConditionsToImprove()
        } else {
          await NetworkReachability.shared.waitForRouteToReturn()
        }
      }
      await group.next()
      group.cancelAll()
    }
  }

  /// How long to wait before polling again. A refusal is answered by the
  /// path changing, so its interval is only a backstop.
  private func retryInterval(refused: Bool) -> Duration {
    guard refused else { return Self.errorRetryInterval }
    return BulkWorkPressure.current.stretching(Self.refusedRetryInterval)
  }

  /// Logs a failed poll and hands it on with how long the watcher has been
  /// failing, so a run of them can be told from a single bad minute.
  private func reportPollFailure(_ error: any Error, for account: AccountIdentifier) async {
    let failure = PollFailure(error: error, failedPolls: (failedPolls[account] ?? 0) + 1)
    failedPolls[account] = failure.failedPolls
    ZephyrLog.watcher.error(
      """
      Change watcher for account \(account.rawValue, privacy: .private(mask: .hash)) failed \
      \(failure.failedPolls, privacy: .public) times running: \
      \(String(describing: error), privacy: .private)
      """
    )
    await pollFailureHandler?(account, failure)
  }

  /// - Returns: Whether the poll reached Dropbox, as opposed to waiting on an
  ///   index that does not exist yet.
  private func pollOnce(for account: AccountIdentifier) async throws -> Bool {
    let session = try await manager.session(for: account)
    guard let cursor = try await currentCursor(of: session) else {
      await waitForIndex(of: account)
      return false
    }
    let result: LongpollResult
    do {
      result = try await session.waitForChanges(after: cursor)
    } catch EngineFailure.pathRootChanged(let newRoot) {
      // A root that turns out not to have moved leaves the refusal standing,
      // so the watcher backs off instead of asking again immediately.
      guard try await adoptPathRoot(of: session) else {
        throw EngineFailure.pathRootChanged(newRoot: newRoot)
      }
      return true
    }
    if result.changes {
      try await settleThenSignal(account)
    }
    if let backoff = result.backoff {
      try await Task.sleep(for: backoff)
    }
    return true
  }

  /**
   Waits for the extension to build the account's index, ending the moment it
   commits anything rather than at the end of the interval.

   Only the extension's first enumeration stores a cursor, and until one
   exists there is nothing to longpoll from. Waiting out the whole check
   interval would leave a freshly linked account unwatched for up to a minute
   after it was ready — longer on a Mac that is holding back.
   */
  private func waitForIndex(of account: AccountIdentifier) async {
    await withTaskGroup(of: Void.self) { group in
      group.addTask {
        try? await Task.sleep(for: BulkWorkPressure.current.stretching(Self.indexCheckInterval))
      }
      group.addTask {
        for await _ in ChangeSignal.index(account).signals() { return }
      }
      await group.next()
      group.cancelAll()
    }
  }

  /**
   Re-resolves the account's path root as its watch starts, which is the
   startup check for a member who joined or left a team while the app was
   not running.

   A failure here is not worth reporting: the poll loop reaches the network
   next, and every path-based call surfaces its own failure.
   */
  private func confirmPathRoot(of account: AccountIdentifier) async {
    guard let session = try? await manager.session(for: account) else { return }
    _ = try? await adoptPathRoot(of: session)
  }

  /**
   Records the account's path root as Dropbox reports it now, and
   re-enumerates the domain when it moved: a moved root renames every path
   the extension indexed, and the cursor the extension stored belongs to the
   namespace the account has left.

   - Returns: Whether the root moved.
   */
  @discardableResult
  private func adoptPathRoot(of session: AccountSession) async throws -> Bool {
    guard try await session.refreshPathRoot() else { return false }
    try await settleThenSignal(session.accountID)
    return true
  }

  /// The extension-persisted delta cursor, or `nil` until the extension's
  /// first enumeration has built the index and stored one.
  private func currentCursor(of session: AccountSession) async throws -> DeltaCursor? {
    guard session.indexExists else { return nil }
    return try await session.openIndex(mode: .readOnly).currentCursor()
  }

  private func settleThenSignal(_ account: AccountIdentifier) async throws {
    try await Task.sleep(for: BulkWorkPressure.current.stretching(Self.changeSettleDelay))
    await DomainManager.signalWorkingSet(for: account)
    await remoteChangeHandler?(account)
  }

  /// A poll that failed, and how long the watcher has been failing on the
  /// account it belongs to.
  struct PollFailure {
    /// What the poll threw.
    let error: any Error

    /// How many polls in a row have failed, this one included.
    let failedPolls: Int

    /**
     Whether the watcher has been failing long enough that the account is not
     syncing at all.

     A single failed poll says nothing — Dropbox is refused for a minute a
     dozen times a day. A run of them says the app has stopped hearing about
     remote changes entirely, which stops the account as surely as an error
     the mapper classifies as fatal.
     */
    var isPersistent: Bool { failedPolls >= DomainWatcher.persistentFailureCount }

    /// Whether the poll failed for a reason that lifts on its own — the
    /// network being away — rather than one the user has to put right.
    var resolvesWithoutUser: Bool {
      (error as? any SyncFatalError)?.resolvesWithoutUser ?? false
    }

    /// Why the path refused to carry the poll, or `nil` for a poll that
    /// failed at something. A refusal is a wait Zephyr chose and can name,
    /// not an outage it is suffering.
    var networkCostRefusal: NetworkCostRefusal? {
      (error as? EngineFailure)?.networkCostRefusal
    }
  }
}
