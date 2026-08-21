import Foundation

/// The response of Dropbox's `oauth2/token` endpoint.
struct OAuthTokenResponse: Decodable {
  let accessToken: String
  let expiresIn: TimeInterval
  /// Present only when exchanging an authorization code with offline access.
  let refreshToken: String?
  /// Present only when exchanging an authorization code.
  let accountID: AccountIdentifier?

  private enum CodingKeys: String, CodingKey {
    case accessToken = "access_token"
    case expiresIn = "expires_in"
    case refreshToken = "refresh_token"
    case accountID = "account_id"
  }
}
