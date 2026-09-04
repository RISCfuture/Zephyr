public import Foundation

/**
 The HTTP layer beneath ``DropboxClient``, abstracted so tests can substitute
 canned responses without touching the network.
 */
public protocol HTTPTransport: Sendable {
  /// Performs a request and returns the complete response body.
  func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)

  /**
   Performs a request and returns the complete response body, drawn at the
   pace a download is held to when `pacing` is set.

   An RPC body is normally small enough that draining the socket is the right
   thing to do. The exception is a route answering with rendered content,
   whose bytes cost the user what a download's do and deserve the same pacing
   — applied as they arrive, so the rate is governed rather than merely
   accounted for afterwards.
   */
  func execute(_ request: URLRequest, pacing: Bool) async throws -> (Data, HTTPURLResponse)

  /**
   Performs a request and writes the response body to `destination`,
   overwriting any existing file there.
   */
  func download(_ request: URLRequest, to destination: URL) async throws -> HTTPURLResponse
}

extension HTTPTransport {
  /// A transport that draws every body the same way answers both forms alike.
  public func execute(_ request: URLRequest, pacing _: Bool) async throws -> (
    Data, HTTPURLResponse
  ) {
    try await execute(request)
  }
}

/// The production ``HTTPTransport`` backed by a dedicated `URLSession`.
public struct URLSessionTransport: HTTPTransport {
  /// How many received bytes accumulate before each paced write.
  private static let throttledWriteSize = 128 * 1024

  private let session: URLSession

  /// The session bulk traffic uses once the user has declared this Mac's
  /// expensive networks fine to use. Low Data Mode is refused on it too.
  private let expensiveTolerantSession: URLSession?
  private let expensiveNetworkPolicy: ExpensiveNetworkPolicy?
  private let downloadThrottle: BandwidthThrottle?

  /// The session that carries the next request, which for bulk traffic is
  /// whichever one the user's answer about expensive networks calls for.
  private var activeSession: URLSession {
    guard let expensiveTolerantSession, expensiveNetworkPolicy?.isAllowed == true else {
      return session
    }
    return expensiveTolerantSession
  }

  /**
   Creates a transport with a session configured for the Dropbox API.

   - Parameters:
     - traffic: What the session's requests are for, which decides whether
       macOS may carry them over a path that costs the user something.
     - downloadThrottle: Paces received download bytes; `nil` leaves
       downloads unthrottled.
   */
  public init(traffic: Traffic = .userInitiated, downloadThrottle: BandwidthThrottle? = nil) {
    switch traffic {
      case .userInitiated:
        session = Self.session(allowsExpensiveNetworks: true, allowsLowDataMode: true)
        expensiveTolerantSession = nil
        expensiveNetworkPolicy = nil
      case .bulk(let policy):
        session = Self.session(allowsExpensiveNetworks: false, allowsLowDataMode: false)
        // Low Data Mode stays refused on both: the user's answer is about
        // what macOS guessed, and says nothing about what they instructed.
        expensiveTolerantSession = Self.session(
          allowsExpensiveNetworks: true,
          allowsLowDataMode: false
        )
        expensiveNetworkPolicy = policy
    }
    self.downloadThrottle = downloadThrottle
  }

