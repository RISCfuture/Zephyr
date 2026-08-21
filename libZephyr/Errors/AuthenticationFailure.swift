import Foundation

/**
 An OAuth or credential-storage failure.

 Every case leaves the account unusable until the user re-authorizes or repairs
 the keychain, so the whole type sits in the fatal tier as well as the auth one.
 */
public enum AuthenticationFailure: AuthError, SyncFatalError, Equatable {
  /// The access token expired and could not be refreshed.
  case tokenExpired
  /// The user or Dropbox revoked this app's authorization.
  case tokenRevoked
  /// The app registration is missing a required OAuth scope.
  case missingScope(String)
  /// The authorization code or refresh token was rejected.
  case invalidGrant
  /// The OAuth `state` parameter was absent or did not match, indicating a possible CSRF attempt.
  case stateMismatch
  /// The user declined to grant Zephyr access at Dropbox's authorization page.
  case authorizationDeclined
  /// Dropbox refused the authorization request itself, for the reason given.
  case authorizationRejected(reason: String)
  /// The authorization response could not be parsed.
  case malformedTokenResponse(detail: String)
  /// The keychain refused an operation.
  case keychain(status: OSStatus)
}

extension AuthenticationFailure: LocalizedError {
  public var errorDescription: String? {
    String(localized: "Dropbox authentication failed.", bundle: #bundle)
  }

  public var failureReason: String? {
    switch self {
      case .tokenExpired:
        String(localized: "The access token expired and couldn’t be refreshed.", bundle: #bundle)
      case .tokenRevoked:
        String(localized: "Access to Dropbox was revoked.", bundle: #bundle)
      case .missingScope(let scope):
        String(
          localized: "The app registration is missing the “\(scope)” permission.",
          bundle: #bundle
        )
      case .invalidGrant:
        String(
          localized: "Dropbox rejected the authorization code or refresh token.",
          bundle: #bundle
        )
      case .stateMismatch:
        String(localized: "The authorization response failed its integrity check.", bundle: #bundle)
      case .authorizationDeclined:
        String(localized: "Zephyr wasn’t granted access to your Dropbox.", bundle: #bundle)
      case .authorizationRejected(let reason):
        String(localized: "Dropbox refused the authorization request: \(reason).", bundle: #bundle)
      case .malformedTokenResponse(let detail):
        String(
          localized: "The authorization response couldn’t be read: \(detail).",
          bundle: #bundle
        )
      case .keychain(let status):
        String(
          localized: "The keychain reported error \(status, format: .number).",
          bundle: #bundle
        )
    }
  }

  public var recoverySuggestion: String? {
    switch self {
      case .tokenExpired, .tokenRevoked, .invalidGrant, .stateMismatch, .malformedTokenResponse:
        String(
          localized: "Relink the account with “zephyr auth link” or from the app.",
          bundle: #bundle
        )
      case .authorizationDeclined, .authorizationRejected:
        String(
          localized: "Link the account again, and choose Allow on the Dropbox page.",
          bundle: #bundle
        )
      case .keychain:
        String(
          localized: "Unlock the login keychain, then link the account again.",
          bundle: #bundle
        )
      // Nothing the user can do: the app registration itself asks Dropbox for
      // too little, and only a new build can widen it.
      case .missingScope:
        nil
    }
  }

  /**
   The help-book topic, in Foundation's own slot for one — which is what AppKit
   reads to put a Help button on an alert presenting this error.

   Every case here leaves the account unusable, which is what the reauthorizing
   article is about. `.missingScope` returns nothing: it is a fault in the
   build rather than in the account, and a help button landing on an article
   about relinking would send the reader off to do something that cannot work.
   */
  public var helpAnchor: String? {
    switch self {
      case .missingScope: nil
      default: HelpAnchor.reauthorize.rawValue
    }
  }
}
