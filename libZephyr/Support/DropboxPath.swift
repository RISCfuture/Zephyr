import Foundation

/**
 A Dropbox path in display form, as accepted and returned by the Dropbox API.

 The account root is the empty string (never `"/"`); every other path starts with `"/"`
 and never ends with one. Casing is preserved — use ``NormalizedDropboxPath`` wherever
 paths are compared or used as keys, because Dropbox treats paths case-insensitively.
 */
public struct DropboxPath: Sendable, Hashable {
  /// The root of the Dropbox account.
  public static let root = Self()

  /// The path exactly as the Dropbox API represents it (`""` for the root).
  public let rawValue: String

  /// Whether this path is the account root.
  public var isRoot: Bool { rawValue.isEmpty }

  /// The final path component, or `""` for the root.
  public var basename: String {
    guard let lastSeparator = rawValue.lastIndex(of: "/") else { return "" }
    return String(rawValue[rawValue.index(after: lastSeparator)...])
  }

  /// The containing folder's path; the root is its own parent.
  public var parent: Self {
    guard let lastSeparator = rawValue.lastIndex(of: "/") else { return .root }
    return Self(validated: String(rawValue[..<lastSeparator]))
  }

  /// The case-insensitive, Unicode-normalized form used for comparisons and index keys.
  public var normalized: NormalizedDropboxPath { NormalizedDropboxPath(self) }

  /// The path as a person reads it, spelling the account root `"/"` rather than
  /// the empty string the API uses for it.
  public var displayPath: String { isRoot ? "/" : rawValue }

  /// The path's components, outermost first. The root has none.
  public var components: [String] { rawValue.split(separator: "/").map(String.init) }

  /// The path written the way the Finder writes one: the components divided by
  /// chevrons rather than run together on slashes.
  ///
  /// For showing a person where something lives, not for anything that has to be
  /// read back -- a path that will be copied, typed, logged, or handed to another
  /// tool wants ``displayPath``. Somewhere a view can be laid out rather than a
  /// string interpolated, ``PathBreadcrumb`` says the same thing and elides it
  /// far better. The root has no components and so reads empty; a caller that
  /// can land on the root names it itself.
  public var breadcrumb: String {
    components.joined(separator: " \u{203A} ")
  }

  private init() {
    rawValue = ""
  }

  private init(validated: String) {
    rawValue = validated
  }

  /**
   Creates a path after validating its form.

   - Parameter rawValue: `""` for the root, or a `/`-prefixed path without a trailing slash.
   - Throws: `PathValidationFailure` when the string is not a well-formed Dropbox path.
   */
  public init(validating rawValue: String) throws {
    if rawValue.isEmpty {
      self = .root
      return
    }
    guard rawValue.hasPrefix("/") else { throw PathValidationFailure.missingLeadingSlash(rawValue) }
    guard !rawValue.hasSuffix("/") else { throw PathValidationFailure.trailingSlash(rawValue) }
    guard !rawValue.contains("//") else { throw PathValidationFailure.emptyComponent(rawValue) }
    guard !rawValue.contains("\0") else { throw PathValidationFailure.containsNullByte }
    self.init(validated: rawValue)
  }

  /**
   Creates a path from something a person typed or a picker offered, rather
   than from something Dropbox said.

   ``init(validating:)`` is strict because a path from the API that is
   malformed means the client misunderstood something. A path from a person is
   different: `Documents`, `/Documents/`, and `/` are all clear enough, and
   refusing them would be pedantry. `/` and the empty string are the root,
   which strict validation rejects because the root's own form is `""`.

   - Parameter userTyped: The path as offered.
   - Throws: `PathValidationFailure` when leniency cannot rescue it.
   */
  public init(userTyped: String) throws {
    var path = userTyped
    if path == "/" || path.isEmpty {
      self = .root
      return
    }
    if !path.hasPrefix("/") { path = "/" + path }
    while path.count > 1, path.hasSuffix("/") { path.removeLast() }
    try self.init(validating: path)
  }

  /// Returns the path for a child of this path.
  public func appending(_ component: String) throws -> Self {
    try Self(validating: "\(rawValue)/\(component)")
  }
}

extension DropboxPath: Codable {
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    do {
      try self.init(validating: container.decode(String.self))
    } catch {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "\(error)")
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

extension DropboxPath: CustomStringConvertible {
  public var description: String { isRoot ? "(root)" : rawValue }
}

/**
 A Dropbox path in the canonical form Dropbox uses for comparison: Unicode NFC,
 lowercased. Matches the API's `path_lower` fields and Maestral's `normalize()`.
 */
public struct NormalizedDropboxPath: Sendable, Hashable {
  /// The root of the Dropbox account.
  public static let root = Self(.root)

  /// The normalized path string (`""` for the root).
  public let rawValue: String

  /// Whether this path is the account root.
  public var isRoot: Bool { rawValue.isEmpty }

  /// The containing folder's normalized path; the root is its own parent.
  public var parent: Self {
    guard let lastSeparator = rawValue.lastIndex(of: "/") else { return .root }
    return Self(normalized: String(rawValue[..<lastSeparator]))
  }

  /// Creates the normalized form of a display path.
  public init(_ path: DropboxPath) {
    self.init(normalized: Self.folded(path.rawValue))
  }

  /**
   Creates a normalized path from a string the Dropbox API already normalized
   (a `path_lower` value), validating its form.

   - Throws: `PathValidationFailure` when the string is not a well-formed Dropbox path.
   */
  public init(validating rawValue: String) throws {
    self.init(normalized: Self.folded(try DropboxPath(validating: rawValue).rawValue))
  }

  private init(normalized: String) {
    rawValue = normalized
  }

  /**
   The folding a path, a name, and a search term are all reduced to before any
   of them are compared: Unicode NFC, then lowercased.

   Dropbox compares paths this way, so a comparison made over folded strings is
   Dropbox's own rather than SQLite's ASCII-only `LIKE`. An accent survives the
   folding, and so still distinguishes two names.
   */
  public static func folded(_ text: String) -> String {
    text.precomposedStringWithCanonicalMapping.lowercased()
  }
}

extension NormalizedDropboxPath: Codable {
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    do {
      try self.init(validating: container.decode(String.self))
    } catch {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "\(error)")
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

extension NormalizedDropboxPath: CustomStringConvertible {
  public var description: String { isRoot ? "(root)" : rawValue }
}

/// A malformed Dropbox path string was rejected.
enum PathValidationFailure: WireError, Equatable {
  case missingLeadingSlash(String)
  case trailingSlash(String)
  case emptyComponent(String)
  case containsNullByte
}

extension PathValidationFailure: LocalizedError {
  public var errorDescription: String? {
    String(localized: "Invalid Dropbox path.", bundle: #bundle)
  }

  public var failureReason: String? {
    switch self {
      case .missingLeadingSlash(let path):
        String(localized: "The path “\(path)” does not start with a slash.", bundle: #bundle)
      case .trailingSlash(let path):
        String(localized: "The path “\(path)” ends with a slash.", bundle: #bundle)
      case .emptyComponent(let path):
        String(localized: "The path “\(path)” contains an empty component.", bundle: #bundle)
      case .containsNullByte:
        String(localized: "The path contains a null byte.", bundle: #bundle)
    }
  }
}
