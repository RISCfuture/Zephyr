public import CoreGraphics
public import Foundation
import os

/// Which revisions `files/list_revisions` groups together.
private enum RevisionsMode: String, Encodable {
  /// The revisions of whatever occupies the path now.
  case path

  /// The revisions of one file, across the paths it has occupied.
  case id

  /// The mode that reports the fullest history for an addressed item: a
  /// path can only be followed as a path, but an item named by its
  /// identifier — or by one of its revisions — can be followed as itself.
  init(following specifier: PathSpecifier) {
    switch specifier {
      case .path, .namespace: self = .path
      case .id, .revision: self = .id
    }
  }
}

extension DropboxClient {
  /**
   Fetches metadata for a file or folder.

   - Returns: `nil` when nothing exists at the path (a `not_found` route error).
   */
  public func metadata(
    for specifier: PathSpecifier,
    includeDeleted: Bool = false
  ) async throws -> ItemMetadata? {
    struct Argument: Encodable {
      let path: String
      let includeDeleted: Bool

      enum CodingKeys: String, CodingKey {
        case path
        case includeDeleted = "include_deleted"
      }
    }
    do {
      let recognized: RecognizedItemMetadata = try await rpc(
        DropboxRoute(host: .api, namespace: "files", name: "get_metadata"),
        argument: Argument(path: specifier.wireValue, includeDeleted: includeDeleted),
        path: specifier.wireValue
      )
      return recognized.item
    } catch ItemSyncFailure.notFound {
      return nil
    }
  }

  /**
   Lists the stored revisions of a file, most recent first.

   How far back the history reaches depends on how the file is addressed: an
   identifier or a revision follows the file itself through the renames and
   moves it survived, while a path follows the path, so a rename ends the
   history it can report.
   */
  public func revisions(
    of specifier: PathSpecifier,
    limit: UInt = 10
  ) async throws -> [FileMetadata] {
    struct Argument: Encodable {
      let path: String
      let mode: RevisionsMode
      let limit: UInt
    }
    struct Result: Decodable {
      let entries: [FileMetadata]
    }
    let result: Result = try await rpc(
      DropboxRoute(host: .api, namespace: "files", name: "list_revisions"),
      argument: Argument(
        path: specifier.wireValue,
        mode: RevisionsMode(following: specifier),
        limit: limit
      ),
      path: specifier.wireValue
    )
    return result.entries
  }

  /// Restores a file to an earlier revision, creating a new head revision.
  public func restore(_ path: DropboxPath, to revision: FileRevision) async throws -> FileMetadata {
    struct Argument: Encodable {
      let path: String
      let rev: String
    }
    return try await rpc(
      DropboxRoute(host: .api, namespace: "files", name: "restore"),
      argument: Argument(path: path.rawValue, rev: revision.rawValue),
      path: path.rawValue
    )
  }

  /// Creates a folder.
  public func createFolder(at path: DropboxPath, autorename: Bool = false) async throws
    -> FolderMetadata
  {
    struct Argument: Encodable {
      let path: String
      let autorename: Bool
    }
    struct Result: Decodable {
      let metadata: FolderMetadata
    }
    let result: Result = try await rpc(
      DropboxRoute(host: .api, namespace: "files", name: "create_folder_v2"),
      argument: Argument(path: path.rawValue, autorename: autorename),
      path: path.rawValue
    )
    return result.metadata
  }

  /**
   Deletes a file or folder.

   - Parameter specifier: The file or folder to delete, by path or by ID.
   - Parameter parentRevision: For files, the last-known revision; the server
     rejects the deletion if the file has changed since (the lost-update
     guard). Folders cannot be revision-guarded.
   */
  public func delete(
    _ specifier: PathSpecifier,
    parentRevision: FileRevision? = nil
  ) async throws -> ItemMetadata {
    struct Argument: Encodable {
      let path: String
      let parentRev: String?

      enum CodingKeys: String, CodingKey {
        case path
        case parentRev = "parent_rev"
      }
    }
    struct Result: Decodable {
      let metadata: ItemMetadata
    }
    let result: Result = try await rpc(
      DropboxRoute(host: .api, namespace: "files", name: "delete_v2"),
      argument: Argument(path: specifier.wireValue, parentRev: parentRevision?.rawValue),
      path: specifier.wireValue
    )
    return result.metadata
  }

  /// Moves or renames a file or folder server-side (no content transfer).
  public func move(
    from source: PathSpecifier,
    to destination: DropboxPath,
    autorename: Bool = false
  ) async throws -> ItemMetadata {
    struct Argument: Encodable {
      let fromPath: String
      let toPath: String
      let autorename: Bool
      let allowSharedFolder = true
      let allowOwnershipTransfer = true

      enum CodingKeys: String, CodingKey {
        case fromPath = "from_path"
        case toPath = "to_path"
        case autorename
        case allowSharedFolder = "allow_shared_folder"
        case allowOwnershipTransfer = "allow_ownership_transfer"
      }
    }
    struct Result: Decodable {
      let metadata: ItemMetadata
    }
    let result: Result = try await rpc(
      DropboxRoute(host: .api, namespace: "files", name: "move_v2"),
      argument: Argument(
        fromPath: source.wireValue,
        toPath: destination.rawValue,
        autorename: autorename
      ),
      path: destination.rawValue
    )
    return result.metadata
  }

