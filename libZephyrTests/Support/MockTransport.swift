import Foundation

@testable import libZephyr

/**
 An `HTTPTransport` that answers from a queue of canned exchanges while
 recording every request it receives.

 Answering from an empty queue is a test bug and traps immediately, so a test
 that enqueues exactly N exchanges also proves exactly N requests were made.
 */
actor MockTransport: HTTPTransport {
  /// Every executed or downloaded request, in order, with `httpBody` as the client set it.
  private(set) var requests: [URLRequest] = []

  private var queue: [Exchange] = []
  private var requestHook: (@Sendable (URLRequest) async -> Void)?

  private static func response(to request: URLRequest, for exchange: Exchange) -> HTTPURLResponse {
    HTTPURLResponse(
      url: request.url!,
      statusCode: exchange.status,
      httpVersion: "HTTP/1.1",
      headerFields: exchange.headers
    )!
  }

  /// Appends a canned exchange to the response queue.
  func enqueue(_ exchange: Exchange) {
    queue.append(exchange)
  }

  /// Appends a canned JSON response to the response queue.
  func enqueueJSON(_ json: String, status: Int = 200, headers: [String: String] = [:]) {
    enqueue(Exchange(status: status, headers: headers, body: Data(json.utf8)))
  }

  /// Appends a request that never reaches Dropbox, failing the way URL loading
  /// fails when the network — or the caller — takes the request away.
  func enqueueFailure(_ code: URLError.Code) {
    enqueue(Exchange(failure: URLError(code)))
  }

  /// Queues a failure carrying its own user info, for the errors whose code
  /// alone does not say what happened.
  func enqueueFailure(_ error: URLError) {
    enqueue(Exchange(failure: error))
  }

  /// Installs a hook awaited before each request is answered.
  func setRequestHook(_ hook: (@Sendable (URLRequest) async -> Void)?) {
    requestHook = hook
  }

  func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let exchange = await answer(request)
    if let failure = exchange.failure { throw failure }
    return (exchange.body, Self.response(to: request, for: exchange))
  }

  func download(_ request: URLRequest, to destination: URL) async throws -> HTTPURLResponse {
    let exchange = await answer(request)
    if let failure = exchange.failure { throw failure }
    try exchange.body.write(to: destination)
    return Self.response(to: request, for: exchange)
  }

  private func answer(_ request: URLRequest) async -> Exchange {
    requests.append(request)
    if let requestHook {
      await requestHook(request)
    }
    guard !queue.isEmpty else {
      fatalError(
        "MockTransport received an unexpected request: \(request.url?.absoluteString ?? "<no URL>")"
      )
    }
    return queue.removeFirst()
  }

  /// One canned HTTP response, or the failure that stands in for one.
  struct Exchange: Sendable {
    var status: Int = 200
    var headers: [String: String] = [:]
    var body = Data()

    /// What the transport throws instead of answering. The failures that
    /// matter most to the client — a lost network, a cancelled task — never
    /// reach a status code, so a queue of responses alone cannot pose them.
    var failure: URLError?
  }
}
