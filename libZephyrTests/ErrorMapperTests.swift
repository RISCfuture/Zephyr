import Foundation
import Testing

@testable import libZephyr

@Suite
struct DropboxErrorMapperTests {
  private let route = DropboxRoute(host: .api, namespace: "files", name: "test")
  private let path = "/reports/q3.pdf"

  private func mapped(_ status: Int, _ json: String, headers: [AnyHashable: Any] = [:]) -> any Error
  {
    DropboxErrorMapper.error(
      route: route,
      status: status,
      body: Data(json.utf8),
      headers: headers,
      path: path
    )
  }

  @Test
  func `not found lookup maps to not found at request path`() throws {
    let json = """
      {
        "error_summary": "path/not_found/..",
        "error": {".tag": "path", "path": {".tag": "not_found"}}
      }
      """
    let failure = try #require(mapped(409, json) as? ItemSyncFailure)
    guard case .notFound(let failurePath) = failure else {
      Issue.record("Expected notFound, got \(failure)")
      return
    }
    #expect(failurePath == path)
  }

  @Test
  func `upload write conflicts map to file and folder conflicts`() throws {
    func conflictJSON(_ kind: String) -> String {
      """
      {
        "error_summary": "path/conflict/\(kind)/..",
        "error": {
          ".tag": "path",
          "path": {
            "reason": {".tag": "conflict", "conflict": {".tag": "\(kind)"}},
            "upload_session_id": "AAAAAAHmUxIAAAAAAAB2lQ"
          }
        }
      }
      """
    }

    let fileFailure = try #require(mapped(409, conflictJSON("file")) as? ItemSyncFailure)
    guard case .fileConflict(let filePath) = fileFailure else {
      Issue.record("Expected fileConflict, got \(fileFailure)")
      return
    }
    #expect(filePath == path)

    let folderFailure = try #require(mapped(409, conflictJSON("folder")) as? ItemSyncFailure)
    guard case .folderConflict(let folderPath) = folderFailure else {
      Issue.record("Expected folderConflict, got \(folderFailure)")
      return
    }
    #expect(folderPath == path)
  }

  @Test
  func `insufficient space maps to insufficient space`() throws {
    let json = """
      {
        "error_summary": "path/insufficient_space/..",
        "error": {".tag": "path", "path": {".tag": "insufficient_space"}}
      }
      """
    let failure = try #require(mapped(409, json) as? ItemSyncFailure)
    guard case .insufficientSpace(let failurePath) = failure else {
      Issue.record("Expected insufficientSpace, got \(failure)")
      return
    }
    #expect(failurePath == path)
  }

  @Test(arguments: ["malformed_path", "disallowed_name"])
  func `relocation path problem maps to invalid path`(tag: String) throws {
    let json = """
      {
        "error_summary": "to/\(tag)/..",
        "error": {".tag": "to", "to": {".tag": "\(tag)"}}
      }
      """
    let failure = try #require(mapped(409, json) as? ItemSyncFailure)
    guard case .invalidPath(let failurePath, _) = failure else {
      Issue.record("Expected invalidPath for \(tag), got \(failure)")
      return
    }
    #expect(failurePath == path)
  }

  @Test
  func `cursor reset maps to engine cursor reset`() throws {
    let json = """
      {"error_summary": "reset/..", "error": {".tag": "reset"}}
      """
    let failure = try #require(mapped(409, json) as? EngineFailure)
    guard case .cursorReset = failure else {
      Issue.record("Expected cursorReset, got \(failure)")
      return
    }
  }

  @Test
  func `incorrect offset maps to signal carrying correct offset`() throws {
    let flat = """
      {
        "error_summary": "incorrect_offset/..",
        "error": {".tag": "incorrect_offset", "correct_offset": 86016}
      }
      """
    let flatSignal = try #require(mapped(409, flat) as? IncorrectOffsetSignal)
    #expect(flatSignal.correctOffset == 86016)

    let nested = """
      {
        "error_summary": "lookup_failed/incorrect_offset/..",
        "error": {
          ".tag": "lookup_failed",
          "lookup_failed": {".tag": "incorrect_offset", "correct_offset": 123}
        }
      }
      """
    let nestedSignal = try #require(mapped(409, nested) as? IncorrectOffsetSignal)
    #expect(nestedSignal.correctOffset == 123)
  }

  @Test
  func `content hash mismatch maps to data corruption`() throws {
    let json = """
      {"error_summary": "content_hash_mismatch/..", "error": {".tag": "content_hash_mismatch"}}
      """
    let failure = try #require(mapped(409, json) as? ItemSyncFailure)
    guard case .dataCorruption(let failurePath) = failure else {
      Issue.record("Expected dataCorruption, got \(failure)")
      return
    }
    #expect(failurePath == path)
  }

