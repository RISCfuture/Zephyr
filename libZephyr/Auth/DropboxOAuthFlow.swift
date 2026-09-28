public import Foundation
import CryptoKit
import os

/**
 Dropbox's OAuth 2 authorization-code flow with PKCE, as a public client:
 no client secret exists anywhere.

 Two redirect styles are supported: ``RedirectStyle/outOfBand`` shows the
 authorization code on dropbox.com for the user to paste into a terminal
 (Maestral's flow), and ``RedirectStyle/customScheme`` round-trips through an
 `ASWebAuthenticationSession` in the app.
 */
public struct DropboxOAuthFlow: Sendable {

  private static let authorizeEndpoint = URL(string: "https://www.dropbox.com/oauth2/authorize")!
  private static let tokenEndpoint = URL(string: "https://api.dropboxapi.com/oauth2/token")!

  /// The retry budget a token request shares with the rest of the Dropbox API.
  private static let retryPolicy = RetryPolicy()

  /// The PKCE verifier for this flow instance.
  public let verifier: PKCEVerifier
  /// The CSRF token round-tripped through the `state` parameter.
  public let state: String

  private let appKey: String
  private let redirect: RedirectStyle
  private let transport: any HTTPTransport

  /// The redirect URI for ``RedirectStyle/customScheme``, or `nil` for out-of-band.
  public var redirectURI: String? {
    switch redirect {
      case .outOfBand: nil
      case .customScheme: "db-\(appKey)://oauth"
    }
  }

  /// The scheme ``redirectURI`` redirects to, which a web authentication
  /// session matches its callback against, or `nil` for out-of-band.
  public var callbackScheme: String? {
    redirectURI.flatMap { URLComponents(string: $0)?.scheme }
  }