  /// Downloads a file's content to `destination`, returning the served
  /// revision's metadata. Content verification is the caller's job.
  public func downloadContent(
    of specifier: PathSpecifier,
    to destination: URL
  ) async throws -> FileMetadata {
    struct Argument: Encodable {
      let path: String
    }
    return try await download(
      DropboxRoute(host: .content, namespace: "files", name: "download", style: .download),
      argument: Argument(path: specifier.wireValue),
      to: destination,
      path: specifier.wireValue
    )
  }
}

/// The sizes Dropbox renders a thumbnail at. Dropbox picks from this fixed
/// set; a request names a bucket rather than a pixel count.
public enum ThumbnailSize: String, Sendable, Encodable, CaseIterable {
  case w32h32
  case w64h64
  case w128h128
  case w256h256
  case w480h320
  case w640h480
  case w960h640
  case w1024h768
  case w2048h1536

  /// The bucket's own dimensions, in pixels.
  private var pixels: CGSize {
    switch self {
      case .w32h32: CGSize(width: 32, height: 32)
      case .w64h64: CGSize(width: 64, height: 64)
      case .w128h128: CGSize(width: 128, height: 128)
      case .w256h256: CGSize(width: 256, height: 256)
      case .w480h320: CGSize(width: 480, height: 320)
      case .w640h480: CGSize(width: 640, height: 480)
      case .w960h640: CGSize(width: 960, height: 640)
      case .w1024h768: CGSize(width: 1024, height: 768)
      case .w2048h1536: CGSize(width: 2048, height: 1536)
    }
  }

  /**
   The smallest bucket covering `size` in both axes, or the largest Dropbox
   renders when `size` outgrows every one of them.

   Asking for the nearest bucket *at or above* what was requested is what
   keeps a thumbnail from arriving already too small to draw: the system
   scales down cleanly and scales up visibly.
   */
  public static func covering(_ size: CGSize) -> Self {
    allCases.first { $0.pixels.width >= size.width && $0.pixels.height >= size.height }
      ?? .w2048h1536
  }
}

extension ThumbnailSize: Comparable {
  /// Ordered by how much Dropbox renders, which its ladder ascends by width.
  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.pixels.width < rhs.pixels.width
  }
}

/// What Dropbox had to say about one file in a thumbnail batch.
public enum ThumbnailEntry: Sendable, Equatable {
  /// The rendered image, in the format the request asked for.
  case rendered(Data)

  /// Dropbox rendered nothing: an extension it does not convert, an image it
  /// could not read, a source over its size ceiling, or a revision it could
  /// not look up. All of them mean the same thing to a caller — draw
  /// something else — so none of them is worth telling apart.
  case unavailable
}

extension DropboxClient {
  /// How many files `files/get_thumbnail_batch` renders in one call.
  public static let thumbnailBatchLimit = 25

  /**
   Renders thumbnails for up to ``thumbnailBatchLimit`` files, in the order
   they were asked for.

   Dropbox renders only `jpg`, `jpeg`, `png`, `tiff`, `tif`, `gif`, `webp`,
   `ppm`, and `bmp`, and nothing whose source is over 20 MB. Callers are
   expected to have ruled the rest out locally — every file sent here that
   Dropbox declines is a round trip spent to be told what a filename already
   said.

   A file Dropbox declines comes back as ``ThumbnailEntry/unavailable``
   rather than failing the batch, so one unreadable image cannot cost a
   folder its thumbnails.
   */
  public func thumbnails(
    for specifiers: [PathSpecifier],
    size: ThumbnailSize
  ) async throws -> [ThumbnailEntry] {
    guard !specifiers.isEmpty else { return [] }
    struct Entry: Encodable {
      let path: String
      let format = "jpeg"
      let size: ThumbnailSize
      // Fit the requested size *or its transpose*, so a portrait photo asked
      // for at 480×320 comes back filling 320×480 rather than shrunk into a
      // landscape box.
      let mode = "bestfit"
    }
    struct Argument: Encodable {
      let entries: [Entry]
    }
    struct Result: Decodable {
      let entries: [ThumbnailEntry]
    }
    let route = DropboxRoute(host: .content, namespace: "files", name: "get_thumbnail_batch")
    let result: Result = try await rpc(
      route,
      argument: Argument(
        entries: specifiers.map { Entry(path: $0.wireValue, size: size) }
      ),
      pacingResponse: true
    )
    guard result.entries.count == specifiers.count else {
      throw WireFormatFailure.malformedResponse(
        route: route.identifier,
        detail: String(
          localized: """
            \(specifiers.count, format: .number) thumbnails were requested and \
            \(result.entries.count, format: .number) were returned
            """,
          bundle: #bundle
        )
      )
    }
    return result.entries
  }
}

extension ThumbnailEntry: Decodable {
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let tag = try container.decode(String.self, forKey: .tag)
    guard tag == "success" else {
      // Every failure tag, and every tag a later Dropbox invents, says the
      // same thing: there is no image here.
      ZephyrLog.transport.debug("Dropbox rendered no thumbnail (\(tag, privacy: .public)).")
      self = .unavailable
      return
    }
    let encoded = try container.decode(String.self, forKey: .thumbnail)
    guard let data = Data(base64Encoded: encoded) else {
      ZephyrLog.transport.warning("Discarding a thumbnail whose payload was not base64.")
      self = .unavailable
      return
    }
    self = .rendered(data)
  }

  private enum CodingKeys: String, CodingKey {
    case tag = ".tag"
    case thumbnail
  }
}