  @Test
  func `too many write operations maps to rate limited signal`() throws {
    let json = """
      {
        "error_summary": "path/too_many_write_operations/..",
        "error": {".tag": "path", "path": {".tag": "too_many_write_operations"}}
      }
      """
    let signal = try #require(mapped(409, json) as? RateLimitedSignal)
    #expect(signal.retryAfter == nil)
  }

  @Test
  func `expired access token maps to token expired`() throws {
    let json = """
      {"error_summary": "expired_access_token/..", "error": {".tag": "expired_access_token"}}
      """
    let failure = try #require(mapped(401, json) as? AuthenticationFailure)
    guard case .tokenExpired = failure else {
      Issue.record("Expected tokenExpired, got \(failure)")
      return
    }
  }

  @Test
  func `missing scope maps to missing scope with required scope`() throws {
    let json = """
      {
        "error_summary": "missing_scope/..",
        "error": {".tag": "missing_scope", "required_scope": "files.content.read"}
      }
      """
    let failure = try #require(mapped(401, json) as? AuthenticationFailure)
    guard case .missingScope(let scope) = failure else {
      Issue.record("Expected missingScope, got \(failure)")
      return
    }
    #expect(scope == "files.content.read")
  }

  @Test
  func `invalid access token maps to token revoked`() throws {
    let json = """
      {"error_summary": "invalid_access_token/..", "error": {".tag": "invalid_access_token"}}
      """
    let failure = try #require(mapped(401, json) as? AuthenticationFailure)
    guard case .tokenRevoked = failure else {
      Issue.record("Expected tokenRevoked, got \(failure)")
      return
    }
  }

  @Test
  func `unprocessable entity maps to path root changed`() throws {
    let json = """
      {"error_summary": "invalid_root/..", "error": {".tag": "invalid_root"}}
      """
    let failure = try #require(mapped(422, json) as? EngineFailure)
    guard case .pathRootChanged(let newRoot) = failure else {
      Issue.record("Expected pathRootChanged, got \(failure)")
      return
    }
    #expect(newRoot == nil)
  }

