public import Foundation

/**
 A failure that stops the sync engine until it is resolved.

 Mirrors Maestral's fatal error tier: connection loss (recoverable by the
 connection monitor), cursor resets (recoverable by reindexing), and states
 requiring user action.
 */
public enum EngineFailure: SyncFatalError, Equatable {
  /// No Dropbox account is linked.
  case notLinked
  /// The Dropbox servers cannot be reached.
  case connection(detail: String?)
  /// Dropbox invalidated the delta cursor; the index must be rebuilt.
  case cursorReset
  /// The account's path root (team/personal namespace) changed.
  case pathRootChanged(newRoot: NamespaceIdentifier?)
  /// Another operation holds the sync lock.
  case busy
  /// The operation was cancelled.
  case cancelled
  /// The temporary cache directory could not be created or used.
  case cacheDirectory(detail: String?)
  /// macOS refused to carry Zephyr's own traffic over a path that costs the
  /// user something.
  case deferredForNetworkCost(reason: NetworkCostRefusal)

  public var haltsSync: Bool {
    switch self {
      case .notLinked, .connection, .cursorReset, .pathRootChanged, .cacheDirectory,
        .deferredForNetworkCost:
        true
      // Neither says anything is wrong with the account: the caller walked away
      // from the operation, or another one is already holding the lock.
      case .busy, .cancelled: false
    }
  }

  public var resolvesWithoutUser: Bool {
    switch self {
      // Nothing reaches Dropbox until a route does, and a route comes back
      // without being asked: a lid opens, a radio wakes, a cable goes in. A
      // path stops costing the same way — a hotspot is put away, a network
      // is joined — and the wait it caused ends with it.
      case .connection, .deferredForNetworkCost: true
      case .notLinked, .cursorReset, .pathRootChanged, .cacheDirectory, .busy, .cancelled: false
    }
  }

  /// Why syncing is holding back over what the path costs, or `nil` for a
  /// failure at something. A refusal is a wait Zephyr chose, and can name.
  public var networkCostRefusal: NetworkCostRefusal? {
    switch self {
      case .deferredForNetworkCost(let reason): reason
      default: nil
    }
  }
}

extension EngineFailure: LocalizedError {
  /// A deferral is the one failure here that nothing went wrong in: syncing
  /// is holding back on purpose and will pick itself up, so it says so
  /// rather than reporting a stoppage.
  public var errorDescription: String? {
    switch self {
      case .deferredForNetworkCost:
        String(localized: "Syncing is waiting for a cheaper network.", bundle: #bundle)
      default:
        String(localized: "Syncing stopped.", bundle: #bundle)
    }
  }

  public var failureReason: String? {
    switch self {
      case .notLinked:
        String(localized: "No Dropbox account is linked.", bundle: #bundle)
      case .connection(let detail):
        sentence(
          String(localized: "Cannot connect to Dropbox.", bundle: #bundle),
          followedBy: detail
        )
      case .cursorReset:
        String(
          localized: "Dropbox reset the sync state; the index must be rebuilt.",
          bundle: #bundle
        )
      case .pathRootChanged:
        String(localized: "The Dropbox account’s root namespace changed.", bundle: #bundle)
      case .busy:
        String(localized: "Another sync operation is in progress.", bundle: #bundle)
      case .cancelled:
        String(localized: "The operation was cancelled.", bundle: #bundle)
      case .cacheDirectory(let detail):
        sentence(
          String(localized: "The cache directory is unusable.", bundle: #bundle),
          followedBy: detail
        )
      case .deferredForNetworkCost(let reason):
        reason.explanation
    }
  }

  public var recoverySuggestion: String? {
    switch self {
      case .notLinked:
        String(
          localized: "Link an account with “zephyr auth link” or from the app.",
          bundle: #bundle
        )
      case .deferredForNetworkCost(.constrained):
        String(
          localized: "Switch off Low Data Mode for this network, or join another one.",
          bundle: #bundle
        )
      case .deferredForNetworkCost(.expensive):
        String(
          localized: "Join a network that costs nothing to use. Files you open still download.",
          bundle: #bundle
        )
      default:
        nil
    }
  }

  /// `reason` alone, or with the detail the failed operation supplied as a
  /// second sentence. Most failures carry no detail, so the two are joined only
  /// when there is something to join.
  private func sentence(_ reason: String, followedBy detail: String?) -> String {
    guard let detail else { return reason }
    return "\(reason) \(detail)"
  }
}

/**
 Why macOS would not carry Zephyr's own traffic over the path it has.

 The two are not equally authoritative. ``constrained`` is Low Data Mode,
 which somebody switched on deliberately. ``expensive`` is the system's
 reading of a tethered iPhone or a metered connection — usually right, and
 still only a reading, which is why it holds back bulk work and never holds
 back a file somebody asked for.
 */
public enum NetworkCostRefusal: Sendable, Equatable {
  /// The path costs money or battery, as far as macOS can tell.
  case expensive
  /// The path is in Low Data Mode.
  case constrained

  /// Why background syncing is holding back, as a failure states it.
  public var explanation: String {
    switch self {
      case .expensive:
        String(localized: "This network costs money or battery to use.", bundle: #bundle)
      case .constrained:
        String(localized: "Low Data Mode is switched on for this network.", bundle: #bundle)
    }
  }

  /**
   The same reason in the words a status line has room for.

   A line under an account's name shares its row with the account's counts,
   which leaves it about half the panel: a sentence there is a sentence
   with its end cut off, and the state it belongs to is already named
   above it.
   */
  public var summary: String {
    switch self {
      case .expensive: String(localized: "This network costs to use", bundle: #bundle)
      case .constrained: String(localized: "Low Data Mode is on", bundle: #bundle)
    }
  }
}
