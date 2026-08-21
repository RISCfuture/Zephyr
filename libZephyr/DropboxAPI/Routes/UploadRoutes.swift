import Foundation

/// The commit parameters shared by `files/upload` and `upload_session/finish`.
struct UploadCommitInfo: Encodable, Sendable {
  let path: String

  /// The destination in normalized form, which keys the checkpoint a chunked
  /// upload leaves behind. Absent from ``CodingKeys``, so it never reaches
  /// the wire — Dropbox is sent the cased path.
  let normalizedPath: NormalizedDropboxPath

  let mode: WireEncodedWriteMode
  let autorename: Bool
  let clientModified: Date

  init(path: DropboxPath, mode: WriteMode, autorename: Bool, clientModified: Date) {
    self.path = path.rawValue
    normalizedPath = path.normalized
    self.mode = WireEncodedWriteMode(mode)
    self.autorename = autorename
    self.clientModified = clientModified
  }

  enum CodingKeys: String, CodingKey {
    case path, mode, autorename
    case clientModified = "client_modified"
  }
}

/// `WriteMode` in its wire form.
struct WireEncodedWriteMode: Encodable, Sendable {
  private let tag: String
  private let update: String?

  init(_ mode: WriteMode) {
    switch mode {
      case .add:
        tag = "add"
        update = nil
      case .update(let revision):
        tag = "update"
        update = revision.rawValue
      case .overwrite:
        tag = "overwrite"
        update = nil
    }
  }

  private enum CodingKeys: String, CodingKey {
    case tag = ".tag"
    case update
  }
}

extension DropboxClient {
  /// Uploads a file that fits in a single request.
  func uploadSmall(
    commit: UploadCommitInfo,
    contentHash: ContentHash,
    body: Data
  ) async throws -> FileMetadata {
    struct Argument: Encodable {
      let path: String
      let mode: WireEncodedWriteMode
      let autorename: Bool
      let clientModified: Date
      let contentHash: String

      enum CodingKeys: String, CodingKey {
        case path, mode, autorename
        case clientModified = "client_modified"
        case contentHash = "content_hash"
      }
    }
    return try await upload(
      DropboxRoute(host: .content, namespace: "files", name: "upload", style: .upload),
      argument: Argument(
        path: commit.path,
        mode: commit.mode,
        autorename: commit.autorename,
        clientModified: commit.clientModified,
        contentHash: contentHash.rawValue
      ),
      body: body,
      path: commit.path
    )
  }

  /// Opens an upload session with its first chunk.
  func uploadSessionStart(body: Data, contentHash: ContentHash) async throws
    -> UploadSessionIdentifier
  {
    struct Argument: Encodable {
      let close = false
      let contentHash: String

      enum CodingKeys: String, CodingKey {
        case close
        case contentHash = "content_hash"
      }
    }
    struct Result: Decodable {
      let sessionID: UploadSessionIdentifier

      enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
      }
    }
    let result: Result = try await upload(
      DropboxRoute(
        host: .content,
        namespace: "files",
        name: "upload_session/start",
        style: .upload
      ),
      argument: Argument(contentHash: contentHash.rawValue),
      body: body
    )
    return result.sessionID
  }

  /// Appends a chunk to an upload session at the given offset.
  func uploadSessionAppend(
    session: UploadSessionIdentifier,
    offset: UInt64,
    body: Data,
    contentHash: ContentHash?,
    close: Bool = false
  ) async throws {
    struct Argument: Encodable {
      let cursor: Cursor
      let close: Bool
      let contentHash: String?

      enum CodingKeys: String, CodingKey {
        case cursor, close
        case contentHash = "content_hash"
      }
    }
    struct Cursor: Encodable {
      let sessionID: String
      let offset: UInt64

      enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case offset
      }
    }
    try await uploadVoid(
      DropboxRoute(
        host: .content,
        namespace: "files",
        name: "upload_session/append_v2",
        style: .upload
      ),
      argument: Argument(
        cursor: Cursor(sessionID: session.rawValue, offset: offset),
        close: close,
        contentHash: contentHash?.rawValue
      ),
      body: body
    )
  }

  /// Commits an upload session with its final chunk.
  func uploadSessionFinish(
    session: UploadSessionIdentifier,
    offset: UInt64,
    commit: UploadCommitInfo,
    body: Data,
    contentHash: ContentHash?
  ) async throws -> FileMetadata {
    struct Argument: Encodable {
      let cursor: Cursor
      let commit: UploadCommitInfo
      let contentHash: String?

      enum CodingKeys: String, CodingKey {
        case cursor, commit
        case contentHash = "content_hash"
      }
    }
    struct Cursor: Encodable {
      let sessionID: String
      let offset: UInt64

      enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case offset
      }
    }
    return try await upload(
      DropboxRoute(
        host: .content,
        namespace: "files",
        name: "upload_session/finish",
        style: .upload
      ),
      argument: Argument(
        cursor: Cursor(sessionID: session.rawValue, offset: offset),
        commit: commit,
        contentHash: contentHash?.rawValue
      ),
      body: body,
      path: commit.path
    )
  }
}
