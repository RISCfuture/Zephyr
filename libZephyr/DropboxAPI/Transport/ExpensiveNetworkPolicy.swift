import Foundation
import Synchronization

/**
 Whether Zephyr's own background work may use a network macOS reads as
 expensive.

 A setting, and a live one: the File Provider extension holds its transport
 across many changes to it, and a toggle that only took effect at the next
 launch would look broken. It is settable for the same reason a bandwidth
 limit is, and travels the same way — the extension watches the account's
 configuration file and adopts what it finds.

 Nothing here speaks for Low Data Mode. That is an instruction rather than a
 reading, so the session refusing it does so unconditionally and this policy
 never sees it.
 */
public final class ExpensiveNetworkPolicy: Sendable {
  private let allowed: Mutex<Bool>

  /// Whether background work may use an expensive network as things stand.
  public var isAllowed: Bool { allowed.withLock { $0 } }

  public init(isAllowed: Bool) {
    allowed = Mutex(isAllowed)
  }

  /// Takes a new answer, which the next request honors.
  public func adopt(_ isAllowed: Bool) {
    allowed.withLock { $0 = isAllowed }
  }
}
