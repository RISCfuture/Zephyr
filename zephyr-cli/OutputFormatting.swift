import Foundation

/// Column-aligned table output for humans, JSON output for scripts.
enum Output {
  /// The cell a table shows where a value does not exist.
  static let missing = "-"

  /**
   Whether the command may ask the user a question.

   Both ends of the conversation have to be a terminal: a prompt written into
   a pipe stalls the pipeline, and an answer read from one is whatever the
   upstream command happened to write.
   */
  static var isInteractive: Bool {
    isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1
  }

  /// Prints rows as left-aligned padded columns.
  static func table(_ rows: [[String]]) {
    guard let columnCount = rows.first?.count else { return }
    var widths = [Int](repeating: 0, count: columnCount)
    for row in rows {
      for (index, cell) in row.enumerated() {
        widths[index] = max(widths[index], cell.count)
      }
    }
    for row in rows {
      let line = row.enumerated()
        .map { index, cell in
          index == row.count - 1
            ? cell : cell.padding(toLength: widths[index], withPad: " ", startingAt: 0)
        }
        .joined(separator: "  ")
      print(line)
    }
  }

  /// Prints a value as deterministic JSON.
  static func json(_ value: some Encodable) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    // `JSONEncoder` emits UTF-8 by contract, so there is no lossy decode
    // here for the failable initializer to catch.
    // swiftlint:disable:next optional_data_string_conversion
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
  }

  /// Asks the user a question on the terminal, returning the trimmed answer.
  static func ask(_ question: String) -> String? {
    print(question, terminator: " ")
    return readLine(strippingNewline: true)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// A human-readable byte count.
  static func bytes(_ count: UInt64) -> String {
    Int64(clamping: count).formatted(.byteCount(style: .file))
  }

  /// A human-readable byte count, or ``missing`` when there is none.
  static func bytes(_ count: UInt64?) -> String {
    guard let count else { return missing }
    return bytes(count)
  }

  /// A compact date-and-time rendering.
  static func date(_ date: Date) -> String {
    date.formatted(date: .abbreviated, time: .shortened)
  }

  /// A compact date-and-time rendering, or ``missing`` when there is none.
  static func date(_ date: Date?) -> String {
    guard let date else { return missing }
    return self.date(date)
  }
}