  /**
   A session configured for the Dropbox API.

   Both sessions a bulk transport holds are built here, because a
   `URLSessionConfiguration` cannot be changed once its session is made: the
   user's answer about expensive networks picks between two sessions rather
   than editing one.
   */
  private static func session(
    allowsExpensiveNetworks: Bool,
    allowsLowDataMode: Bool
  ) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    // The engine owns retry, and it owns the reason the user reads. Waiting
    // for connectivity here would suspend a request inside `URLSession` with
    // nothing above able to say what it is waiting for or how long it has
    // been — least of all for bulk work, whose whole answer to an expensive
    // path is to say so and slow down rather than to hang.
    configuration.waitsForConnectivity = false
    configuration.httpAdditionalHeaders = nil
    configuration.allowsExpensiveNetworkAccess = allowsExpensiveNetworks
    configuration.allowsConstrainedNetworkAccess = allowsLowDataMode
    return URLSession(configuration: configuration)
  }

  private static func httpResponse(from response: URLResponse) throws -> HTTPURLResponse {
    guard let httpResponse = response as? HTTPURLResponse else {
      throw URLError(.badServerResponse)
    }
    return httpResponse
  }

  public func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await activeSession.data(for: request)
    return (data, try Self.httpResponse(from: response))
  }

  public func execute(_ request: URLRequest, pacing: Bool) async throws -> (Data, HTTPURLResponse) {
    guard pacing, let downloadThrottle, await downloadThrottle.isPacing else {
      return try await execute(request)
    }
    return try await throttledExecute(request, throttle: downloadThrottle)
  }

  /// Streams the response body in paced chunks so the received rate honors
  /// the throttle, at the cost of assembling the body a chunk at a time
  /// instead of letting `URLSession` hand it over whole.
  private func throttledExecute(
    _ request: URLRequest,
    throttle: BandwidthThrottle
  ) async throws -> (Data, HTTPURLResponse) {
    let (bytes, response) = try await activeSession.bytes(for: request)
    let httpResponse = try Self.httpResponse(from: response)

    var body = Data()
    var buffer = Data(capacity: Self.throttledWriteSize)
    for try await byte in bytes {
      buffer.append(byte)
      if buffer.count >= Self.throttledWriteSize {
        try await throttle.acquire(buffer.count)
        body.append(buffer)
        buffer.removeAll(keepingCapacity: true)
      }
    }
    if !buffer.isEmpty {
      try await throttle.acquire(buffer.count)
      body.append(buffer)
    }
    return (body, httpResponse)
  }

  public func download(_ request: URLRequest, to destination: URL) async throws -> HTTPURLResponse {
    guard let downloadThrottle, await downloadThrottle.isPacing else {
      let (temporaryURL, response) = try await activeSession.download(for: request)
      let httpResponse = try Self.httpResponse(from: response)
      let fileManager = FileManager.default
      try? fileManager.removeItem(at: destination)
      try fileManager.moveItem(at: temporaryURL, to: destination)
      return httpResponse
    }
    return try await throttledDownload(request, to: destination, throttle: downloadThrottle)
  }

  /// Streams the response body in paced chunks so the received rate honors
  /// the throttle, instead of letting `URLSession` drain the socket at will.
  private func throttledDownload(
    _ request: URLRequest,
    to destination: URL,
    throttle: BandwidthThrottle
  ) async throws -> HTTPURLResponse {
    let (bytes, response) = try await activeSession.bytes(for: request)
    let httpResponse = try Self.httpResponse(from: response)
    FileManager.default.createFile(atPath: destination.path, contents: nil)
    let handle = try FileHandle(forWritingTo: destination)
    defer { try? handle.close() }

    var buffer = Data(capacity: Self.throttledWriteSize)
    for try await byte in bytes {
      buffer.append(byte)
      if buffer.count >= Self.throttledWriteSize {
        try await throttle.acquire(buffer.count)
        try handle.write(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
      }
    }
    if !buffer.isEmpty {
      try await throttle.acquire(buffer.count)
      try handle.write(contentsOf: buffer)
    }
    return httpResponse
  }

  /**
   What a session's requests are for.

   The split is about who is waiting. Nobody is waiting on the index being
   walked or on the change feed being held open, so that traffic can be told
   to stay off a tethered iPhone. Somebody is waiting on a file they just
   double-clicked, and refusing to fetch it because the network looks
   expensive would be the app deciding it knows better.
   */
  public enum Traffic: Sendable {
    /// Work somebody asked for and is waiting on: materialization, uploads,
    /// the writes Finder makes, account and authentication calls.
    case userInitiated
    /// Work Zephyr does on its own: the initial listing, delta pages, the
    /// change feed. `policy` carries the user's standing answer about
    /// networks macOS only guesses are expensive.
    case bulk(ExpensiveNetworkPolicy)
  }
}
