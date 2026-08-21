import Foundation

/**
 Maps Dropbox API error responses onto Zephyr's error taxonomy, mirroring
 Maestral's `dropbox_to_maestral_error`.

 Transient conditions (rate limiting, 5xx, incorrect upload offsets) map to
 internal signals the client's retry loop consumes; everything else maps to the
 public taxonomy.
 */
enum DropboxErrorMapper {
  /// Tags spread across the write, lookup, and sharing unions that all say the
  /// same thing: Dropbox will not let this account touch the item.
  private static let permissionDeniedTags = [
    "no_write_permission", "insufficient_permissions", "no_permission", "access_denied", "locked"
  ]

  /**
   Converts a non-success HTTP response into the matching error.

   - Parameters:
     - route: The route that produced the response.
     - status: The HTTP status code.
     - body: The response body.
     - headers: The response headers, consulted for `Retry-After` and the request ID.
     - path: The Dropbox path the call concerned, for error context.
   */
  static func error(
    route: DropboxRoute,
    status: Int,
    body: Data,
    headers: [AnyHashable: Any],
    path: String?
  ) -> any Error {
    let requestID = headerValue("x-dropbox-request-id", in: headers)
    let details = DropboxErrorDetails.parse(body: body)
    let contextPath = path ?? details?.fields["path"]?.stringValue ?? ""

    switch status {
      case 400:
        return WireFormatFailure.badRequest(
          route: route.identifier,
          detail: badRequestDetail(body: body, details: details)
        )
      case 401:
        return authenticationError(details: details)
      case 403:
        return ItemSyncFailure.insufficientPermissions(path: contextPath, detail: details?.summary)
      case 409:
        return routeError(route: route, details: details, path: contextPath)
      case 422:
        return pathRootError(details: details, path: contextPath)
      case 429:
        return RateLimitedSignal(retryAfter: retryAfter(headers: headers, details: details))
      case 500...:
        return ServerErrorSignal(status: status, requestID: requestID)
      default:
        return WireFormatFailure.unexpectedStatus(code: status, requestID: requestID)
    }
  }

