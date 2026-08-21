import Foundation

/**
 A Dropbox content hash: the lowercase hex SHA-256 of the concatenated SHA-256
 digests of a file's 4 MiB blocks.

 Compute one with `DropboxContentHasher`. Two files with equal hashes have
 identical content as far as Dropbox is concerned.
 */
public struct ContentHash: ValidatedStringWrapper {
  static let kind = IdentifierKind.contentHash

  private static let hexLength = 64

  public let rawValue: String

  public init(validating rawValue: String) throws {
    guard
      rawValue.count == Self.hexLength,
      rawValue.allSatisfy({ $0.isHexDigit && ($0.isNumber || $0.isLowercase) })
    else {
      throw IdentifierValidationFailure(kind: Self.kind, rawValue: rawValue)
    }
    self.rawValue = rawValue
  }

  /**
   Wraps hex that the framework itself produced and therefore knows to be well formed.

   ``DropboxContentHasher/finalize()`` renders a `SHA256.Digest` — always 32 bytes,
   always two lowercase hex characters per byte — so validation there could only ever
   succeed. Taking this initializer instead keeps the hasher total: it cannot throw and
   cannot trap, which matters because it runs inside the File Provider extension, where
   a trap takes down the whole sync session. Strings from outside the framework have no
   such guarantee and must go through ``init(validating:)``.

   - Parameter rawValue: Lowercase hex of exactly ``hexLength`` characters.
   */
  init(unchecked rawValue: String) {
    assert(
      rawValue.count == Self.hexLength
        && rawValue.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) },
      "ContentHash(unchecked:) given malformed hex: \(rawValue)"
    )
    self.rawValue = rawValue
  }
}
