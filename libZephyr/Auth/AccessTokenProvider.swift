public import Foundation

/**
 Holds the account's refresh token and vends valid short-lived access tokens,
 refreshing them single-flight shortly before expiry.
 */
public actor AccessTokenProvider {
  /// How long before expiry a cached token is refreshed anyway.
  private static let earlyRefreshMargin: TimeInterval = 300

  private let refreshToken: String
  private let appKey: String
  private let transport: any HTTPTransport
  private var cached: (accessToken: String, expiry: Date)?
  private var refreshTask: Task<String, any Error>?

  /**
   Creates a provider for one account's long-lived refresh token.

   The provider starts with an empty cache, so the first ``validAccessToken()`` call
   performs a refresh. Callers that just completed the OAuth flow can skip that
   round trip by handing the token they already have to ``seed(accessToken:expiry:)``.

   - Parameters:
     - refreshToken: The account's refresh token, as returned by the OAuth flow.
     - appKey: The Dropbox app key the token was issued to.
     - transport: The transport used to reach the token endpoint; override it in tests.
   */
  public init(
    refreshToken: String,
    appKey: String = DropboxAppCredentials.appKey,
    transport: any HTTPTransport = URLSessionTransport()
  ) {
    self.refreshToken = refreshToken
    self.appKey = appKey
    self.transport = transport
  }

  /// Seeds the cache with a token obtained during linking.
  public func seed(accessToken: String, expiry: Date) {
    cached = (accessToken, expiry)
  }

  /**
   Returns a currently valid access token, refreshing it when the cached one
   is missing or near expiry. Concurrent callers share one refresh request.
   */
  public func validAccessToken() async throws -> String {
    if let cached, cached.expiry.timeIntervalSinceNow > Self.earlyRefreshMargin {
      return cached.accessToken
    }
    if let refreshTask {
      return try await refreshTask.value
    }
    let task = Task<String, any Error> { [refreshToken, appKey, transport] in
      let (accessToken, expiry) = try await DropboxOAuthFlow.refreshAccessToken(
        refreshToken: refreshToken,
        appKey: appKey,
        transport: transport
      )
      self.cache(accessToken: accessToken, expiry: expiry)
      return accessToken
    }
    refreshTask = task
    defer { refreshTask = nil }
    return try await task.value
  }

  private func cache(accessToken: String, expiry: Date) {
    cached = (accessToken, expiry)
  }
}
