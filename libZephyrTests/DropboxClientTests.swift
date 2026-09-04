import Foundation
import Testing

@testable import libZephyr

@Suite
struct DropboxClientTests {
  private static let accountJSON = """
    {
        "account_id": "dbid:AAH4f99T0taONIb-OurWxbNQ6ywGRopQngc",
        "name": {"display_name": "Franz Ferdinand (Personal)"},
        "email": "franz@example.com",
        "email_verified": true,
        "disabled": false,
        "country": "US",
        "locale": "en",
        "account_type": {".tag": "basic"},
        "root_info": {
            ".tag": "user",
            "root_namespace_id": "3235641",
            "home_namespace_id": "3235641"
        }
    }
    """

  private static let fileMetadataJSON = """
    {
        ".tag": "file",
        "id": "id:a4ayc_80_OEAAAAAAAAAXw",
        "name": "Prime_Numbers.txt",
        "path_lower": "/homework/math/prime_numbers.txt",
        "path_display": "/Homework/Math/Prime_Numbers.txt",
        "client_modified": "2015-05-12T15:50:38Z",
        "server_modified": "2015-05-12T15:50:38Z",
        "rev": "a1c10ce0dd78",
        "size": 7212,
        "content_hash": "a4a5f2b7e2c31d0f9e8d7c6b5a493827160f5e4d3c2b1a09f8e7d6c5b4a39281"
    }
    """

  private static let notFoundJSON = """
    {
        "error_summary": "path/not_found/..",
        "error": {".tag": "path", "path": {".tag": "not_found"}}
    }
    """

