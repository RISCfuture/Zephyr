import Foundation

/// The server rate-limited the request (HTTP 429 or `too_many_requests`).
/// Consumed by the client's retry loop; surfaces as a connection failure only
/// when retries are exhausted.
struct RateLimitedSignal: Error {
  let retryAfter: Duration?
}

/// The server failed transiently (HTTP 5xx). Consumed by the client's retry loop.
struct ServerErrorSignal: Error {
  let status: Int
  let requestID: String?
}

/// An upload-session append arrived at the wrong offset; the server reports
/// where to resume. Consumed by the upload session's recovery logic.
struct IncorrectOffsetSignal: Error {
  let correctOffset: UInt64
}

/// A route error this client has no specific mapping for. Carries the raw
/// details so nothing is silently swallowed.
struct DropboxRouteError: WireError {
  /// The route that failed, e.g. `files/list_folder`.
  let route: String
  /// The server's `error_summary`, when present.
  let summary: String?
  /// The chain of error-union tags.
  let tagPath: [String]
}

extension DropboxRouteError: LocalizedError {
  public var errorDescription: String? {
    String(localized: "Dropbox rejected a request.", bundle: #bundle)
  }

  public var failureReason: String? {
    String(
      localized: "The route “\(route)” failed: \(summary ?? tagPath.joined(separator: "/")).",
      bundle: #bundle
    )
  }
}
