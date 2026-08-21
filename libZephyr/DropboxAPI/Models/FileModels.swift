import Foundation
import os

/**
 Metadata for one entry in a Dropbox folder listing or change feed.

 Mirrors the API's `Metadata` union: a file, a folder, or a deletion tombstone.
 */
public enum ItemMetadata: Sendable, Equatable {
  case file(FileMetadata)

  case folder(FolderMetadata)

  case deleted(DeletedMetadata)

  /// The entry's name (the final path component).
  public var name: String {
    switch self {
      case .file(let metadata): metadata.name
      case .folder(let metadata): metadata.name
      case .deleted(let metadata): metadata.name
    }
  }

  /// The entry's cased display path, absent only for items in unmounted shares.
  public var pathDisplay: DropboxPath? {
    switch self {
      case .file(let metadata): metadata.pathDisplay
      case .folder(let metadata): metadata.pathDisplay
      case .deleted(let metadata): metadata.pathDisplay
    }
  }
}

extension ItemMetadata: Decodable {
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let tag = try container.decode(String.self, forKey: .tag)
    guard let recognized = try Self(tag: tag, from: decoder) else {
      throw DecodingError.dataCorruptedError(
        forKey: .tag,
        in: container,
        debugDescription: "Unknown metadata tag “\(tag)”."
      )
    }
    self = recognized
  }

  /// Decodes the variant a `.tag` names, or `nil` when the tag names a variant
  /// this client does not know.
  fileprivate init?(tag: String, from decoder: any Decoder) throws {
    switch tag {
      case "file": self = .file(try FileMetadata(from: decoder))
      case "folder": self = .folder(try FolderMetadata(from: decoder))
      case "deleted": self = .deleted(try DeletedMetadata(from: decoder))
      default: return nil
    }
  }

  private enum CodingKeys: String, CodingKey {
    case tag = ".tag"
  }
}

/**
 One listing entry, tolerating `Metadata` variants that postdate this client.

 Dropbox can add a variant at any time and a page is decoded in one shot, so a
 strict decode would fail the whole page — stalling the initial index and the
 delta feed alike on an entry that re-listing can only hit again. Decoding each
 entry through this wrapper confines an unrecognized variant to ``item`` being
 `nil`.
 */
struct RecognizedItemMetadata: Sendable, Equatable, Decodable {
  /// The decoded entry, or `nil` when its `.tag` names a variant this client
  /// does not know.
  let item: ItemMetadata?

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let tag = try container.decode(String.self, forKey: .tag)
    item = try ItemMetadata(tag: tag, from: decoder)
    if item == nil {
      ZephyrLog.engine.warning(
        "Skipping a listing entry of unrecognized kind “\(tag, privacy: .public)”."
      )
    }
  }

  private enum CodingKeys: String, CodingKey {
    case tag = ".tag"
  }
}

/// Metadata for a Dropbox file.
public struct FileMetadata: Sendable, Equatable, Decodable {
  public let id: DropboxFileIdentifier

  public let name: String

  public let pathLower: NormalizedDropboxPath?

  public let pathDisplay: DropboxPath?

  /// The modification time claimed by the uploading client. Not trustworthy.
  public let clientModified: Date

  /// The time the server recorded this revision.
  public let serverModified: Date

  public let rev: FileRevision

  public let size: UInt64

  /// The link target when this file is a symlink; `nil` for regular files.
  public let symlinkTarget: String?

  /// Whether the file lives inside a shared folder.
  public let isShared: Bool

  /// The account that last changed the file, reported only for shared files.
  public let modifiedBy: AccountIdentifier?

  /// `false` for export-only cloud documents that cannot be downloaded.
  public let isDownloadable: Bool

  /// Absent only for non-downloadable files.
  public let contentHash: ContentHash?

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(DropboxFileIdentifier.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    pathLower = try container.decodeIfPresent(NormalizedDropboxPath.self, forKey: .pathLower)
    pathDisplay = try container.decodeIfPresent(DropboxPath.self, forKey: .pathDisplay)
    clientModified = try container.decode(Date.self, forKey: .clientModified)
    serverModified = try container.decode(Date.self, forKey: .serverModified)
    rev = try container.decode(FileRevision.self, forKey: .rev)
    size = try container.decode(UInt64.self, forKey: .size)
    symlinkTarget = try container.decodeIfPresent(SymlinkInfo.self, forKey: .symlinkInfo)?.target
    let sharingInfo = try container.decodeIfPresent(SharingInfo.self, forKey: .sharingInfo)
    isShared = sharingInfo != nil
    modifiedBy = sharingInfo?.modifiedBy
    isDownloadable = try container.decodeIfPresent(Bool.self, forKey: .isDownloadable) ?? true
    contentHash = try container.decodeIfPresent(ContentHash.self, forKey: .contentHash)
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, rev, size

    case pathLower = "path_lower"

    case pathDisplay = "path_display"

    case clientModified = "client_modified"

    case serverModified = "server_modified"

    case symlinkInfo = "symlink_info"

    case sharingInfo = "sharing_info"

    case isDownloadable = "is_downloadable"

    case contentHash = "content_hash"
  }

