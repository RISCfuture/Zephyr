import Foundation
import Network
import Synchronization

/**
 What the Mac's network path is, and what using it costs.

 The two costs are not the same kind of fact. ``isConstrained`` is Low Data
 Mode: somebody went into System Settings and said to hold back on this
 network, and there is nothing to second-guess. ``isExpensive`` is the
 system's own reading of a tethered iPhone or a metered connection — usually
 right, sometimes not, and never something the user asked for. Bulk work
 defers to either; work the user just asked for defers to neither.
 */
public struct NetworkConditions: Sendable, Equatable {
  /// The conditions assumed before the monitor has reported a path: a route,
  /// costing nothing. Holding back on a path nobody has described yet would
  /// delay every first request on the overwhelmingly common network.
  static let unknown = Self()

  /// Whether the Mac has a route to anywhere.
  public let isSatisfied: Bool

  /// Whether macOS reads the path as costing money or battery — a personal
  /// hotspot, a metered connection. A heuristic, and treated as one.
  public let isExpensive: Bool

  /// Whether the path is in Low Data Mode. An explicit user instruction.
  public let isConstrained: Bool

  /**
   Whether using the path costs the user something, either way it can.

   The two costs are told apart where the difference matters — whether
   background work runs at all — and taken together where it doesn't, which
   is how fast a transfer the user is waiting on should run.
   */
  public var isMetered: Bool { isExpensive || isConstrained }

  /// How costly the path is, so an improvement can be told from a change.
  var cost: Cost {
    guard isSatisfied else { return .unreachable }
    if isConstrained { return .constrained }
    return isExpensive ? .expensive : .free
  }

  public init(isSatisfied: Bool = true, isExpensive: Bool = false, isConstrained: Bool = false) {
    self.isSatisfied = isSatisfied
    self.isExpensive = isExpensive
    self.isConstrained = isConstrained
  }

  init(_ path: NWPath) {
    self.init(
      isSatisfied: path.status == .satisfied,
      isExpensive: path.isExpensive,
      isConstrained: path.isConstrained
    )
  }

  /// What a path costs to use, ordered so that less is better.
  enum Cost: Comparable {
    case free, expensive, constrained, unreachable
  }
}

/**
 Reports what the Mac's network path is and when it gets better.

 A poll that failed because nothing could reach Dropbox would otherwise sit
 out its whole retry interval after the lid opens, leaving the user watching
 a Dropbox that has every reason to be syncing and isn't. Waiting on the path
 instead lets the watcher try again as soon as macOS has a route to offer —
 or, for work that held back rather than failed, as soon as the route it has
 stops costing so much.

 Only improvements are reported, never the current state: a path that is
 already satisfied is not news, because the failure being retried happened
 over it. That keeps a watcher from spinning against a route that looks fine
 to the system and still can't carry a request. Conditions that merely
 changed — including a path that got worse — reach ``conditionsStream()``,
 for a host long-lived enough to care.

 One monitor serves the process. Sessions are built and dropped constantly —
 the change watcher builds one per poll — and a monitor apiece would be a
 monitor a minute per account.
 */
public actor NetworkReachability {
  /// The process's path monitor.
  public static let shared = NetworkReachability()

  private let monitor = NWPathMonitor()
  private let snapshot = Mutex(NetworkConditions.unknown)
  private var waiters: [UUID: Waiter] = [:]
  private var observers: [UUID: AsyncStream<NetworkConditions>.Continuation] = [:]

  /// The path as it stands, readable from anywhere: a session decides what a
  /// transfer costs while it is being built, with nowhere to await.
  nonisolated public var conditions: NetworkConditions { snapshot.withLock { $0 } }

  private init() {
    monitor.pathUpdateHandler = { [weak self] path in
      guard let self else { return }
      let conditions = NetworkConditions(path)
      let previous = snapshot.withLock { stored in
        defer { stored = conditions }
        return stored
      }
      Task { await self.pathChanged(from: previous, to: conditions) }
    }
    monitor.start(queue: DispatchQueue(label: "codes.tim.Zephyr.reachability"))
  }

  /// Returns the next time the Mac goes from having no route to having one,
  /// or when the calling task is cancelled.
  public func waitForRouteToReturn() async { await wait(for: .route) }

  /**
   Returns the next time the path gets cheaper — a route where there was
   none, Low Data Mode switched off, a hotspot traded for a network — or
   when the calling task is cancelled.

   What bulk work waits on when it held back rather than failed. A path that
   only got worse is not an answer to that wait.
   */
  public func waitForConditionsToImprove() async { await wait(for: .cost) }

  /**
   Reports the conditions each time they change, for a host that outlives
   them: the File Provider extension keeps one session across a whole
   afternoon of joining and leaving networks.
   */
  public func conditionsStream() -> AsyncStream<NetworkConditions> {
    let id = UUID()
    let (stream, continuation) = AsyncStream<NetworkConditions>.makeStream()
    continuation.onTermination = { [weak self] _ in
      Task { await self?.stopObserving(id) }
    }
    observers[id] = continuation
    return stream
  }

  private func wait(for improvement: Waiter.Improvement) async {
    let id = UUID()
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard !Task.isCancelled else { return continuation.resume() }
        waiters[id] = Waiter(improvement: improvement, continuation: continuation)
      }
    } onCancel: {
      Task { await self.stopWaiting(id) }
    }
  }

  private func pathChanged(from previous: NetworkConditions, to conditions: NetworkConditions) {
    guard previous != conditions else { return }
    for observer in observers.values { observer.yield(conditions) }
    let resuming = waiters.filter {
      $0.value.improvement.happened(from: previous.cost, to: conditions.cost)
    }
    for id in resuming.keys { waiters[id] = nil }
    for waiter in resuming.values { waiter.continuation.resume() }
  }

  private func stopWaiting(_ id: UUID) {
    waiters.removeValue(forKey: id)?.continuation.resume()
  }

  private func stopObserving(_ id: UUID) {
    observers[id] = nil
  }

  deinit { monitor.cancel() }

  /// One suspended caller, and what would answer it.
  private struct Waiter {
    let improvement: Improvement
    let continuation: CheckedContinuation<Void, Never>

    /// The kinds of improvement worth waking for.
    enum Improvement {
      /// A route where there was none, whatever the new one costs.
      case route
      /// Any cheaper path, a returning route included.
      case cost

      func happened(from previous: NetworkConditions.Cost, to current: NetworkConditions.Cost)
        -> Bool
      {
        switch self {
          case .route: previous == .unreachable && current != .unreachable
          case .cost: current < previous
        }
      }
    }
  }
}
