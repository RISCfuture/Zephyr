import Testing

@testable import libZephyr

/// A deterministic SplitMix64 generator for reproducible verifier generation.
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
struct PKCETests {
  private static let generatedLength = 43
  private static let allowedAlphabet =
    Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

  @Test
  func `matches RFC7636 appendix B vector`() throws {
    let verifier = try PKCEVerifier(validating: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
    #expect(verifier.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
  }

  @Test
  func `generates well formed verifiers`() {
    var generator = SplitMix64(seed: 0x5EED_1DEA)
    for _ in 0..<32 {
      let verifier = PKCEVerifier(using: &generator)
      #expect(verifier.value.count == Self.generatedLength)
      #expect(verifier.value.allSatisfy { Self.allowedAlphabet.contains($0) })
    }
  }

  @Test(arguments: [
    String(repeating: "a", count: 42),
    String(repeating: "a", count: 129),
    String(repeating: "a", count: 42) + "+"
  ])
  func `rejects malformed verifier`(_ candidate: String) {
    #expect(throws: PKCEValidationFailure(value: candidate)) {
      try PKCEVerifier(validating: candidate)
    }
  }
}