  private struct SymlinkInfo: Decodable {
    let target: String
  }

  private struct SharingInfo: Decodable {
    let modifiedBy: AccountIdentifier?

    private enum CodingKeys: String, CodingKey {
      case modifiedBy = "modified_by"
    }
  }
}

/// Metadata for a Dropbox folder.
public struct FolderMetadata: Sendable, Equatable, Decodable {
  public let id: DropboxFileIdentifier

  public let name: String

  public let pathLower: NormalizedDropboxPath?

  public let pathDisplay: DropboxPath?

  /// Whether the folder is shared or lives inside a shared folder.
  public let isShared: Bool

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(DropboxFileIdentifier.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    pathLower = try container.decodeIfPresent(NormalizedDropboxPath.self, forKey: .pathLower)
    pathDisplay = try container.decodeIfPresent(DropboxPath.self, forKey: .pathDisplay)
    isShared = container.contains(.sharingInfo) || container.contains(.sharedFolderID)
  }

  private enum CodingKeys: String, CodingKey {
    case id, name

    case pathLower = "path_lower"

    case pathDisplay = "path_display"

    case sharingInfo = "sharing_info"

    case sharedFolderID = "shared_folder_id"
  }
}

/// A deletion tombstone from a folder listing or change feed. Carries only a
/// path — the deleted item's identifier must be recovered from the sync index.
public struct DeletedMetadata: Sendable, Equatable, Decodable {
  public let name: String

  public let pathLower: NormalizedDropboxPath?

  public let pathDisplay: DropboxPath?

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    name = try container.decode(String.self, forKey: .name)
    pathLower = try container.decodeIfPresent(NormalizedDropboxPath.self, forKey: .pathLower)
    pathDisplay = try container.decodeIfPresent(DropboxPath.self, forKey: .pathDisplay)
  }

  private enum CodingKeys: String, CodingKey {
    case name

    case pathLower = "path_lower"

    case pathDisplay = "path_display"
  }
}

/// One page of a folder listing or change feed from `files/list_folder`.
public struct ListFolderPage: Sendable, Equatable, Decodable {
  public let entries: [ItemMetadata]

  public let cursor: DeltaCursor

  public let hasMore: Bool

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    entries = try container.decode([RecognizedItemMetadata].self, forKey: .entries)
      .compactMap(\.item)
    cursor = try container.decode(DeltaCursor.self, forKey: .cursor)
    hasMore = try container.decode(Bool.self, forKey: .hasMore)
  }

  private enum CodingKeys: String, CodingKey {
    case entries, cursor

    case hasMore = "has_more"
  }
}

/// The result of a `files/list_folder/longpoll` call.
public struct LongpollResult: Sendable, Equatable, Decodable {
  /// Whether changes are waiting to be fetched with `list_folder/continue`.
  public let changes: Bool

  /// A server-requested pause before the next longpoll, when present.
  public let backoff: Duration?

  public init(changes: Bool, backoff: Duration?) {
    self.changes = changes
    self.backoff = backoff
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    changes = try container.decode(Bool.self, forKey: .changes)
    backoff = try container.decodeIfPresent(UInt64.self, forKey: .backoff).map { .seconds($0) }
  }

  private enum CodingKeys: String, CodingKey {
    case changes, backoff
  }
}

/**
 How an upload commits its file, mirroring the API's `WriteMode` union.

 ``update(_:)`` with the last-known revision is the lost-update guard: combined
 with `autorename`, the server creates a conflicted copy instead of overwriting
 a revision the client has never seen.
 */
public enum WriteMode: Sendable, Equatable {
  /// Add a new file; with `autorename`, collisions get a numbered suffix.
  case add

  /// Replace the file only if its current revision matches; with `autorename`,
  /// mismatches produce a conflicted copy.
  case update(FileRevision)

  /// Replace whatever is at the path unconditionally. Use sparingly.
  case overwrite
}
