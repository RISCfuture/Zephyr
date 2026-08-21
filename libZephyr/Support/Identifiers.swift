import Foundation

/**
 A validated, domain-restricted string wrapper.

 Conforming types get `Codable` behavior that round-trips the raw string and re-runs
 validation on decode, so malformed wire data fails loudly instead of propagating.
 */
protocol ValidatedStringWrapper: Sendable, Hashable, Codable, CustomStringConvertible {
  // periphery:ignore
  /**
   The kind of value this type wraps, which decides how a validation failure
   describes itself.

   Every conformer reads its own ``kind`` directly rather than through the
   protocol, so nothing dispatches this requirement; it is what obliges each
   identifier to name itself in the failure it throws.
   */
  static var kind: IdentifierKind { get }

  /// The wrapped string exactly as the Dropbox API represents it.
  var rawValue: String { get }

  /// Creates a value after validating the string's form, throwing when malformed.
  init(validating rawValue: String) throws
}

extension ValidatedStringWrapper {
  /// The wrapped string, so interpolating an identifier prints what Dropbox sent.
  public var description: String { rawValue }

  /// Decodes the wrapper from a single string value, re-running validation so a
  /// malformed identifier surfaces as a `DecodingError` at the point it arrives.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    do {
      try self.init(validating: container.decode(String.self))
    } catch {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "\(error)")
    }
  }

  /// Encodes the wrapper as its bare string, matching the shape Dropbox expects.
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// The kind of value a ``ValidatedStringWrapper`` carries, which names it in a
/// validation failure.
enum IdentifierKind: Sendable {
  case fileIdentifier
  case accountIdentifier
  case namespaceIdentifier
  case fileRevision
  case uploadSessionIdentifier
  case deltaCursor
  case contentHash
}

/// A malformed identifier string was rejected.
struct IdentifierValidationFailure: WireError, Equatable {
  /// The kind of value that rejected the string.
  let kind: IdentifierKind
  /// The rejected string.
  let rawValue: String
}

extension IdentifierValidationFailure: LocalizedError {
  public var errorDescription: String? {
    String(localized: "Invalid Dropbox identifier.", bundle: #bundle)
  }

  public var failureReason: String? {
    switch kind {
      case .fileIdentifier:
        String(
          localized: "“\(rawValue)” is not a valid Dropbox file identifier.",
          bundle: #bundle
        )
      case .accountIdentifier:
        String(
          localized: "“\(rawValue)” is not a valid Dropbox account identifier.",
          bundle: #bundle
        )
      case .namespaceIdentifier:
        String(
          localized: "“\(rawValue)” is not a valid Dropbox namespace identifier.",
          bundle: #bundle
        )
      case .fileRevision:
        String(localized: "“\(rawValue)” is not a valid Dropbox file revision.", bundle: #bundle)
      case .uploadSessionIdentifier:
        String(
          localized: "“\(rawValue)” is not a valid Dropbox upload session identifier.",
          bundle: #bundle
        )
      case .deltaCursor:
        String(localized: "“\(rawValue)” is not a valid Dropbox delta cursor.", bundle: #bundle)
      case .contentHash:
        String(localized: "“\(rawValue)” is not a valid Dropbox content hash.", bundle: #bundle)
    }
  }
}

/// The stable identifier of a Dropbox file or folder (an `id:`-prefixed string).
/// Survives moves and renames; Zephyr also uses it as the File Provider item identifier.
public struct DropboxFileIdentifier: ValidatedStringWrapper {
  static let kind = IdentifierKind.fileIdentifier
  public let rawValue: String

  public init(validating rawValue: String) throws {
    guard rawValue.hasPrefix("id:"), rawValue.count > 3 else {
      throw IdentifierValidationFailure(kind: Self.kind, rawValue: rawValue)
    }
    self.rawValue = rawValue
  }
}

/// The identifier of a Dropbox account (a `dbid:`-prefixed string).
public struct AccountIdentifier: ValidatedStringWrapper {
  static let kind = IdentifierKind.accountIdentifier
  private static let prefix = "dbid:"
  public let rawValue: String

  /**
   The account in the form used for File Provider domain identifiers, which
   forbid `:` — the `dbid:` prefix is stripped, leaving URL-safe base64.
   */
  public var providerDomainIdentifier: String {
    String(rawValue.dropFirst(Self.prefix.count))
  }

  public init(validating rawValue: String) throws {
    guard rawValue.hasPrefix(Self.prefix), rawValue.count > Self.prefix.count else {
      throw IdentifierValidationFailure(kind: Self.kind, rawValue: rawValue)
    }
    self.rawValue = rawValue
  }

  /// Recovers an account identifier from its File Provider domain form.
  public init(providerDomainIdentifier: String) throws {
    try self.init(validating: Self.prefix + providerDomainIdentifier)
  }
}

/// The identifier of a Dropbox namespace (the numeric string in `root_info`).
public struct NamespaceIdentifier: ValidatedStringWrapper {
  static let kind = IdentifierKind.namespaceIdentifier
  public let rawValue: String

  public init(validating rawValue: String) throws {
    guard !rawValue.isEmpty, rawValue.allSatisfy(\.isNumber) else {
      throw IdentifierValidationFailure(kind: Self.kind, rawValue: rawValue)
    }
    self.rawValue = rawValue
  }
}

/// The revision of a Dropbox file (a lowercase hexadecimal string).
public struct FileRevision: ValidatedStringWrapper {
  static let kind = IdentifierKind.fileRevision
  public let rawValue: String

  public init(validating rawValue: String) throws {
    guard !rawValue.isEmpty, rawValue.allSatisfy(\.isHexDigit), rawValue == rawValue.lowercased()
    else {
      throw IdentifierValidationFailure(kind: Self.kind, rawValue: rawValue)
    }
    self.rawValue = rawValue
  }
}

/// The identifier of an in-progress Dropbox upload session.
struct UploadSessionIdentifier: ValidatedStringWrapper {
  static let kind = IdentifierKind.uploadSessionIdentifier
  let rawValue: String

  init(validating rawValue: String) throws {
    guard !rawValue.isEmpty else {
      throw IdentifierValidationFailure(kind: Self.kind, rawValue: rawValue)
    }
    self.rawValue = rawValue
  }
}

/// An opaque Dropbox delta cursor from `files/list_folder`, marking a position
/// in an account's change feed.
public struct DeltaCursor: ValidatedStringWrapper {
  static let kind = IdentifierKind.deltaCursor
  public let rawValue: String

  public init(validating rawValue: String) throws {
    guard !rawValue.isEmpty else {
      throw IdentifierValidationFailure(kind: Self.kind, rawValue: rawValue)
    }
    self.rawValue = rawValue
  }
}
