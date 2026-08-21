import Foundation

extension DropboxClient {
  /// The page size requested from folder listings; the server may return less.
  private static var listFolderLimit: UInt32 { 2000 }

  /**
   Whether listings report cloud documents — Google Docs and the like, which
   `is_downloadable: false` marks as export-only.

   They carry a revision, so nothing downstream can tell them apart from an
   ordinary file, and `files/download` refuses them with `unsupported_file`.
   Leaving them out of the listing keeps items that can never materialize out
   of the File Provider domain.
   */
  private static var includesNonDownloadableFiles: Bool { false }

  /// The longpoll wait; must be within the API's accepted 30–480 s range.
  private static var longpollTimeout: Duration { .seconds(40) }
  /// Extra socket-timeout margin on top of the longpoll wait — Dropbox adds
  /// up to 90 s of server-side jitter before responding.
  private static var longpollSocketMargin: Duration { .seconds(90) }

  /// Starts listing a folder, returning the first page.
  public func listFolder(
    _ path: DropboxPath,
    recursive: Bool = false,
    includeDeleted: Bool = false
  ) async throws -> ListFolderPage {
    struct Argument: Encodable {
      let path: String
      let recursive: Bool
      let includeDeleted: Bool
      let includeMountedFolders = true
      let includeNonDownloadableFiles = DropboxClient.includesNonDownloadableFiles
      let limit: UInt32

      enum CodingKeys: String, CodingKey {
        case path, recursive, limit
        case includeDeleted = "include_deleted"
        case includeMountedFolders = "include_mounted_folders"
        case includeNonDownloadableFiles = "include_non_downloadable_files"
      }
    }
    return try await rpc(
      DropboxRoute(host: .api, namespace: "files", name: "list_folder"),
      argument: Argument(
        path: path.rawValue,
        recursive: recursive,
        includeDeleted: includeDeleted,
        limit: Self.listFolderLimit
      ),
      path: path.rawValue
    )
  }

  /// Fetches the next page of a listing or the changes since a cursor.
  public func listFolderContinue(from cursor: DeltaCursor) async throws -> ListFolderPage {
    struct Argument: Encodable {
      let cursor: String
    }
    return try await rpc(
      DropboxRoute(host: .api, namespace: "files", name: "list_folder/continue"),
      argument: Argument(cursor: cursor.rawValue)
    )
  }

  /// Returns a cursor for the folder's current state without listing it.
  public func latestCursor(for path: DropboxPath, recursive: Bool = true) async throws
    -> DeltaCursor
  {
    struct Argument: Encodable {
      let path: String
      let recursive: Bool
      let includeDeleted = false, includeMountedFolders = true
      let includeNonDownloadableFiles = DropboxClient.includesNonDownloadableFiles

      enum CodingKeys: String, CodingKey {
        case path, recursive
        case includeDeleted = "include_deleted"
        case includeMountedFolders = "include_mounted_folders"
        case includeNonDownloadableFiles = "include_non_downloadable_files"
      }
    }
    struct Result: Decodable {
      let cursor: DeltaCursor
    }
    let result: Result = try await rpc(
      DropboxRoute(host: .api, namespace: "files", name: "list_folder/get_latest_cursor"),
      argument: Argument(path: path.rawValue, recursive: recursive),
      path: path.rawValue
    )
    return result.cursor
  }

  /**
   Waits for changes after a cursor, blocking until changes arrive or the
   longpoll times out. Unauthenticated by design — it needs only the cursor.
   */
  public func waitForChanges(after cursor: DeltaCursor) async throws -> LongpollResult {
    struct Argument: Encodable {
      let cursor: String
      let timeout: UInt64
    }
    return try await rpc(
      DropboxRoute(
        host: .notify,
        namespace: "files",
        name: "list_folder/longpoll",
        isAuthenticated: false,
        timeout: Self.longpollTimeout + Self.longpollSocketMargin
      ),
      argument: Argument(
        cursor: cursor.rawValue,
        timeout: UInt64(Self.longpollTimeout.components.seconds)
      )
    )
  }
}