  /// `PathRootError.invalid_root` carries the account's current `RootInfo`, and
  /// that namespace is the only thing that gets the account unwedged short of
  /// relinking — so it has to survive the walk down to the nested union.
  @Test
  func `path root change carries the namespace Dropbox returned`() throws {
    func invalidRootJSON(_ rootInfo: String) -> String {
      """
      {
        "error_summary": "invalid_root/..",
        "error": {".tag": "invalid_root", "invalid_root": \(rootInfo)}
      }
      """
    }

    let personal = invalidRootJSON(
      #"{".tag": "user", "root_namespace_id": "7", "home_namespace_id": "7"}"#
    )
    let personalRoot = try NamespaceIdentifier(validating: "7")
    #expect(mapped(422, personal) as? EngineFailure == .pathRootChanged(newRoot: personalRoot))

    // A team root nests one level deeper and carries fields the walker also
    // collects, so it exercises the descent rather than a flat union.
    let team = invalidRootJSON(
      #"""
      {".tag": "team", "root_namespace_id": "1234", "home_namespace_id": "3235",
      "home_path": "/Bees"}
      """#
    )
    let teamRoot = try NamespaceIdentifier(validating: "1234")
    #expect(mapped(422, team) as? EngineFailure == .pathRootChanged(newRoot: teamRoot))
  }

  @Test
  func `path root permission refusal is not a path root change`() throws {
    let json = """
      {"error_summary": "no_permission/..", "error": {".tag": "no_permission"}}
      """
    #expect(
      mapped(422, json) as? ItemSyncFailure
        == .insufficientPermissions(path: path, detail: "no_permission/..")
    )
  }

  /// A 400 is Dropbox refusing the arguments, not Zephyr misreading a response;
  /// `unexpectedStatus` would tell the user the client has a protocol bug.
  @Test
  func `bad request is reported as a rejected request`() throws {
    let body = #"Error in call to API function "files/list_folder": bad "path" parameter"#
    let failure = try #require(mapped(400, body) as? WireFormatFailure)
    #expect(failure == .badRequest(route: "files/test", detail: body))
  }

  /// Tags compare whole, so every `shared_link_*` tag needs its own arm; before
  /// they existed a revoked link fell through to an opaque `DropboxRouteError`.
  @Test(arguments: [
    ("shared_link_not_found", ItemSyncFailure.notFound(path: "/reports/q3.pdf")),
    (
      "shared_link_access_denied",
      ItemSyncFailure.insufficientPermissions(
        path: "/reports/q3.pdf",
        detail: "shared_link_access_denied/.."
      )
    ),
    (
      "shared_link_malformed",
      ItemSyncFailure.invalidPath(path: "/reports/q3.pdf", reason: "malformed shared link")
    ),
    ("unsupported_link_type", ItemSyncFailure.unsupportedFile(path: "/reports/q3.pdf"))
  ])
  func sharedLinkTagsAreMatchedWhole(tag: String, expected: ItemSyncFailure) throws {
    let json = """
      {"error_summary": "\(tag)/..", "error": {".tag": "\(tag)"}}
      """
    #expect(mapped(409, json) as? ItemSyncFailure == expected)
  }

  /// A Basic account asking for a link password is told what its plan can't do,
  /// rather than being handed the raw union.
  @Test
  func `link settings refusal names the plan limit`() throws {
    let json = """
      {
        "error_summary": "settings_error/not_authorized/..",
        "error": {
          ".tag": "settings_error",
          "settings_error": {".tag": "not_authorized"}
        }
      }
      """
    #expect(mapped(409, json) as? ItemSyncFailure == .linkSettingsUnavailable(path: path))

    let invalid = """
      {
        "error_summary": "settings_error/invalid_settings/..",
        "error": {
          ".tag": "settings_error",
          "settings_error": {".tag": "invalid_settings"}
        }
      }
      """
    #expect(mapped(409, invalid) as? ItemSyncFailure == .linkSettingsInvalid(path: path))
  }

  @Test(arguments: [
    ("email_not_verified", ItemSyncFailure.accountEmailUnverified(path: "/reports/q3.pdf")),
    ("shared_link_already_exists", ItemSyncFailure.sharedLinkExists(path: "/reports/q3.pdf")),
    ("team_folder", ItemSyncFailure.teamFolder(path: "/reports/q3.pdf")),
    ("operation_suppressed", ItemSyncFailure.operationSuppressed(path: "/reports/q3.pdf")),
    ("invalid_revision", ItemSyncFailure.notFound(path: "/reports/q3.pdf")),
    (
      "locked",
      ItemSyncFailure.insufficientPermissions(path: "/reports/q3.pdf", detail: "locked/..")
    )
  ])
  func residualTagsMapToNamedFailures(tag: String, expected: ItemSyncFailure) throws {
    let json = """
      {"error_summary": "\(tag)/..", "error": {".tag": "\(tag)"}}
      """
    #expect(mapped(409, json) as? ItemSyncFailure == expected)
  }

  /// A session that is already closed, or not yet closed, cannot be continued;
  /// the transfer restarts, which is the same arm an expired session takes.
  @Test(arguments: ["closed", "not_closed"])
  func `unusable upload session restarts the transfer`(tag: String) throws {
    let json = """
      {
        "error_summary": "lookup_failed/\(tag)/..",
        "error": {".tag": "lookup_failed", "lookup_failed": {".tag": "\(tag)"}}
      }
      """
    let failure = try #require(mapped(409, json) as? ItemSyncFailure)
    guard case .serverError(let failurePath, _) = failure else {
      Issue.record("Expected serverError for \(tag), got \(failure)")
      return
    }
    #expect(failurePath == path)
  }

  @Test
  func `rate limit prefers retry after header`() throws {
    let json = """
      {
        "error_summary": "too_many_requests/..",
        "error": {"reason": {".tag": "too_many_requests"}}
      }
      """
    let signal = try #require(
      mapped(429, json, headers: ["Retry-After": "30"]) as? RateLimitedSignal
    )
    #expect(signal.retryAfter == .seconds(30))
  }

  @Test
  func `rate limit falls back to retry after in body`() throws {
    let json = """
      {
        "error_summary": "too_many_requests/..",
        "error": {"reason": {".tag": "too_many_requests"}, "retry_after": 60}
      }
      """
    let signal = try #require(mapped(429, json) as? RateLimitedSignal)
    #expect(signal.retryAfter == .seconds(60))
  }

  @Test
  func `server error maps to server error signal with request ID`() throws {
    let headers: [AnyHashable: Any] = ["x-dropbox-request-id": "3f0aa1b2c3d4"]
    let signal = try #require(
      mapped(500, "<html>Internal Server Error</html>", headers: headers) as? ServerErrorSignal
    )
    #expect(signal.status == 500)
    #expect(signal.requestID == "3f0aa1b2c3d4")
  }

  @Test
  func `unknown tag chain maps to Dropbox route error`() throws {
    let json = """
      {
        "error_summary": "properties_error/template_not_found/..",
        "error": {
          ".tag": "properties_error",
          "properties_error": {".tag": "template_not_found"}
        }
      }
      """
    let error = try #require(mapped(409, json) as? DropboxRouteError)
    #expect(error.route == "files/test")
    #expect(error.tagPath == ["properties_error", "template_not_found"])
    #expect(error.summary == "properties_error/template_not_found/..")
  }

  @Test
  func `unparseable 409 body maps to malformed response`() throws {
    let failure = try #require(mapped(409, "<html>Conflict</html>") as? WireFormatFailure)
    guard case .malformedResponse(let failedRoute, _) = failure else {
      Issue.record("Expected malformedResponse, got \(failure)")
      return
    }
    #expect(failedRoute == "files/test")
  }

  @Test
  func `header lookups are case insensitive`() throws {
    // HTTP/2 lowercases header names on the wire; the raw dictionary is case-sensitive.
    let rateLimited = try #require(
      mapped(429, "{}", headers: ["retry-after": "7"]) as? RateLimitedSignal
    )
    #expect(rateLimited.retryAfter == .seconds(7))

    let serverError = try #require(
      mapped(500, "{}", headers: ["X-Dropbox-Request-Id": "req99"]) as? ServerErrorSignal
    )
    #expect(serverError.requestID == "req99")
  }

  @Test
  func `upload session lookup not found is not path not found`() throws {
    let json = """
      {
        "error_summary": "lookup_failed/not_found/..",
        "error": {
          ".tag": "lookup_failed",
          "lookup_failed": {".tag": "not_found"}
        }
      }
      """
    let failure = try #require(mapped(409, json) as? ItemSyncFailure)
    guard case .serverError = failure else {
      Issue.record("Expected serverError (session expired), got \(failure)")
      return
    }
  }
}

@Suite
struct OSErrorMappingTests {
  private let path = "/reports/q3.pdf"

  /// The status list shows a failure's localized text, so a raw file-system
  /// error has to acquire a taxonomy case before it is recorded.
  @Test
  func `file system errors are restated in the taxonomy`() {
    let posix = POSIXError(.ENOSPC)
    #expect(
      OSErrorMapping.classified(posix, path: path) as? ItemSyncFailure
        == .insufficientSpace(path: path)
    )

    // Foundation's file APIs wrap the errno rather than reporting it directly.
    let wrapped = NSError(
      domain: NSCocoaErrorDomain,
      code: NSFileWriteUnknownError,
      userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))]
    )
    #expect(
      OSErrorMapping.classified(wrapped, path: path) as? ItemSyncFailure
        == .insufficientPermissions(path: path, detail: nil)
    )

    // A Cocoa file error with no errno underneath still names itself.
    let noSuchFile = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)
    #expect(
      OSErrorMapping.classified(noSuchFile, path: path) as? ItemSyncFailure
        == .notFound(path: path)
    )
  }

  /// Only file-system errors are restated: a Dropbox or engine failure already
  /// describes itself, and rewriting it as a file failure would lose the reason.
  @Test
  func `errors from elsewhere are passed through`() {
    let engine = EngineFailure.connection(detail: "offline")
    #expect(OSErrorMapping.classified(engine, path: path) as? EngineFailure == engine)

    let urlError = URLError(.timedOut)
    #expect((OSErrorMapping.classified(urlError, path: path) as? URLError)?.code == .timedOut)
  }
}

@Suite
struct SyncErrorTierTests {
  /// A cancellation and a held lock stop the engine without saying anything is
  /// wrong with the account, so neither belongs in a fatal status row.
  @Test
  func `only lasting conditions halt sync`() {
    #expect(EngineFailure.connection(detail: nil).haltsSync)
    #expect(EngineFailure.pathRootChanged(newRoot: nil).haltsSync)
    #expect(!EngineFailure.cancelled.haltsSync)
    #expect(!EngineFailure.busy.haltsSync)
    #expect(AuthenticationFailure.tokenRevoked.haltsSync)
  }

  /// A lost connection is the one halting condition that comes back on its
  /// own, so it must never be reported the way a revoked token is.
  @Test
  func `only lost connections resolve without the user`() {
    #expect(EngineFailure.connection(detail: nil).resolvesWithoutUser)
    #expect(!EngineFailure.notLinked.resolvesWithoutUser)
    #expect(!EngineFailure.cursorReset.resolvesWithoutUser)
    #expect(!EngineFailure.pathRootChanged(newRoot: nil).resolvesWithoutUser)
    #expect(!EngineFailure.cacheDirectory(detail: nil).resolvesWithoutUser)
    #expect(!AuthenticationFailure.tokenRevoked.resolvesWithoutUser)
  }
}
