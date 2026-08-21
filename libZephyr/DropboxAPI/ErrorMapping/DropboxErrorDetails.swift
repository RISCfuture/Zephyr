import Foundation

/**
 The decoded shape of a Dropbox API error response.

 Dropbox reports route errors as arbitrarily nested tagged unions. Rather than
 mirroring every route's union types, Zephyr extracts the chain of `.tag`
 discriminators (for example `["path", "conflict", "file"]`) plus any scalar
 payload fields seen along the way (`retry_after`, `required_scope`,
 `correct_offset`, …). ``DropboxErrorMapper`` matches on those.
 */
struct DropboxErrorDetails: Sendable {
  /// The human-readable `error_summary` from the envelope, when present.
  let summary: String?
  /// The chain of union tags from outermost to innermost.
  let tagPath: [String]
  /// Scalar payload fields collected from every visited union level.
  let fields: [String: DropboxErrorScalar]

  /**
   Parses an error response body.

   Returns `nil` when the body is not a JSON object — some proxies and 5xx
   responses return HTML or plain text.
   */
  static func parse(body: Data) -> Self? {
    guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
      return nil
    }
    var tagPath: [String] = []
    var fields: [String: DropboxErrorScalar] = [:]
    if let error = root["error"] as? [String: Any] {
      walk(error, tagPath: &tagPath, fields: &fields)
    } else {
      walk(root, tagPath: &tagPath, fields: &fields)
    }
    return Self(
      summary: root["error_summary"] as? String,
      tagPath: tagPath,
      fields: fields
    )
  }

  private static func walk(
    _ union: [String: Any],
    tagPath: inout [String],
    fields: inout [String: DropboxErrorScalar]
  ) {
    for (key, value) in union {
      switch value {
        case let string as String where key != ".tag":
          fields[key] = .string(string)
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
          fields[key] = .number(number.uint64Value)
        default:
          break
      }
    }
    guard let tag = union[".tag"] as? String else {
      if let reason = union["reason"] as? [String: Any] {
        walk(reason, tagPath: &tagPath, fields: &fields)
      }
      return
    }
    tagPath.append(tag)
    if let nested = union[tag] as? [String: Any] {
      walk(nested, tagPath: &tagPath, fields: &fields)
    } else if let reason = union["reason"] as? [String: Any] {
      walk(reason, tagPath: &tagPath, fields: &fields)
    }
  }

  /// Whether any level of the union carries this exact tag. Tags compare whole,
  /// so `shared_link_not_found` does not answer a query for `not_found`.
  func contains(_ tag: String) -> Bool { tagPath.contains(tag) }

  /// The tag immediately after `tag` in the chain, when present.
  func tag(following tag: String) -> String? {
    guard let index = tagPath.firstIndex(of: tag), tagPath.index(after: index) < tagPath.endIndex
    else {
      return nil
    }
    return tagPath[tagPath.index(after: index)]
  }
}

/// A scalar payload value carried by an error union.
enum DropboxErrorScalar: Sendable, Equatable {
  case string(String)
  case number(UInt64)

  var stringValue: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  var numberValue: UInt64? {
    if case .number(let value) = self { return value }
    return nil
  }
}
