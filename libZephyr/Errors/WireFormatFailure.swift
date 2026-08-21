import Foundation

/// A request Dropbox could not interpret, or a response Zephyr could not.
enum WireFormatFailure: WireError, Equatable {
  /// The response body did not match the route's schema.
  case malformedResponse(route: String, detail: String)
  /// Dropbox rejected the request itself as malformed (HTTP 400), which for a
  /// typed client means a bad argument rather than an unexpected wire format.
  case badRequest(route: String, detail: String?)
  /// The server returned a status code the route does not define.
  case unexpectedStatus(code: Int, requestID: String?)
  /// A request argument could not be encoded into the `Dropbox-API-Arg` header.
  case headerEncoding(detail: String)
}

extension WireFormatFailure: LocalizedError {
  public var errorDescription: String? {
    switch self {
      case .badRequest:
        String(localized: "Dropbox rejected a request.", bundle: #bundle)
      case .malformedResponse, .unexpectedStatus, .headerEncoding:
        String(localized: "Received an unexpected response from Dropbox.", bundle: #bundle)
    }
  }

  public var failureReason: String? {
    switch self {
      case let .malformedResponse(route, detail):
        String(
          localized: "The response from “\(route)” couldn’t be read: \(detail).",
          bundle: #bundle
        )
      case let .badRequest(route, detail):
        sentence(
          String(localized: "“\(route)” rejected its arguments.", bundle: #bundle),
          followedBy: detail
        )
      case let .unexpectedStatus(code, requestID):
        if let requestID {
          String(
            localized: "Received HTTP status \(code, format: .number) (request \(requestID)).",
            bundle: #bundle
          )
        } else {
          String(
            localized: "Received HTTP status \(code, format: .number).",
            bundle: #bundle
          )
        }
      case .headerEncoding(let detail):
        String(localized: "A request couldn’t be encoded: \(detail).", bundle: #bundle)
    }
  }

  /// `reason` alone, or with the detail Dropbox supplied as a second sentence.
  /// A rejection does not always explain itself, so the two are joined only
  /// when there is something to join.
  private func sentence(_ reason: String, followedBy detail: String?) -> String {
    guard let detail else { return reason }
    return "\(reason) \(detail)"
  }
}
