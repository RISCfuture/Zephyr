import Foundation
import Testing

@testable import libZephyr

/// A seeded SplitMix64 generator, so jittered backoff is reproducible in tests.
private struct SplitMix64: RandomNumberGenerator {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var mixed = state
    mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
    mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
    return mixed ^ (mixed >> 31)
  }
}

@Suite
struct RetryPolicyTests {
  private let policy = RetryPolicy()

  private func decision(for failure: RetryPolicy.FailureClass, attempt: UInt)
    -> RetryPolicy.Decision
  {
    var generator = SplitMix64(seed: 0)
    return policy.decision(for: failure, attempt: attempt, using: &generator)
  }

  @Test
  func `rate limited honors retry after falls back to five seconds and caps at twenty tries`() {
    #expect(
      decision(for: .rateLimited(retryAfter: .seconds(42)), attempt: 0)
        == .retry(after: .seconds(42))
    )
    #expect(decision(for: .rateLimited(retryAfter: nil), attempt: 0) == .retry(after: .seconds(5)))
    #expect(
      decision(for: .rateLimited(retryAfter: .seconds(1)), attempt: 19)
        == .retry(after: .seconds(1))
    )
    #expect(decision(for: .rateLimited(retryAfter: .seconds(1)), attempt: 20) == .giveUp)
  }

  @Test
  func `server error backs off exponentially with jitter and caps at four tries`() {
    var generator = SplitMix64(seed: 0x5EED)
    var reference = SplitMix64(seed: 0x5EED)
    for attempt: UInt in 0...3 {
      let expectedSeconds = exp2(Double(attempt)) * Double.random(in: 0..<1, using: &reference)
      let decision = policy.decision(for: .serverError, attempt: attempt, using: &generator)
      #expect(decision == .retry(after: .seconds(expectedSeconds)))
    }
    #expect(policy.decision(for: .serverError, attempt: 4, using: &generator) == .giveUp)
  }

  @Test
  func `data corruption backs off exponentially with jitter and caps at four tries`() {
    var generator = SplitMix64(seed: 0x5EED)
    var reference = SplitMix64(seed: 0x5EED)
    for attempt: UInt in 0...3 {
      let expectedSeconds = exp2(Double(attempt)) * Double.random(in: 0..<1, using: &reference)
      let decision = policy.decision(for: .dataCorruption, attempt: attempt, using: &generator)
      #expect(decision == .retry(after: .seconds(expectedSeconds)))
    }
    #expect(policy.decision(for: .dataCorruption, attempt: 4, using: &generator) == .giveUp)
  }

  @Test
  func `list folder timeout retries after three seconds and caps at three tries`() {
    for attempt: UInt in 0...2 {
      #expect(decision(for: .listFolderTimeout, attempt: attempt) == .retry(after: .seconds(3)))
    }
    #expect(decision(for: .listFolderTimeout, attempt: 3) == .giveUp)
  }

  @Test
  func `connection lost backs off exponentially with jitter and caps at four tries`() {
    var generator = SplitMix64(seed: 0xC0FFEE)
    var reference = SplitMix64(seed: 0xC0FFEE)
    for attempt: UInt in 0...3 {
      let expectedSeconds = exp2(Double(attempt)) * Double.random(in: 0..<1, using: &reference)
      let decision = policy.decision(for: .connectionLost, attempt: attempt, using: &generator)
      #expect(decision == .retry(after: .seconds(expectedSeconds)))
    }
    #expect(policy.decision(for: .connectionLost, attempt: 4, using: &generator) == .giveUp)
  }
}
