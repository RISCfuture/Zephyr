import Foundation

@testable import libZephyr

/// A client already holding an unexpired access token, so the transport's
/// queued exchanges answer API calls rather than a token refresh.
func makeLinkedClient(transport: MockTransport) async -> DropboxClient {
  let provider = AccessTokenProvider(refreshToken: "unused", transport: transport)
  await provider.seed(accessToken: "tok", expiry: Date(timeIntervalSinceNow: 7200))
  return DropboxClient(transport: transport, tokenProvider: provider)
}
