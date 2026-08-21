import Foundation

/**
 An authorization that succeeded as the wrong Dropbox account.

 Dropbox's page approves whichever account the browser is already signed into,
 and Zephyr learns which one only once the exchange is done — so this is the
 first and only chance to notice that the approval, valid in itself, is not the
 one that was asked for.

 Apart from ``AuthenticationFailure`` and its fatal tier on purpose: nothing is
 wrong with either account, nothing has been stored, and the account already
 linked goes on syncing.
 */
enum LinkRefusal: AuthError, Equatable {
  /// The account that approved is linked already.
  case alreadyLinked(email: String)

  /// The account that approved is not the one the link was repairing.
  case notTheAccountBeingRepaired(approved: String, repairing: String)
}

extension LinkRefusal: LocalizedError {
  var errorDescription: String? {
    String(localized: "That isn’t the Dropbox account this was for.", bundle: #bundle)
  }

  var failureReason: String? {
    switch self {
      case let .alreadyLinked(email):
        String(localized: "“\(email)” is already linked to Zephyr.", bundle: #bundle)
      case let .notTheAccountBeingRepaired(approved, repairing):
        String(
          localized: "You approved “\(approved)”, but this repairs “\(repairing)”.",
          bundle: #bundle
        )
    }
  }

  var recoverySuggestion: String? {
    String(
      localized: """
        Dropbox approves whichever account your browser is signed in to. Sign out there, then try \
        again.
        """,
      bundle: #bundle
    )
  }

  var helpAnchor: String? { HelpAnchor.linkAccount.rawValue }
}
