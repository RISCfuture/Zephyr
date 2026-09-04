import Foundation
import Testing

@testable import libZephyr

@Suite
struct DropboxAPIArgTests {
  /// An argument as the client sends it: keys sorted, so the expectation can
  /// be written as one literal.
  private static func encoded(_ argument: some Encodable) throws -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = .sortedKeys
    return try #require(String(bytes: try encoder.encode(argument), encoding: .utf8))
  }

  @Test
  func `sorts keys and passes ASCII through`() throws {
    let argument = UploadArgument(path: "/test.txt", mode: "add")
    let header = try DropboxAPIArgumentEncoder.headerValue(for: argument)
    #expect(header == #"{"mode":"add","path":"\/test.txt"}"#)
  }

  @Test
  func `escapes latin supplement scalar`() throws {
    let header = try DropboxAPIArgumentEncoder.headerValue(for: LabeledArgument(label: "caf\u{E9}"))
    #expect(header == #"{"label":"caf\u00E9"}"#)
  }

  @Test
  func `escapes basic multilingual plane scalar`() throws {
    let header = try DropboxAPIArgumentEncoder.headerValue(for: LabeledArgument(label: "→"))
    #expect(header == #"{"label":"\u2192"}"#)
  }

  @Test
  func `escapes astral scalar as surrogate pair`() throws {
    let header = try DropboxAPIArgumentEncoder.headerValue(for: LabeledArgument(label: "𝔘"))
    #expect(header == #"{"label":"\uD835\uDD18"}"#)
  }

  @Test
  func `preserves combining sequences without normalizing`() throws {
    let header = try DropboxAPIArgumentEncoder.headerValue(for: LabeledArgument(label: "e\u{0301}"))
    #expect(header == #"{"label":"e\u0301"}"#)
  }

  @Test
  func `produces only ASCII`() throws {
    let header = try DropboxAPIArgumentEncoder.headerValue(
      for: LabeledArgument(label: "naïve → 𝔘nicode")
    )
    let isEntirelyASCII = header.allSatisfy(\.isASCII)
    #expect(isEntirelyASCII)
  }

  @Test
  func `a namespace specifier addresses the namespace root and paths within it`() throws {
    let namespaceID = try NamespaceIdentifier(validating: "7684224")
    let homework = try DropboxPath(validating: "/Homework")
    #expect(PathSpecifier.namespaceRoot(namespaceID).wireValue == "ns:7684224")
    #expect(
      PathSpecifier.namespace(namespaceID, path: homework).wireValue == "ns:7684224/Homework"
    )
  }

  @Test
  func `unset shared link settings are omitted so Dropbox's defaults stand`() throws {
    let json = try Self.encoded(SharedLinkSettingsArgument(SharedLinkSettings()))
    #expect(json == "{}")
  }

  @Test
  func `set shared link settings send bare tag strings`() throws {
    let json = try Self.encoded(
      SharedLinkSettingsArgument(
        SharedLinkSettings(
          password: "hunter2",
          audience: .public,
          accessLevel: .viewer,
          allowDownload: false
        )
      )
    )
    #expect(
      json == #"""
        {"access":"viewer","allow_download":false,"audience":"public","link_password":"hunter2","require_password":true}
        """#
    )
  }

  private struct UploadArgument: Encodable {
    let path: String
    let mode: String
  }

  private struct LabeledArgument: Encodable {
    let label: String
  }
}
