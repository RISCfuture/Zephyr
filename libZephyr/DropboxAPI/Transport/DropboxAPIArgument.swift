import Foundation
import os

/**
 Encodes route arguments for the `Dropbox-API-Arg` HTTP header.

 Content-style Dropbox routes (upload, download) pass their JSON arguments in
 this header rather than in the request body. HTTP headers must be ASCII, so
 every character outside the printable ASCII range is escaped as a `\uXXXX`
 JSON escape — one escape per UTF-16 code unit, so astral-plane characters
 become surrogate pairs, exactly as Dropbox documents.
 */
enum DropboxAPIArgumentEncoder {
  /// The Unicode scalar values allowed to appear unescaped in the header:
  /// printable ASCII, space through tilde.
  private static let unescapedScalarValues: ClosedRange<UInt32> = 0x20...0x7E

  /// The number of hex digits in a `\uXXXX` escape.
  private static let escapeDigitCount = 4

  /**
   Encodes a route argument into a `Dropbox-API-Arg` header value: JSON with
   sorted keys, every character outside `0x20...0x7E` escaped as `\uXXXX`.

   - Parameter argument: The route's argument value.
   - Returns: An ASCII-only header value.
   - Throws: ``WireFormatFailure/headerEncoding(detail:)`` if the argument
     cannot be encoded as JSON.
   */
  static func headerValue(for argument: some Encodable) throws -> String {
    asciiEscaped(try encodeJSON(argument))
  }

  private static func encodeJSON(_ argument: some Encodable) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    encoder.dateEncodingStrategy = .iso8601
    let data: Data
    do {
      data = try encoder.encode(argument)
    } catch {
      ZephyrLog.transport.error(
        "Couldn’t encode a route argument: \(String(describing: error), privacy: .private)"
      )
      throw WireFormatFailure.headerEncoding(
        detail: String(localized: "it couldn’t be written as JSON", bundle: #bundle)
      )
    }
    guard let json = String(data: data, encoding: .utf8) else {
      throw WireFormatFailure.headerEncoding(
        detail: String(localized: "the encoded JSON wasn’t valid UTF-8", bundle: #bundle)
      )
    }
    return json
  }

  private static func asciiEscaped(_ json: String) -> String {
    json.unicodeScalars
      .map { scalar in
        unescapedScalarValues.contains(scalar.value)
          ? String(Character(scalar))
          : escapeSequence(for: scalar)
      }
      .joined()
  }

  private static func escapeSequence(for scalar: Unicode.Scalar) -> String {
    utf16CodeUnits(of: scalar)
      .map { codeUnit in
        let hex = String(codeUnit, radix: 16, uppercase: true)
        let padding = String(repeating: "0", count: escapeDigitCount - hex.count)
        return "\\u\(padding)\(hex)"
      }
      .joined()
  }

  private static func utf16CodeUnits(of scalar: Unicode.Scalar) -> [UInt16] {
    if UTF16.width(scalar) == 1 {
      [UInt16(scalar.value)]
    } else {
      [UTF16.leadSurrogate(scalar), UTF16.trailSurrogate(scalar)]
    }
  }
}
