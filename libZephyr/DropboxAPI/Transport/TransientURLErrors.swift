import Foundation

extension URLError {
  /**
   Whether the request failed because the network was briefly not there,
   rather than because the request itself was wrong.

   A Mac that sleeps, changes networks, or loses a route tears down every
   socket under it, and the requests riding those sockets come back having
   never been answered. Asking again unchanged is the right move; asking
   again after a refused or malformed request is not, so only this family is
   named here. A cancellation is deliberately absent — see ``isCancellation``.
   */
  var isTransient: Bool {
    switch code {
      case .networkConnectionLost, .notConnectedToInternet, .timedOut,
        .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
        .secureConnectionFailed, .resourceUnavailable, .internationalRoamingOff,
        .callIsActive, .dataNotAllowed:
        true
      default:
        false
    }
  }

  /**
   Whether the request failed because something cancelled it, rather than
   because it was tried and went wrong.

   A cancellation is not a verdict on Dropbox or on the network: the task was
   torn down before either could answer, and there is nothing for the user to
   put right. Reading it as a connection failure stops the account and spends
   the notification kept for syncing that has genuinely stopped.
   */
  var isCancellation: Bool { code == .cancelled }

  /**
   Why macOS refused to carry the request over the path it has, or `nil` for
   a request that failed for some other reason.

   A refusal is not the network being briefly absent. The route is up and it
   works; the system declined to spend it on traffic that declared it did not
   need spending. That has to be told apart before ``isTransient``, which
   already lists the codes a refusal arrives under: retrying one four times
   over would spend the battery the refusal just saved, and would end at a
   sync issue naming a connection that was never lost.
   */
  var networkCostRefusal: NetworkCostRefusal? {
    switch networkUnavailableReason {
      case .constrained: .constrained
      case .cellular, .expensive: .expensive
      default: nil
    }
  }
}
