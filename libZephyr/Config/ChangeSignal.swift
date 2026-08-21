import CryptoKit
import Foundation
import notify
import os

/**
 Something one Zephyr process changed that the others need to hear about.

 The app, the File Provider extension, the share extension, the widget, and the
 command line share an app group container and nothing else. A signal is how
 one of them says that a file in it is no longer what a reader last saw, so
 that the reader looks again instead of waiting for a poll to come round.

 A signal carries no payload and no generation counter. `notify(3)` keeps state
 only for as long as some registrant holds the name continuously, so a process
 that starts after the poster exited cannot tell being behind from there being
 no state, and has to read anyway. The configuration files and the sync index
 stay the source of truth; a signal is only a poke.

 Delivery is best-effort, and every consumer reads its file or its index on
 waking, so a post that goes missing costs latency rather than correctness.
 */
public enum ChangeSignal: Sendable, Hashable {
  /// One account's stored configuration.
  case configuration(AccountIdentifier)

  /// One account's sync index, whose only writer is the File Provider extension.
  case index(AccountIdentifier)

  /// The Mac's transfer limits.
  case transferLimits

  /// The notification level and snooze deadline.
  case notificationSettings

  /**
   Whether syncing is paused.

   The one signal whose source of truth is not a file in the container: pausing
   disconnects the File Provider domains, and ``DomainConnection`` reads that
   back from the system. A signal is a poke either way, so the reader looks the
   same — it just looks somewhere else.
   */
  case syncPaused

  /// How long ``coalescedSignals(within:)`` lets a run of posts collapse into
  /// one before it reports again.
  public static let coalescingWindow = Duration.seconds(5)

  /// What `notify(3)` answers when a call succeeded.
  private static let ok = UInt32(NOTIFY_STATUS_OK)

  /// How many bytes of an account's digest name it. Eight is far more than
  /// enough to separate the handful of accounts one Mac links, and the name is
  /// an identifier rather than a defense against a search.
  private static let digestLength = 8

  /// Where registrations are handed back. Every handler does nothing but yield,
  /// so one utility queue serves every signal in the process.
  private static let deliveryQueue = DispatchQueue(
    label: "codes.tim.Zephyr.change-signal",
    qos: .utility
  )

  /**
   The Darwin notification name, which every Zephyr process derives alike.

   The app group prefix is what lets sandboxed processes share a name. An
   account is named by a digest of its identifier rather than by the identifier
   itself: this is a namespace the whole system can see, and an account only
   needs to correlate here — the same reason the unified log masks it.
   */
  var name: String { "\(ZephyrEnvironment.appGroupIdentifier).\(scope)" }

  private var scope: String {
    switch self {
      case .configuration(let account): "config.\(Self.digest(of: account))"
      case .index(let account): "index.\(Self.digest(of: account))"
      case .transferLimits: "transfer-limits"
      case .notificationSettings: "notification-settings"
      case .syncPaused: "sync-paused"
    }
  }

  private static func digest(of account: AccountIdentifier) -> String {
    SHA256.hash(data: Data(account.rawValue.utf8))
      .prefix(digestLength)
      .map { String(format: "%02x", $0) }
      .joined()
  }

  /**
   Tells every other process that this changed.

   Cheap, synchronous, and safe from inside an actor: a post is one call into
   libSystem. A post nobody has registered for is the ordinary case rather than
   a failure — most of the time only one process is running.
   */
  public func post() {
    let status = notify_post(name)
    guard status != Self.ok else { return }
    ZephyrLog.engine.error(
      "Cannot post \(self.name, privacy: .public), notify status \(status, privacy: .public)"
    )
  }

  /**
   Reports each time any process posts this signal, including this one.

   The stream keeps only the newest element: a signal says that something
   changed and never how often, so a consumer that was busy has nothing to gain
   from the posts it slept through.
   */
  public func signals() -> AsyncStream<Void> {
    let (stream, continuation) = AsyncStream<Void>.makeStream(
      bufferingPolicy: .bufferingNewest(1)
    )
    var token = NOTIFY_TOKEN_INVALID
    let status = notify_register_dispatch(name, &token, Self.deliveryQueue) { _ in
      continuation.yield()
    }
    guard status == Self.ok else {
      // A watch that failed to register never reports anything again, which is
      // silent everywhere else, so it is logged where it happens.
      ZephyrLog.engine.error(
        "Cannot watch \(self.name, privacy: .public), notify status \(status, privacy: .public)"
      )
      continuation.finish()
      return stream
    }
    let registered = token
    continuation.onTermination = { _ in _ = notify_cancel(registered) }
    return stream
  }

  /**
   Reports posts at most once per `window`, without ever letting a run of them
   go unreported.

   The extension commits one delta page at a time, so an account being indexed
   for the first time posts steadily for as long as the walk takes. A consumer
   that reads every account's index per post would spend that whole walk
   re-reading it. Reporting on the leading edge and then holding the window
   shut bounds that work, and still says something while the walk runs — which
   waiting for silence never would, because the silence comes only at the end.

   The window widens under ``BulkWorkPressure``, re-read each time round, so a
   Mac that is hot or saving power reports less often and one plugged in
   mid-walk picks up again.
   */
  public func coalescedSignals(within window: Duration = Self.coalescingWindow) -> AsyncStream<Void>
  {
    let posts = signals()
    let (stream, continuation) = AsyncStream<Void>.makeStream(
      bufferingPolicy: .bufferingNewest(1)
    )
    let reporting = Task {
      for await _ in posts {
        continuation.yield()
        try? await Task.sleep(for: BulkWorkPressure.current.stretching(window))
      }
      continuation.finish()
    }
    continuation.onTermination = { _ in reporting.cancel() }
    return stream
  }
}
