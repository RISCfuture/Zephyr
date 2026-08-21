import Foundation

/**
 A recoverable, per-item sync failure (Maestral's `SyncError` tier).

 Failures of this kind are recorded against the affected item, surfaced to the
 user, and retried later; they never stop the engine.
 */
protocol SyncItemError: Error {}

/**
 A failure that halts the sync engine (Maestral's fatal tier), such as a revoked
 token, a lost connection, or a corrupt index.

 The tier is the account-level counterpart of the per-item failures: a conforming
 failure belongs in its own status row rather than in the "couldn't sync" count,
 because it describes the account and not one item.
 */
public protocol SyncFatalError: Error {
  /**
   Whether sync stays stopped until something outside the failed operation changes.

   A few conditions stop the engine without saying anything is wrong with the
   account — a cancellation, a lock another operation already holds — and must
   not be reported as an account-level failure.
   */
  var haltsSync: Bool { get }

  /**
   Whether the condition lifts on its own, with nothing for the user to do.

   A halted account is not always a broken one. A Mac that has just gone to
   sleep, or wandered off its network, stops syncing exactly as thoroughly as
   one whose token was revoked — but it comes back by itself, and telling the
   user about it spends their attention on something they cannot act on. The
   two are told apart here so a passing outage can be reported as a state and
   a real failure as a failure.
   */
  var resolvesWithoutUser: Bool { get }
}

extension SyncFatalError {
  /// Failures in this tier halt sync unless the conforming type says otherwise.
  public var haltsSync: Bool { true }

  /// A failure in this tier waits for the user unless the conforming type
  /// says it clears itself.
  public var resolvesWithoutUser: Bool { false }
}

/// An OAuth, token-refresh, or credential-storage failure.
public protocol AuthError: Error {}

/// A persistence failure in the sync index or configuration store.
protocol StoreError: Error {}

/// A malformed or unexpected payload from the Dropbox API, or a value that
/// failed strict parsing.
protocol WireError: Error {}
