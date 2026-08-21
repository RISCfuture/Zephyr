import Foundation

/**
 A pure decision table for retrying failed Dropbox API requests.

 The policy never sleeps and never reads a clock: given how a request failed and how
 many times it has failed already, it answers with a ``Decision`` — wait some duration
 and try again, or give up — and the transport layer performs the actual waiting.

 The rules are ported from Maestral and the official Dropbox SDK, with one deliberate
 deviation: rate-limited requests are capped at a finite number of tries instead of
 retrying without bound.
 */
struct RetryPolicy: Sendable {
  /// The most tries a rate-limited request gets — a deliberate deviation from the
  /// Dropbox SDK, which retries HTTP 429 responses without bound.
  private static let maximumRateLimitedTries: UInt = 20

  /// The wait applied to a rate-limited request when the server sent no `Retry-After`.
  private static let fallbackRateLimitDelay = Duration.seconds(5)

  /// The most tries a request that hit a server error gets.
  private static let maximumServerErrorTries: UInt = 4

  /// The half-open interval a backoff's jitter factor is drawn from.
  private static let jitterRange: Range<Double> = 0..<1

  /// The most tries a corrupted transfer gets (Maestral's `MAX_TRANSFER_RETRIES`).
  private static let maximumDataCorruptionTries: UInt = 4

  /// The most tries a timed-out `files/list_folder/continue` poll gets.
  private static let maximumListFolderTimeoutTries: UInt = 3

  /// The fixed wait before re-polling `files/list_folder/continue` after a read timeout.
  private static let listFolderTimeoutDelay = Duration.seconds(3)

  /// The most tries a request gets after the connection under it dropped.
  private static let maximumConnectionLostTries: UInt = 4

  /**
   Decides whether a failed request should be tried again, and after how long a wait.

   `attempt` is 0-based: the number of failures already seen for this request. Each
   failure class allows an operation at most N tries in total, so once `attempt`
   reaches N the budget is spent and the decision is ``Decision/giveUp``; for any
   smaller `attempt` it is ``Decision/retry(after:)`` with the class's delay:

   - ``FailureClass/rateLimited(retryAfter:)`` — the server-provided `Retry-After`
     duration, or a 5-second fallback when absent; at most 20 tries.
   - ``FailureClass/serverError`` — an exponential backoff of `2^attempt × r` seconds,
     where `r` is drawn uniformly from `0..<1` using `generator`; at most 4 tries.
   - ``FailureClass/dataCorruption`` — the same jittered exponential backoff as
     ``FailureClass/serverError``, giving the bad copy time to settle; at most 4 tries.
   - ``FailureClass/listFolderTimeout`` — a fixed 3-second wait; at most 3 tries.
   - ``FailureClass/connectionLost`` — the same jittered exponential backoff as
     ``FailureClass/serverError``, giving the route time to come back; at most 4 tries.

   - Parameters:
     - failure: How the request failed.
     - attempt: The number of failures already seen for this request (0-based).
     - generator: The source of randomness for jittered backoff; consulted for
       ``FailureClass/serverError``, ``FailureClass/dataCorruption`` and
       ``FailureClass/connectionLost``, and only when the decision is to retry.
   - Returns: The transport layer's next move: wait and retry, or give up.
   */
  func decision(
    for failure: FailureClass,
    attempt: UInt,
    using generator: inout some RandomNumberGenerator
  ) -> Decision {
    switch failure {
      case .rateLimited(let retryAfter):
        decide(attempt: attempt, limit: Self.maximumRateLimitedTries) {
          retryAfter ?? Self.fallbackRateLimitDelay
        }
      case .serverError:
        decide(attempt: attempt, limit: Self.maximumServerErrorTries) {
          jitteredBackoff(attempt: attempt, using: &generator)
        }
      case .dataCorruption:
        decide(attempt: attempt, limit: Self.maximumDataCorruptionTries) {
          jitteredBackoff(attempt: attempt, using: &generator)
        }
      case .connectionLost:
        decide(attempt: attempt, limit: Self.maximumConnectionLostTries) {
          jitteredBackoff(attempt: attempt, using: &generator)
        }

      case .listFolderTimeout:
        decide(attempt: attempt, limit: Self.maximumListFolderTimeoutTries) {
          Self.listFolderTimeoutDelay
        }
    }
  }

  private func decide(attempt: UInt, limit: UInt, delay: () -> Duration) -> Decision {
    attempt < limit ? .retry(after: delay()) : .giveUp
  }

  private func jitteredBackoff(
    attempt: UInt,
    using generator: inout some RandomNumberGenerator
  ) -> Duration {
    .seconds(exp2(Double(attempt)) * Double.random(in: Self.jitterRange, using: &generator))
  }

  /// A classification of a Dropbox API failure the transport layer may retry.
  enum FailureClass: Sendable, Equatable {
    /// HTTP 429: the request was rejected for exceeding a rate limit, carrying the
    /// server's `Retry-After` duration when it provided one.
    case rateLimited(retryAfter: Duration?)

    /// HTTP 5xx: transient trouble on Dropbox's side.
    case serverError

    /// The transferred bytes failed verification: a `content_hash_mismatch` or
    /// `incorrect_offset` from the server, or a local hash check that didn't match.
    case dataCorruption

    /// A read timeout while long-polling the `files/list_folder/continue` route.
    case listFolderTimeout

    /// The connection under a request went away mid-flight: a radio going to
    /// sleep, an interface leaving, a route changing under an open socket.
    /// The request was never answered, so it is worth asking again unchanged.
    case connectionLost
  }

  /// The transport layer's next move for a failed request.
  enum Decision: Sendable, Equatable {
    /// Wait for the given duration, then try the request again.
    case retry(after: Duration)

    /// Stop retrying and surface the failure.
    case giveUp
  }
}
