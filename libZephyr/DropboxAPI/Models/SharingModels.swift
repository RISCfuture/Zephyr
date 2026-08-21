import Foundation

/// What a shared link lets its audience do.
public enum LinkAccessLevel: String, Sendable, Equatable, Decodable {
  case viewer
  case editor
  case other

  /// The value a request sends, or `nil` for ``other``, which only ever comes
  /// back from the server.
  var requestValue: String? { self == .other ? nil : rawValue }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: TagKey.self)
    self = Self(rawValue: try container.decode(String.self, forKey: .tag)) ?? .other
  }
}

/// Who can use a shared link.
public enum LinkAudience: String, Sendable, Equatable, Decodable {
  case `public`
  case team
  case noOne = "no_one"
  case other

  /// The value a request sends, or `nil` for ``other``, which only ever comes
  /// back from the server.
  var requestValue: String? { self == .other ? nil : rawValue }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: TagKey.self)
    self = Self(rawValue: try container.decode(String.self, forKey: .tag)) ?? .other
  }
}

/// The effective permissions of a shared link.
public struct LinkPermissions: Sendable, Equatable, Decodable {
  /// Whether this account may take the link down.
  public let canRevoke: Bool
  /// Whether following the link offers the file for download. `true` when
  /// Dropbox omits the field.
  public let allowDownload: Bool
  /// Who can use the link, after the folder and team policies that narrow it.
  public let effectiveAudience: LinkAudience?
  /// What that audience may do with what the link opens.
  public let linkAccessLevel: LinkAccessLevel?
  /// Whether a password stands in front of the link. `false` when Dropbox
  /// omits the field.
  public let requirePassword: Bool

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    canRevoke = try container.decode(Bool.self, forKey: .canRevoke)
    allowDownload = try container.decodeIfPresent(Bool.self, forKey: .allowDownload) ?? true
    effectiveAudience = try container.decodeIfPresent(LinkAudience.self, forKey: .effectiveAudience)
    linkAccessLevel = try container.decodeIfPresent(LinkAccessLevel.self, forKey: .linkAccessLevel)
    requirePassword = try container.decodeIfPresent(Bool.self, forKey: .requirePassword) ?? false
  }

  private enum CodingKeys: String, CodingKey {
    case canRevoke = "can_revoke"
    case allowDownload = "allow_download"
    case effectiveAudience = "effective_audience"
    case linkAccessLevel = "link_access_level"
    case requirePassword = "require_password"
  }
}

/// A shared link to a Dropbox file or folder.
public struct SharedLinkMetadata: Sendable, Equatable, Decodable {
  public let url: URL
  public let name: String
  public let pathLower: NormalizedDropboxPath?
  public let expires: Date?
  public let permissions: LinkPermissions

  private enum CodingKeys: String, CodingKey {
    case url, name, expires
    case pathLower = "path_lower"
    case permissions = "link_permissions"
  }
}

/// One page of shared links from `sharing/list_shared_links`.
public struct ListSharedLinksResult: Sendable, Equatable, Decodable {
  public let links: [SharedLinkMetadata]
  public let hasMore: Bool
  public let cursor: String?

  private enum CodingKeys: String, CodingKey {
    case links
    case hasMore = "has_more"
    case cursor
  }
}

/// A shared folder, from `sharing/share_folder`.
public struct SharedFolderMetadata: Sendable, Equatable, Decodable {
  /// The identifier the sharing routes address this folder by.
  public let sharedFolderID: String

  public let name: String

  public let pathLower: NormalizedDropboxPath?

  /// Whether the folder is a team folder rather than a member-created share.
  public let isTeamFolder: Bool

  private enum CodingKeys: String, CodingKey {
    case name
    case sharedFolderID = "shared_folder_id"
    case pathLower = "path_lower"
    case isTeamFolder = "is_team_folder"
  }
}

/**
 The outcome of `sharing/share_folder`: sharing either completed inline or was
 handed to a background job.

 Dropbox decides which; a folder large enough to need an asynchronous share
 returns ``inProgress(jobID:)`` even when the caller did not ask for one.
 */
public enum ShareFolderLaunch: Sendable, Equatable {
  case complete(SharedFolderMetadata)

  case inProgress(jobID: String)

  /// The shared folder, or `nil` while a background job is still sharing it.
  public var sharedFolder: SharedFolderMetadata? {
    guard case .complete(let metadata) = self else { return nil }
    return metadata
  }
}

extension ShareFolderLaunch: Decodable {
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let tag = try container.decode(String.self, forKey: .tag)
    switch tag {
      case "complete":
        self = .complete(try SharedFolderMetadata(from: decoder))
      case "async_job_id":
        self = .inProgress(jobID: try container.decode(String.self, forKey: .asyncJobID))
      default:
        throw DecodingError.dataCorruptedError(
          forKey: .tag,
          in: container,
          debugDescription: "Unknown share folder launch tag “\(tag)”."
        )
    }
  }

  private enum CodingKeys: String, CodingKey {
    case tag = ".tag"
    case asyncJobID = "async_job_id"
  }
}

/// The `.tag` discriminator key used by Dropbox unions.
struct TagKey: CodingKey {
  static let tag = Self()

  var stringValue: String { ".tag" }
  var intValue: Int? { nil }

  init() {}

  init?(stringValue: String) {
    guard stringValue == ".tag" else { return nil }
  }

  init?(intValue _: Int) {
    nil
  }
}