  /// A 400 body is prose, not a tagged union — Dropbox explains which argument
  /// it could not accept, and that sentence is the only useful detail.
  private static func badRequestDetail(body: Data, details: DropboxErrorDetails?) -> String? {
    if let summary = details?.summary { return summary }
    let prose = String(bytes: body, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return prose?.isEmpty == false ? prose : nil
  }

  private static func authenticationError(details: DropboxErrorDetails?) -> any Error {
    guard let details else { return AuthenticationFailure.tokenRevoked }
    if details.contains("expired_access_token") {
      return AuthenticationFailure.tokenExpired
    }
    if details.contains("missing_scope") {
      return AuthenticationFailure.missingScope(
        details.fields["required_scope"]?.stringValue
          ?? String(localized: "unknown", bundle: #bundle)
      )
    }
    return AuthenticationFailure.tokenRevoked
  }

  /**
   Interprets a `Dropbox-API-Path-Root` rejection.

   Dropbox answers a stale path-root header with the account's *current* root
   info, so the namespace in the body is what the session must adopt; dropping
   it leaves every path-based call failing with no way back but relinking.
   */
  private static func pathRootError(details: DropboxErrorDetails?, path: String) -> any Error {
    guard let details else { return EngineFailure.pathRootChanged(newRoot: nil) }
    if details.contains("no_permission") {
      return ItemSyncFailure.insufficientPermissions(path: path, detail: details.summary)
    }
    return EngineFailure.pathRootChanged(newRoot: currentRootNamespace(in: details))
  }

  /// `PathRootError.invalid_root` carries a `RootInfo`, whose `root_namespace_id`
  /// the details walker collects one level below the `invalid_root` tag.
  private static func currentRootNamespace(
    in details: DropboxErrorDetails
  ) -> NamespaceIdentifier? {
    guard let raw = details.fields["root_namespace_id"]?.stringValue else { return nil }
    return try? NamespaceIdentifier(validating: raw)
  }

  /// Classifies a route's error union, consulting each family of tags in turn
  /// and falling back to a ``DropboxRouteError`` that preserves the raw chain.
  private static func routeError(
    route: DropboxRoute,
    details: DropboxErrorDetails?,
    path: String
  ) -> any Error {
    guard let details else {
      return WireFormatFailure.malformedResponse(
        route: route.identifier,
        detail: String(localized: "the error body couldn’t be parsed", bundle: #bundle)
      )
    }
    return sessionFailure(details: details)
      ?? transferFailure(details: details, path: path)
      ?? sharedLinkFailure(details: details, path: path)
      ?? pathFailure(details: details, path: path)
      ?? permissionFailure(details: details, path: path)
      ?? throttleSignal(details: details)
      ?? DropboxRouteError(
        route: route.identifier,
        summary: details.summary,
        tagPath: details.tagPath
      )
  }

  /// Conditions that concern the session — its delta cursor or its credential —
  /// rather than one item.
  private static func sessionFailure(details: DropboxErrorDetails) -> (any Error)? {
    if details.contains("reset") {
      return EngineFailure.cursorReset
    }
    if details.contains("invalid_access_token") || details.contains("invalid_select_user") {
      return AuthenticationFailure.tokenRevoked
    }
    return nil
  }

  /**
   Conditions raised by an in-flight transfer.

   These are checked before the path family because an upload session's own
   `not_found` — reached through `lookup_failed` — means the session expired,
   not that the file is missing.
   */
  private static func transferFailure(
    details: DropboxErrorDetails,
    path: String
  ) -> (any Error)? {
    if details.contains("incorrect_offset") {
      return IncorrectOffsetSignal(
        correctOffset: details.fields["correct_offset"]?.numberValue ?? 0
      )
    }
    if details.contains("content_hash_mismatch") {
      return ItemSyncFailure.dataCorruption(path: path)
    }
    let sessionUnusable =
      (details.contains("lookup_failed") && details.contains("not_found"))
      || details.contains("closed") || details.contains("not_closed")
    return sessionUnusable ? restartableUploadSession(path: path) : nil
  }

  /// An upload session that can no longer be appended to or finished. The
  /// transfer starts over, so the item is retried rather than abandoned.
  private static func restartableUploadSession(path: String) -> ItemSyncFailure {
    .serverError(
      path: path,
      detail: String(localized: "The upload session must be restarted.", bundle: #bundle)
    )
  }

  /**
   Conditions raised by the sharing routes.

   Every tag here is matched in full: ``DropboxErrorDetails/contains(_:)``
   compares whole tags, so `shared_link_not_found` never satisfies the
   `not_found` arm below.
   */
  private static func sharedLinkFailure(
    details: DropboxErrorDetails,
    path: String
  ) -> (any Error)? {
    if details.contains("shared_link_not_found") {
      return ItemSyncFailure.notFound(path: path)
    }
    if details.contains("shared_link_access_denied") {
      return ItemSyncFailure.insufficientPermissions(path: path, detail: details.summary)
    }
    if details.contains("shared_link_malformed") {
      return ItemSyncFailure.invalidPath(
        path: path,
        reason: String(localized: "malformed shared link", bundle: #bundle)
      )
    }
    if details.contains("unsupported_link_type") {
      return ItemSyncFailure.unsupportedFile(path: path)
    }
    if details.contains("shared_link_already_exists") {
      return ItemSyncFailure.sharedLinkExists(path: path)
    }
    if details.contains("email_not_verified") {
      return ItemSyncFailure.accountEmailUnverified(path: path)
    }
    if details.contains("settings_error") {
      return details.tag(following: "settings_error") == "invalid_settings"
        ? ItemSyncFailure.linkSettingsInvalid(path: path)
        : ItemSyncFailure.linkSettingsUnavailable(path: path)
    }
    return nil
  }

  /// Conditions naming the path the request addressed.
  private static func pathFailure(details: DropboxErrorDetails, path: String) -> (any Error)? {
    if details.contains("not_found") || details.contains("invalid_revision") {
      return ItemSyncFailure.notFound(path: path)
    }
    if details.contains("conflict") {
      return details.tag(following: "conflict") == "folder"
        ? ItemSyncFailure.folderConflict(path: path)
        : ItemSyncFailure.fileConflict(path: path)
    }
    if details.contains("malformed_path") {
      return ItemSyncFailure.invalidPath(
        path: path,
        reason: String(localized: "malformed path", bundle: #bundle)
      )
    }
    if details.contains("disallowed_name") {
      return ItemSyncFailure.invalidPath(
        path: path,
        reason: String(localized: "name not allowed by Dropbox", bundle: #bundle)
      )
    }
    if details.contains("insufficient_space") {
      return ItemSyncFailure.insufficientSpace(path: path)
    }
    if details.contains("not_file") {
      return ItemSyncFailure.isAFolder(path: path)
    }
    if details.contains("not_folder") {
      return ItemSyncFailure.notAFolder(path: path)
    }
    if details.contains("restricted_content") {
      return ItemSyncFailure.restrictedContent(path: path)
    }
    if details.contains("unsupported_file") || details.contains("unsupported_content_type") {
      return ItemSyncFailure.unsupportedFile(path: path)
    }
    if details.contains("payload_too_large") || details.contains("too_large") {
      return ItemSyncFailure.fileSizeExceeded(path: path)
    }
    return nil
  }

  /// Conditions where Dropbox holds the item back rather than rejecting it.
  private static func permissionFailure(
    details: DropboxErrorDetails,
    path: String
  ) -> (any Error)? {
    if details.contains("team_folder") {
      return ItemSyncFailure.teamFolder(path: path)
    }
    if details.contains("operation_suppressed") {
      return ItemSyncFailure.operationSuppressed(path: path)
    }
    guard permissionDeniedTags.contains(where: details.contains) else { return nil }
    return ItemSyncFailure.insufficientPermissions(path: path, detail: details.summary)
  }

  /// Conditions where the server asks the client to slow down.
  private static func throttleSignal(details: DropboxErrorDetails) -> RateLimitedSignal? {
    guard details.contains("too_many_write_operations") || details.contains("too_many_requests")
    else {
      return nil
    }
    return RateLimitedSignal(retryAfter: retryAfter(headers: [:], details: details))
  }

  private static func retryAfter(
    headers: [AnyHashable: Any],
    details: DropboxErrorDetails?
  ) -> Duration? {
    if let header = headerValue("Retry-After", in: headers), let seconds = UInt64(header) {
      return .seconds(seconds)
    }
    if let seconds = details?.fields["retry_after"]?.numberValue {
      return .seconds(seconds)
    }
    return nil
  }

  /// Looks up a header by name case-insensitively — `allHeaderFields` keys
  /// are case-sensitive on subscript, and HTTP/2 lowercases names on the wire.
  private static func headerValue(_ name: String, in headers: [AnyHashable: Any]) -> String? {
    let lowered = name.lowercased()
    for (key, value) in headers {
      guard let keyString = key as? String, keyString.lowercased() == lowered else { continue }
      return value as? String
    }
    return nil
  }
}
