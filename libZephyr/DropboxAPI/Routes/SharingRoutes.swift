import Foundation

/// The options for creating a shared link.
public struct SharedLinkSettings: Sendable, Equatable {
  /// An access password; requires a paid Dropbox plan.
  public let password: String?

  /// An expiry time; requires a paid Dropbox plan.
  public let expires: Date?

  /// Who can use the link; `nil` leaves Dropbox's default for the item.
  public let audience: LinkAudience?

  /// What the link's audience can do; `nil` leaves Dropbox's default.
  public let accessLevel: LinkAccessLevel?

  /// Whether the audience may download the item as well as view it in a
  /// browser; `nil` leaves Dropbox's default.
  public let allowDownload: Bool?

  public init(
    password: String? = nil,
    expires: Date? = nil,
    audience: LinkAudience? = nil,
    accessLevel: LinkAccessLevel? = nil,
    allowDownload: Bool? = nil
  ) {
    self.password = password
    self.expires = expires
    self.audience = audience
    self.accessLevel = accessLevel
    self.allowDownload = allowDownload
  }
}

/// The wire form of ``SharedLinkSettings``; omitted fields keep Dropbox's defaults.
struct SharedLinkSettingsArgument: Encodable {
  let requirePassword: Bool?
  let linkPassword: String?
  let expires: Date?
  let audience: String?
  let access: String?
  let allowDownload: Bool?

  init(_ settings: SharedLinkSettings) {
    requirePassword = settings.password != nil ? true : nil
    linkPassword = settings.password
    expires = settings.expires
    audience = settings.audience?.requestValue
    access = settings.accessLevel?.requestValue
    allowDownload = settings.allowDownload
  }

  enum CodingKeys: String, CodingKey {
    case expires, audience, access
    case requirePassword = "require_password"
    case linkPassword = "link_password"
    case allowDownload = "allow_download"
  }
}

extension DropboxClient {
  /// Creates a shared link for a file or folder.
  public func createSharedLink(
    for path: DropboxPath,
    settings: SharedLinkSettings = SharedLinkSettings()
  ) async throws -> SharedLinkMetadata {
    struct Argument: Encodable {
      let path: String
      let settings: SharedLinkSettingsArgument
    }
    return try await rpc(
      DropboxRoute(host: .api, namespace: "sharing", name: "create_shared_link_with_settings"),
      argument: Argument(path: path.rawValue, settings: SharedLinkSettingsArgument(settings)),
      path: path.rawValue
    )
  }

  /// Revokes a shared link.
  public func revokeSharedLink(_ url: URL) async throws {
    struct Argument: Encodable {
      let url: String
    }
    try await rpcVoid(
      DropboxRoute(host: .api, namespace: "sharing", name: "revoke_shared_link"),
      argument: Argument(url: url.absoluteString)
    )
  }

  /// Lists shared links, optionally restricted to one path.
  public func listSharedLinks(
    for path: DropboxPath? = nil,
    cursor: String? = nil
  ) async throws -> ListSharedLinksResult {
    struct Argument: Encodable {
      let path: String?
      let cursor: String?
    }
    return try await rpc(
      DropboxRoute(host: .api, namespace: "sharing", name: "list_shared_links"),
      argument: Argument(path: path?.rawValue, cursor: cursor),
      path: path?.rawValue
    )
  }

  /**
   Turns a folder into a shared folder, which a folder created at the root of a
   team space must become before anyone else can reach it.

   - Parameters:
     - specifier: The folder to share. Only ``PathSpecifier/path(_:)`` and
       ``PathSpecifier/id(_:)`` address a folder; a revision does not.
     - inheritAccess: Whether the folder inherits its parent's members. `false`
       gives it its own membership, which is what a team-space root folder needs.
   - Returns: The shared folder, or the identifier of the job still sharing it.
   */
  public func shareFolder(
    _ specifier: PathSpecifier,
    inheritAccess: Bool = true
  ) async throws -> ShareFolderLaunch {
    struct Argument: Encodable {
      let path: String
      let accessInheritance: String
      let forceAsync = false

      enum CodingKeys: String, CodingKey {
        case path
        case accessInheritance = "access_inheritance"
        case forceAsync = "force_async"
      }
    }
    return try await rpc(
      DropboxRoute(host: .api, namespace: "sharing", name: "share_folder"),
      argument: Argument(
        path: specifier.wireValue,
        accessInheritance: inheritAccess ? "inherit" : "no_inherit"
      ),
      path: specifier.wireValue
    )
  }
}
