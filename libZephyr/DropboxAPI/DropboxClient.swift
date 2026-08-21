import Foundation
import os

/// The namespace sent as `Dropbox-API-Path-Root` on path-based calls.
public struct PathRoot: Sendable, Equatable {
  public let namespaceID: NamespaceIdentifier

  var headerValue: String {
    #"{".tag": "root", "root": "\#(namespaceID.rawValue)"}"#
  }

  public init(namespaceID: NamespaceIdentifier) {
    self.namespaceID = namespaceID
  }
}

/**
 The path root a family of clients sends, held by reference so it can be
 re-resolved.

 Dropbox invalidates an account's root namespace when the member joins or
 leaves a team, and every path-based call fails until the new namespace is
 sent. Holding the root apart from the client value means the replacement
 reaches clients already copied and captured elsewhere, instead of leaving
 them addressing a namespace that no longer exists.
 */
actor PathRootHolder {
  private(set) var current: PathRoot

  init(_ root: PathRoot) {
    current = root
  }

  func adopt(_ root: PathRoot) {
    current = root
  }
}

/**
 The Dropbox API client: typed route calls over ``HTTPTransport`` with
 authentication, path-root headers, and retry/backoff handling.

 A value type of immutable parts — copies are cheap and share the same
 ``AccessTokenProvider``, `RetryCoordinator`, and path root. Account-level
 calls use a client without a path root; path-based calls use one derived
 with ``withPathRoot(_:)``, and ``adoptPathRoot(_:)`` re-resolves it for the
 whole family.
 */
public struct DropboxClient: Sendable {
  private static let userAgent = "Zephyr/0.1"

  let transport: any HTTPTransport
  let tokenProvider: AccessTokenProvider?
  let retryCoordinator: RetryCoordinator
  let pathRoot: PathRootHolder?
  let uploadThrottle: BandwidthThrottle?
  private let retryPolicy = RetryPolicy()

  /**
   - Parameter transport: Carries every request; the default speaks to Dropbox
     over `URLSession`.
   - Parameter tokenProvider: Supplies the bearer token and refreshes it as it
     expires. `nil` leaves only the unauthenticated routes usable — an
     authenticated one throws ``EngineFailure/notLinked``.
   - Parameter uploadThrottle: Paces upload-style request bodies; `nil`
     leaves uploads unthrottled. Download pacing belongs to the transport
     (see ``URLSessionTransport/init(traffic:downloadThrottle:)``).
   */
  public init(
    transport: any HTTPTransport = URLSessionTransport(),
    tokenProvider: AccessTokenProvider?,
    uploadThrottle: BandwidthThrottle? = nil
  ) {
    self.init(
      transport: transport,
      tokenProvider: tokenProvider,
      retryCoordinator: RetryCoordinator(),
      pathRoot: nil,
      uploadThrottle: uploadThrottle
    )
  }

  private init(
    transport: any HTTPTransport,
    tokenProvider: AccessTokenProvider?,
    retryCoordinator: RetryCoordinator,
    pathRoot: PathRootHolder?,
    uploadThrottle: BandwidthThrottle?
  ) {
    self.transport = transport
    self.tokenProvider = tokenProvider
    self.retryCoordinator = retryCoordinator
    self.pathRoot = pathRoot
    self.uploadThrottle = uploadThrottle
  }