  /// The URL to open in a browser to begin authorization.
  public var authorizationURL: URL {
    var components = URLComponents(url: Self.authorizeEndpoint, resolvingAgainstBaseURL: false)!
    var queryItems = [
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "client_id", value: appKey),
      URLQueryItem(name: "token_access_type", value: "offline"),
      URLQueryItem(name: "code_challenge", value: verifier.challenge),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
      URLQueryItem(name: "state", value: state)
    ]
    if let redirectURI {
      queryItems.append(URLQueryItem(name: "redirect_uri", value: redirectURI))
    }
    components.queryItems = queryItems
    return components.url!
  }

  public init(
    appKey: String = DropboxAppCredentials.appKey,
    redirect: RedirectStyle = .outOfBand,
    transport: any HTTPTransport = URLSessionTransport()
  ) {
    self.appKey = appKey
    self.redirect = redirect
    self.transport = transport
    verifier = PKCEVerifier()
    state = Self.makeState()
  }

  /// Redeems a refresh token for a short-lived access token.
  static func refreshAccessToken(
    refreshToken: String,
    appKey: String,
    transport: any HTTPTransport
  ) async throws -> (accessToken: String, expiry: Date) {
    let response = try await requestToken(
      form: [
        "grant_type": "refresh_token",
        "refresh_token": refreshToken,
        "client_id": appKey
      ],
      transport: transport
    )
    return (response.accessToken, Date(timeIntervalSinceNow: response.expiresIn))
  }

  /**
   Redeems a token request, retrying while Dropbox is the one at fault.

   The token endpoint is a Dropbox service like any other and has the same bad
   minutes, so a transient answer from it earns the retry budget every other
   route gets rather than stopping the account outright.
   */
  private static func requestToken(
    form: [String: String],
    transport: any HTTPTransport
  ) async throws -> OAuthTokenResponse {
    var attempt: UInt = 0
    var generator = SystemRandomNumberGenerator()
    while true {
      do {
        return try await attemptToken(form: form, transport: transport)
      } catch let signal as RateLimitedSignal {
        try await waitOrGiveUp(
          .rateLimited(retryAfter: signal.retryAfter),
          status: 429,
          attempt: &attempt,
          generator: &generator
        )
      } catch let signal as ServerErrorSignal {
        try await waitOrGiveUp(
          .serverError,
          status: signal.status,
          attempt: &attempt,
          generator: &generator
        )
      }
    }
  }

  private static func attemptToken(
    form: [String: String],
    transport: any HTTPTransport
  ) async throws -> OAuthTokenResponse {
    var request = URLRequest(url: tokenEndpoint)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = formEncode(form).data(using: .utf8)
    let (data, response): (Data, HTTPURLResponse)
    do {
      (data, response) = try await transport.execute(request)
    } catch let urlError as URLError {
      if urlError.isCancellation { throw EngineFailure.cancelled }
      throw EngineFailure.connection(detail: urlError.localizedDescription)
    }
    guard response.statusCode == 200 else {
      throw refusal(status: response.statusCode, body: data, headers: response.allHeaderFields)
    }
    do {
      return try JSONDecoder().decode(OAuthTokenResponse.self, from: data)
    } catch {
      throw malformedTokenResponse(from: error)
    }
  }

  /**
   What a non-200 from the token endpoint means.

   A rejected grant is the only one of these the user can do anything about.
   The rest are Dropbox having trouble, and they leave here as the transport
   signals the retry loop consumes: sending someone to relink an authorization
   that was never in question would have them redo the one thing that was
   working.
   */
  private static func refusal(
    status: Int,
    body: Data,
    headers: [AnyHashable: Any]
  ) -> any Error {
    let details = DropboxErrorDetails.parse(body: body)
    if details?.fields["error"]?.stringValue == "invalid_grant" {
      return AuthenticationFailure.invalidGrant
    }
    if let text = String(data: body, encoding: .utf8), text.contains("invalid_grant") {
      return AuthenticationFailure.invalidGrant
    }
    switch status {
      case 429:
        return RateLimitedSignal(
          retryAfter: DropboxErrorMapper.retryAfter(headers: headers, details: details)
        )
      case 500...:
        return ServerErrorSignal(status: status, requestID: nil)
      default:
        return AuthenticationFailure.malformedTokenResponse(
          detail: String(
            localized:
              "the token endpoint returned status \(status, format: .number.grouping(.never))",
            bundle: #bundle
          )
        )
    }
  }

  /**
   Waits out the policy's backoff, or gives up.

   Giving up is a connection failure rather than an authentication one: the
   account's credentials were never the thing that failed, and the tier it
   lands in decides whether syncing waits for the user or simply picks itself
   back up when Dropbox does.
   */
  private static func waitOrGiveUp(
    _ failure: RetryPolicy.FailureClass,
    status: Int,
    attempt: inout UInt,
    generator: inout SystemRandomNumberGenerator
  ) async throws {
    switch retryPolicy.decision(for: failure, attempt: attempt, using: &generator) {
      case .retry(let delay):
        logRetry(status: status, after: delay, attempt: attempt)
        try await ContinuousClock().sleep(for: delay)
        attempt += 1
      case .giveUp:
        throw EngineFailure.connection(
          detail: String(
            localized:
              "Dropbox’s token endpoint returned status \(status, format: .number.grouping(.never)).",
            bundle: #bundle
          )
        )
    }
  }

  private static func logRetry(status: Int, after delay: Duration, attempt: UInt) {
    ZephyrLog.auth.info(
      "Token endpoint returned \(status, privacy: .public); retrying after \(String(describing: delay), privacy: .public) (attempt \(attempt))"
    )
  }

  /**
   A token-response decoding failure worth showing.

   A ``DecodingError`` names coding keys and Swift types, which say nothing to
   a reader, so its description goes to the log and the failure carries a
   general detail.
   */
  private static func malformedTokenResponse(from error: any Error) -> AuthenticationFailure {
    ZephyrLog.auth.error(
      "Couldn’t decode the token response: \(String(describing: error), privacy: .private)"
    )
    return .malformedTokenResponse(
      detail: String(localized: "it didn’t match the expected format", bundle: #bundle)
    )
  }

  private static func formEncode(_ form: [String: String]) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return
      form
      .sorted { $0.key < $1.key }
      .map { key, value in
        let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        return "\(key)=\(encodedValue)"
      }
      .joined(separator: "&")
  }

  private static func makeState() -> String {
    var generator = SystemRandomNumberGenerator()
    return (0..<4)
      .map { _ in String(generator.next(), radix: 36) }
      .joined()
  }

  /// The failure a callback's `error` parameter reports, or `nil` when it carries none.
  private static func refusal(reportedIn components: URLComponents?) -> AuthenticationFailure? {
    guard let components, let error = components.queryItems?.value(named: "error") else {
      return nil
    }
    guard error != "access_denied" else { return .authorizationDeclined }
    return .authorizationRejected(
      reason: components.formDecodedQueryValue(named: "error_description") ?? error
    )
  }

  /**
   Exchanges the callback URL of a web authentication session for tokens
   (``RedirectStyle/customScheme``).

   The callback must carry back the `state` this flow generated; one that
   carries none fails its integrity check rather than skipping it.

   - Throws: ``AuthenticationFailure`` when the user declined, when Dropbox
     refused the request, or when the callback fails its `state` check.
   */
  public func exchange(callbackURL: URL) async throws -> LinkResult {
    let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
    let query = components?.queryItems ?? []
    if let refusal = Self.refusal(reportedIn: components) {
      throw refusal
    }
    guard query.value(named: "state") == state else {
      throw AuthenticationFailure.stateMismatch
    }
    guard let code = query.value(named: "code") else {
      throw AuthenticationFailure.malformedTokenResponse(
        detail: String(localized: "the callback carried no authorization code", bundle: #bundle)
      )
    }
    return try await exchange(code: code)
  }

  /**
   Exchanges an authorization code for tokens.

   ``RedirectStyle/outOfBand`` flows pass the code the user pasted from
   dropbox.com. The ``RedirectStyle/customScheme`` flow arrives here through
   ``exchange(callbackURL:)``, once the callback has passed its `state` check.

   - Throws: ``AuthenticationFailure`` when Dropbox rejects the code.
   */
  public func exchange(code: String) async throws -> LinkResult {
    var form = [
      "grant_type": "authorization_code",
      "code": code.trimmingCharacters(in: .whitespacesAndNewlines),
      "client_id": appKey,
      "code_verifier": verifier.value
    ]
    if let redirectURI {
      form["redirect_uri"] = redirectURI
    }
    let response = try await Self.requestToken(form: form, transport: transport)
    guard let refreshToken = response.refreshToken, let accountID = response.accountID else {
      throw AuthenticationFailure.malformedTokenResponse(
        detail: String(localized: "it carried no refresh token or account", bundle: #bundle)
      )
    }
    return LinkResult(
      accountID: accountID,
      refreshToken: refreshToken,
      accessToken: response.accessToken,
      accessTokenExpiry: Date(timeIntervalSinceNow: response.expiresIn)
    )
  }

  /// How the authorization code returns to the client.
  public enum RedirectStyle: Sendable {
    /// No redirect URI: Dropbox displays the code for the user to copy.
    case outOfBand
    /// Redirect to `db-{appKey}://oauth`, for in-app web authentication sessions.
    case customScheme
  }

  /// The linked account and refresh token an authorization produces.
  public struct LinkResult: Sendable {
    public let accountID: AccountIdentifier
    public let refreshToken: String
    public let accessToken: String
    public let accessTokenExpiry: Date
  }
}

extension [URLQueryItem] {
  /// The value of the first item named `name`, or `nil` when there is none.
  fileprivate func value(named name: String) -> String? {
    first { $0.name == name }?.value
  }
}

extension URLComponents {
  /**
   The value of query item `name`, read as `application/x-www-form-urlencoded`.

   An OAuth 2 redirect carries its parameters form-encoded, so a space arrives
   as `+`. ``queryItems`` percent-decodes but leaves that `+` in place, which
   would spell it verbatim into a message shown to the user; decoding from the
   still-encoded items keeps a literal plus (sent as `%2B`) intact.
   */
  fileprivate func formDecodedQueryValue(named name: String) -> String? {
    guard let items = percentEncodedQueryItems, let encoded = items.value(named: name) else {
      return nil
    }
    let spaced = encoded.replacingOccurrences(of: "+", with: " ")
    return spaced.removingPercentEncoding ?? spaced
  }
}
