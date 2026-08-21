import CryptoKit
import Foundation

/**
 An RFC 7636 code verifier and its S256 challenge.

 The challenge travels with the authorization request; the verifier stays secret
 until the token exchange, proving both requests came from the same client.
 */
public struct PKCEVerifier: Sendable, Equatable {
  private static let entropyByteCount = 32
  private static let minimumLength = 43, maximumLength = 128
  private static let unreservedPunctuation: Set<Character> = ["-", ".", "_", "~"]

  /// The verifier string, disclosed only in the token exchange.
  public let value: String

  /// The S256 code challenge: base64url(SHA256(ASCII(value))) without padding.
  public var challenge: String {
    Self.base64URLEncode(Data(SHA256.hash(data: Data(value.utf8))))
  }

  /// Generates a 43-character verifier from 32 bytes drawn from the given
  /// generator, base64url-encoded without padding.
  public init(using generator: inout some RandomNumberGenerator) {
    let entropy = (0..<Self.entropyByteCount).map { _ in
      UInt8.random(in: .min ... .max, using: &generator)
    }
    value = Self.base64URLEncode(Data(entropy))
  }

  /// Generates a verifier from the system's cryptographically secure generator.
  public init() {
    var generator = SystemRandomNumberGenerator()
    self.init(using: &generator)
  }

  /// Creates a verifier from an existing string, validating RFC 7636 rules
  /// (43...128 characters of `A-Z a-z 0-9 - . _ ~`).
  public init(validating value: String) throws {
    guard
      (Self.minimumLength...Self.maximumLength).contains(value.count),
      value.allSatisfy(Self.isAllowedCharacter)
    else {
      throw PKCEValidationFailure(value: value)
    }
    self.value = value
  }

  private static func isAllowedCharacter(_ character: Character) -> Bool {
    character.isASCII
      && (character.isLetter || character.isNumber || unreservedPunctuation.contains(character))
  }

  private static func base64URLEncode(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}

/// A malformed PKCE verifier string was rejected.
struct PKCEValidationFailure: AuthError, Equatable {
  /// The rejected string.
  let value: String
}

extension PKCEValidationFailure: LocalizedError {
  public var errorDescription: String? {
    String(localized: "Invalid PKCE code verifier.", bundle: #bundle)
  }

  public var failureReason: String? {
    String(localized: "“\(value)” is not a valid RFC 7636 code verifier.", bundle: #bundle)
  }
}