  private static func encode(_ argument: some Encodable) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(argument)
  }

  private static func decode<Result: Decodable>(
    _ type: Result.Type,
    from data: Data,
    route: DropboxRoute
  ) throws -> Result {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    do {
      return try decoder.decode(type, from: data)
    } catch {
      throw malformedResponse(from: error, route: route)
    }
  }

  /**
   A decoding failure worth showing.

   A ``DecodingError`` names coding keys and Swift types, which say nothing to
   a reader, so its description goes to the log and the failure carries a
   general detail.
   */
  private static func malformedResponse(
    from error: any Error,
    route: DropboxRoute
  ) -> WireFormatFailure {
    ZephyrLog.transport.error(
      """
      Couldn’t decode the response from \(route.identifier, privacy: .public): \
      \(String(describing: error), privacy: .private)
      """
    )
    return .malformedResponse(
      route: route.identifier,
      detail: String(localized: "it didn’t match the expected format", bundle: #bundle)
    )
  }

  private static func timeInterval(from duration: Duration) -> TimeInterval {
    let components = duration.components
    return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) * 1e-18
  }

  private static func logRetry(of route: DropboxRoute, after delay: Duration, attempt: UInt) {
    ZephyrLog.transport.info(
      "Retrying \(route.identifier, privacy: .public) after \(String(describing: delay), privacy: .public) (attempt \(attempt))"
    )
  }

  /**
   Derives a client that sends the given path root on every call, sharing this
   client's token cache and backoff state.
   */
  public func withPathRoot(_ root: PathRoot) -> Self {
    Self(
      transport: transport,
      tokenProvider: tokenProvider,
      retryCoordinator: retryCoordinator,
      pathRoot: PathRootHolder(root),
      uploadThrottle: uploadThrottle
    )
  }

  /**
   Derives a client whose requests ride `transport`, sharing this client's
   token cache, backoff state, and path root.

   Sharing the path root is the difference from ``withPathRoot(_:)``: an
   account that moves between a personal Dropbox and a team space is
   re-resolved once, and both clients start sending the new root.
   */
  func usingTransport(_ transport: any HTTPTransport) -> Self {
    Self(
      transport: transport,
      tokenProvider: tokenProvider,
      retryCoordinator: retryCoordinator,
      pathRoot: pathRoot,
      uploadThrottle: uploadThrottle
    )
  }

  /**
   Sends `root` from here on, on this client and on every client derived from
   the same ``withPathRoot(_:)`` call.

   Call it after re-resolving the account's namespace, which changes when the
   member joins or leaves a team; a client without a path root ignores it.
   */
  public func adoptPathRoot(_ root: PathRoot) async {
    await pathRoot?.adopt(root)
  }

  // MARK: Route execution

  /**
   Calls an RPC-style route and decodes its JSON result.

   - Parameter pacingResponse: Whether the response body is content worth
     drawing at the download throttle's pace; see
     ``HTTPTransport/execute(_:pacing:)``.
   */
  func rpc<Result: Decodable & Sendable>(
    _ route: DropboxRoute,
    argument: some Encodable & Sendable,
    path: String? = nil,
    pacingResponse: Bool = false
  ) async throws -> Result {
    try await withRetries(route: route, path: path) { request in
      var request = request
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try Self.encode(argument)
      let (data, response) = try await transport.execute(request, pacing: pacingResponse)
      try self.checkStatus(response, body: data, route: route, path: path)
      return try Self.decode(Result.self, from: data, route: route)
    }
  }

  /// Calls an RPC-style route that returns no meaningful result.
  func rpcVoid(
    _ route: DropboxRoute,
    argument: some Encodable & Sendable,
    path: String? = nil
  ) async throws {
    try await withRetries(route: route, path: path) { request in
      var request = request
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try Self.encode(argument)
      let (data, response) = try await transport.execute(request)
      try self.checkStatus(response, body: data, route: route, path: path)
    }
  }

  /// Calls an upload-style route with the given body chunk.
  func upload<Result: Decodable & Sendable>(
    _ route: DropboxRoute,
    argument: some Encodable & Sendable,
    body: Data,
    path: String? = nil
  ) async throws -> Result {
    try await withRetries(route: route, path: path) { request in
      var request = request
      request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
      request.setValue(
        try DropboxAPIArgumentEncoder.headerValue(for: argument),
        forHTTPHeaderField: "Dropbox-API-Arg"
      )
      request.httpBody = body
      try await uploadThrottle?.acquire(body.count)
      let (data, response) = try await transport.execute(request)
      try self.checkStatus(response, body: data, route: route, path: path)
      return try Self.decode(Result.self, from: data, route: route)
    }
  }

  /// Calls an upload-style route whose success result is irrelevant
  /// (upload-session appends return an empty body).
  func uploadVoid(
    _ route: DropboxRoute,
    argument: some Encodable & Sendable,
    body: Data,
    path: String? = nil
  ) async throws {
    try await withRetries(route: route, path: path) { request in
      var request = request
      request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
      request.setValue(
        try DropboxAPIArgumentEncoder.headerValue(for: argument),
        forHTTPHeaderField: "Dropbox-API-Arg"
      )
      request.httpBody = body
      try await uploadThrottle?.acquire(body.count)
      let (data, response) = try await transport.execute(request)
      try self.checkStatus(response, body: data, route: route, path: path)
    }
  }

  /**
   Calls a download-style route, writing the content to `destination` and
   decoding the metadata from the `Dropbox-API-Result` response header.

   The caller owns content verification; this method only moves bytes.
   */
  func download<Result: Decodable & Sendable>(
    _ route: DropboxRoute,
    argument: some Encodable & Sendable,
    to destination: URL,
    path: String? = nil
  ) async throws -> Result {
    try await withRetries(route: route, path: path) { request in
      var request = request
      request.setValue(
        try DropboxAPIArgumentEncoder.headerValue(for: argument),
        forHTTPHeaderField: "Dropbox-API-Arg"
      )
      let response = try await transport.download(request, to: destination)
      guard response.statusCode == 200 else {
        let body = (try? Data(contentsOf: destination)) ?? Data()
        try? FileManager.default.removeItem(at: destination)
        throw DropboxErrorMapper.error(
          route: route,
          status: response.statusCode,
          body: body,
          headers: response.allHeaderFields,
          path: path
        )
      }
      guard let resultHeader = response.value(forHTTPHeaderField: "Dropbox-API-Result") else {
        throw WireFormatFailure.malformedResponse(
          route: route.identifier,
          detail: String(
            localized: "the Dropbox-API-Result header was missing",
            bundle: #bundle
          )
        )
      }
      return try Self.decode(Result.self, from: Data(resultHeader.utf8), route: route)
    }
  }

  // MARK: Request construction and retry

  private func withRetries<Result>(
    route: DropboxRoute,
    path: String?,
    attempt attemptBody: @Sendable (URLRequest) async throws -> Result
  ) async throws -> Result {
    var attempt: UInt = 0
    var generator = SystemRandomNumberGenerator()
    while true {
      try await retryCoordinator.waitIfBackedOff()
      let request = try await makeRequest(route: route)
      do {
        return try await attemptBody(request)
      } catch let signal as RateLimitedSignal {
        try await backOffOrRethrow(
          retryAfter: signal.retryAfter,
          attempt: &attempt,
          generator: &generator,
          route: route
        )
      } catch let signal as ServerErrorSignal {
        try await retryOrRethrow(
          failure: .serverError,
          attempt: &attempt,
          generator: &generator,
          route: route,
          giveUpError: ItemSyncFailure.serverError(
            path: path ?? "",
            detail: String(
              localized: "Dropbox returned HTTP status \(signal.status, format: .number).",
              bundle: #bundle
            )
          )
        )
      } catch let urlError as URLError {
        // Neither of the first two applies to a request that was never put on
        // the wire. A cancelled one was taken away, and a refused one was
        // declined by the system over what it would cost: there is no verdict
        // to retry towards, and asking again over the same path would only
        // spend what the refusal saved.
        if urlError.isCancellation { throw EngineFailure.cancelled }
        if let refusal = urlError.networkCostRefusal {
          throw EngineFailure.deferredForNetworkCost(reason: refusal)
        }
        if urlError.code == .timedOut, route.name.hasPrefix("list_folder") {
          try await retryOrRethrow(
            failure: .listFolderTimeout,
            attempt: &attempt,
            generator: &generator,
            route: route,
            giveUpError: EngineFailure.connection(detail: urlError.localizedDescription)
          )
        } else if urlError.isTransient {
          try await retryOrRethrow(
            failure: .connectionLost,
            attempt: &attempt,
            generator: &generator,
            route: route,
            giveUpError: EngineFailure.connection(detail: urlError.localizedDescription)
          )
        } else {
          throw EngineFailure.connection(detail: urlError.localizedDescription)
        }
      }
    }
  }

  private func retryOrRethrow(
    failure: RetryPolicy.FailureClass,
    attempt: inout UInt,
    generator: inout SystemRandomNumberGenerator,
    route: DropboxRoute,
    giveUpError: any Error
  ) async throws {
    switch retryPolicy.decision(for: failure, attempt: attempt, using: &generator) {
      case .retry(let delay):
        Self.logRetry(of: route, after: delay, attempt: attempt)
        try await ContinuousClock().sleep(for: delay)
        attempt += 1
      case .giveUp:
        throw giveUpError
    }
  }

  /**
   Hands a rate limit to the coordinator rather than waiting it out here.

   Dropbox rate-limits the account, not the request, so the wait belongs to
   the coordinator every request consults on its way out — and belongs there
   only once. The policy still decides whether the request has tries left,
   and names the wait when the response carried no `Retry-After`.
   */
  private func backOffOrRethrow(
    retryAfter: Duration?,
    attempt: inout UInt,
    generator: inout SystemRandomNumberGenerator,
    route: DropboxRoute
  ) async throws {
    let failure = RetryPolicy.FailureClass.rateLimited(retryAfter: retryAfter)
    switch retryPolicy.decision(for: failure, attempt: attempt, using: &generator) {
      case .retry(let delay):
        Self.logRetry(of: route, after: delay, attempt: attempt)
        await retryCoordinator.reportServerBackoff(delay)
        attempt += 1
      case .giveUp:
        throw EngineFailure.connection(
          detail: String(localized: "Dropbox is rate-limiting this account.", bundle: #bundle)
        )
    }
  }

  private func makeRequest(route: DropboxRoute) async throws -> URLRequest {
    var request = URLRequest(url: route.url)
    request.httpMethod = "POST"
    request.timeoutInterval = Self.timeInterval(from: route.timeout)
    request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
    if route.isAuthenticated {
      guard let tokenProvider else { throw EngineFailure.notLinked }
      let token = try await tokenProvider.validAccessToken()
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      // The notify host rejects the path-root header on unauthenticated
      // routes, so it rides along only with an Authorization header.
      if let pathRoot {
        request.setValue(
          await pathRoot.current.headerValue,
          forHTTPHeaderField: "Dropbox-API-Path-Root"
        )
      }
    }
    return request
  }

  private func checkStatus(
    _ response: HTTPURLResponse,
    body: Data,
    route: DropboxRoute,
    path: String?
  ) throws {
    guard response.statusCode == 200 else {
      throw DropboxErrorMapper.error(
        route: route,
        status: response.statusCode,
        body: body,
        headers: response.allHeaderFields,
        path: path
      )
    }
  }
}

/// The argument for routes that take none — encodes as JSON `null`.
struct NullArgument: Encodable, Sendable {
  func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encodeNil()
  }
}