  /// A cancelled request is the caller walking away, not Dropbox being out of
  /// reach. Reading it as a connection failure stops the account and spends
  /// the notification kept for syncing that has genuinely stopped — on a
  /// request that was never answered either way.
  @Test
  func `a cancelled request reads as cancelled rather than as a lost connection`() async throws {
    let transport = MockTransport()
    let client = await makeLinkedClient(transport: transport)
    await transport.enqueueFailure(.cancelled)

    await #expect(throws: EngineFailure.cancelled) {
      try await client.currentAccount()
    }
  }

  /// A network that went away is a connection failure, and is retried before
  /// it is called one — the branch a cancellation must not fall into.
  @Test
  func `a lost network still reads as a connection failure`() async throws {
    let transport = MockTransport()
    let client = await makeLinkedClient(transport: transport)
    for _ in 0..<8 { await transport.enqueueFailure(.notConnectedToInternet) }

    await #expect(throws: (any Error).self) {
      try await client.currentAccount()
    }
    let attempts = await transport.requests.count
    #expect(attempts > 1, "a transient failure should have been retried")
  }

  /// A request macOS declined to carry over a metered path arrives under a
  /// code the transient family already lists, so it has to be told apart
  /// before that branch: retrying it four times would spend the battery the
  /// refusal saved, and would end at a sync issue naming a connection that
  /// was never lost.
  @Test
  func `a refusal over what the path costs is deferred rather than retried`() async throws {
    let transport = MockTransport()
    let client = await makeLinkedClient(transport: transport)
    await transport.enqueueFailure(
      URLError(
        .dataNotAllowed,
        userInfo: [
          NSURLErrorNetworkUnavailableReasonKey:
            URLError.NetworkUnavailableReason.constrained.rawValue
        ]
      )
    )

    await #expect(throws: EngineFailure.deferredForNetworkCost(reason: .constrained)) {
      try await client.currentAccount()
    }
    // The queue traps when answered empty, so one queued exchange having
    // sufficed is itself proof that nothing was retried.
    #expect(await transport.requests.count == 1)
  }

  @Test
  func `RPC sends authorized JSON request and decodes result`() async throws {
    let transport = MockTransport()
    let client = await makeLinkedClient(transport: transport)
    await transport.enqueueJSON(Self.accountJSON)

    let account = try await client.currentAccount()

    #expect(account.accountID.rawValue == "dbid:AAH4f99T0taONIb-OurWxbNQ6ywGRopQngc")
    #expect(account.displayName == "Franz Ferdinand (Personal)")
    #expect(account.email == "franz@example.com")
    #expect(account.accountType == .basic)
    #expect(account.rootInfo.rootNamespaceID.rawValue == "3235641")

    let requests = await transport.requests
    let request = try #require(requests.first)
    #expect(request.url?.absoluteString == "https://api.dropboxapi.com/2/users/get_current_account")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    let body = try #require(request.httpBody)
    #expect(String(bytes: body, encoding: .utf8) == "null")
  }

  @Test
  func `with path root sends path root header only on derived client`() async throws {
    let transport = MockTransport()
    let client = await makeLinkedClient(transport: transport)
    await transport.enqueueJSON(Self.fileMetadataJSON)
    await transport.enqueueJSON(Self.fileMetadataJSON)
    let specifier = PathSpecifier.path(
      try DropboxPath(validating: "/Homework/Math/Prime_Numbers.txt")
    )

    let metadata = try await client.metadata(for: specifier)
    let rooted = client.withPathRoot(
      PathRoot(namespaceID: try NamespaceIdentifier(validating: "1234"))
    )
    _ = try await rooted.metadata(for: specifier)

    #expect(metadata?.name == "Prime_Numbers.txt")
    let requests = await transport.requests
    try #require(requests.count == 2)
    #expect(requests[0].value(forHTTPHeaderField: "Dropbox-API-Path-Root") == nil)
    let header = try #require(requests[1].value(forHTTPHeaderField: "Dropbox-API-Path-Root"))
    #expect(header.contains("1234"))
  }

  @Test
  func `longpoll needs no token provider and sends no authorization`() async throws {
    let transport = MockTransport()
    let client = DropboxClient(transport: transport, tokenProvider: nil)
      .withPathRoot(PathRoot(namespaceID: try NamespaceIdentifier(validating: "564666")))
    await transport.enqueueJSON(#"{"changes": true, "backoff": 30}"#)

    let result = try await client.waitForChanges(after: try DeltaCursor(validating: "cursor-123"))

    #expect(result == LongpollResult(changes: true, backoff: .seconds(30)))
    let requests = await transport.requests
    let request = try #require(requests.first)
    #expect(
      request.url?.absoluteString == "https://notify.dropboxapi.com/2/files/list_folder/longpoll"
    )
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    // The notify host 400s on the path-root header, even from a rooted client.
    #expect(request.value(forHTTPHeaderField: "Dropbox-API-Path-Root") == nil)
  }

  @Test
  func `metadata returns nil when nothing exists at path`() async throws {
    let transport = MockTransport()
    let client = await makeLinkedClient(transport: transport)
    await transport.enqueueJSON(Self.notFoundJSON, status: 409)

    let metadata = try await client.metadata(
      for: .path(try DropboxPath(validating: "/missing.txt"))
    )

    #expect(metadata == nil)
  }

  @Test
  func `retries rate limited request after server backoff`() async throws {
    let transport = MockTransport()
    let client = await makeLinkedClient(transport: transport)
    await transport.enqueue(MockTransport.Exchange(status: 429, headers: ["Retry-After": "0"]))
    await transport.enqueueJSON(Self.accountJSON)

    let account = try await client.currentAccount()

    #expect(account.email == "franz@example.com")
    let requests = await transport.requests
    #expect(requests.count == 2)
  }

  @Test
  func `retries server error and recovers`() async throws {
    let transport = MockTransport()
    let client = await makeLinkedClient(transport: transport)
    await transport.enqueue(MockTransport.Exchange(status: 500))
    await transport.enqueueJSON(Self.accountJSON)

    let account = try await client.currentAccount()

    #expect(account.displayName == "Franz Ferdinand (Personal)")
    let requests = await transport.requests
    #expect(requests.count == 2)
  }

  @Test
  func `concurrent token requests share one refresh`() async throws {
    let transport = MockTransport()
    let provider = AccessTokenProvider(
      refreshToken: "refresh-token",
      appKey: "test-app-key",
      transport: transport
    )
    await provider.seed(accessToken: "stale", expiry: Date(timeIntervalSinceNow: -60))
    await transport.enqueueJSON(
      #"{"access_token": "fresh", "token_type": "bearer", "expires_in": 14400}"#
    )

    let tokens = try await withThrowingTaskGroup(of: String.self) { group in
      for _ in 0..<5 {
        group.addTask { try await provider.validAccessToken() }
      }
      return try await group.reduce(into: [String]()) { $0.append($1) }
    }

    #expect(tokens == Array(repeating: "fresh", count: 5))
    let requests = await transport.requests
    try #require(requests.count == 1)
    #expect(requests[0].url?.absoluteString == "https://api.dropboxapi.com/oauth2/token")
  }

  @Test
  func `refresh rejected with invalid grant surfaces as invalid grant`() async throws {
    let transport = MockTransport()
    let provider = AccessTokenProvider(
      refreshToken: "revoked",
      appKey: "test-app-key",
      transport: transport
    )
    await transport.enqueueJSON(
      #"{"error": "invalid_grant", "error_description": "refresh token is invalid or revoked"}"#,
      status: 400
    )

    do {
      _ = try await provider.validAccessToken()
      Issue.record("validAccessToken() should have thrown AuthenticationFailure.invalidGrant")
    } catch AuthenticationFailure.invalidGrant {
    } catch {
      Issue.record("Expected AuthenticationFailure.invalidGrant, got \(error)")
    }
  }
}
