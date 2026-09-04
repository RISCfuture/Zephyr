public import Foundation
import os

/// The subscription tier of a Dropbox account.
public enum AccountType: String, Sendable, Equatable, Decodable {
  case basic
  case pro
  case business
  /// A tier introduced after this client was written.
  case other

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self = Self(rawValue: try container.decode(String.self, forKey: .tag)) ?? .other
  }

  private enum CodingKeys: String, CodingKey {
    case tag = ".tag"
  }
}

/// A Dropbox Business team.
public struct Team: Sendable, Equatable, Decodable {
  public let id: String
  public let name: String

  public init(id: String, name: String) {
    self.id = id
    self.name = name
  }
}

/**
 The namespace an account's path-based API calls resolve against.

 Team members have a team space root distinct from their personal home
 namespace; all path-based calls must send the root in the
 `Dropbox-API-Path-Root` header.
 */
public enum RootInfo: Sendable, Equatable {
  case user(rootNamespaceID: NamespaceIdentifier, homeNamespaceID: NamespaceIdentifier)
  case team(
    rootNamespaceID: NamespaceIdentifier,
    homeNamespaceID: NamespaceIdentifier,
    homePath: String
  )

  /// The namespace to send as the path root.
  public var rootNamespaceID: NamespaceIdentifier {
    switch self {
      case .user(let rootNamespaceID, _), .team(let rootNamespaceID, _, _): rootNamespaceID
    }
  }
}

extension RootInfo: Decodable {
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      tag: try container.decode(String.self, forKey: .tag),
      rootNamespaceID: try container.decode(NamespaceIdentifier.self, forKey: .rootNamespaceID),
      homeNamespaceID: try container.decode(NamespaceIdentifier.self, forKey: .homeNamespaceID),
      homePath: try container.decodeIfPresent(String.self, forKey: .homePath)
    )
  }

  /**
   Builds a root from the wire fields every `RootInfo` variant carries.

   A root kind this client does not know becomes a personal root: the path root
   header only ever needs the root namespace, so degrading here keeps linking
   working, where throwing would fail `users/get_current_account` outright.
   */
  private init(
    tag: String,
    rootNamespaceID: NamespaceIdentifier,
    homeNamespaceID: NamespaceIdentifier,
    homePath: String?
  ) {
    if tag == "team", let homePath {
      self = .team(
        rootNamespaceID: rootNamespaceID,
        homeNamespaceID: homeNamespaceID,
        homePath: homePath
      )
    } else {
      if tag != "user" {
        ZephyrLog.auth.warning(
          "Treating unrecognized account root kind “\(tag, privacy: .public)” as personal."
        )
      }
      self = .user(rootNamespaceID: rootNamespaceID, homeNamespaceID: homeNamespaceID)
    }
  }

  private enum CodingKeys: String, CodingKey {
    case tag = ".tag"
    case rootNamespaceID = "root_namespace_id"
    case homeNamespaceID = "home_namespace_id"
    case homePath = "home_path"
  }
}

/// The `name` object every account record carries. Dropbox spells a person's
/// name five ways; only the form meant for display is read.
private struct AccountName: Decodable {
  let displayName: String

  private enum CodingKeys: String, CodingKey {
    case displayName = "display_name"
  }
}

/**
 The publicly visible details of a Dropbox account, from `users/get_account`
 and `users/get_account_batch`.

 Answers "who changed this file?": the identifier a shared file's
 `sharing_info.modified_by` carries names an account, and this is what that
 account is called.
 */
struct BasicAccount: Sendable, Equatable, Decodable {
  let accountID: AccountIdentifier

  let displayName: String

  let email: String

  let profilePhotoURL: URL?

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    accountID = try container.decode(AccountIdentifier.self, forKey: .accountID)
    displayName = try container.decode(AccountName.self, forKey: .name).displayName
    email = try container.decode(String.self, forKey: .email)
    profilePhotoURL = try container.decodeIfPresent(URL.self, forKey: .profilePhotoURL)
  }

  private enum CodingKeys: String, CodingKey {
    case name
    case email
    case accountID = "account_id"
    case profilePhotoURL = "profile_photo_url"
  }
}

/// The full details of the linked Dropbox account, from `users/get_current_account`.
public struct FullAccount: Sendable, Equatable, Decodable {
  public let accountID: AccountIdentifier
  public let displayName: String
  public let email: String
  public let emailVerified: Bool
  public let profilePhotoURL: URL?
  public let disabled: Bool
  public let country: String?
  public let locale: String
  public let team: Team?
  public let teamMemberID: String?
  public let accountType: AccountType
  public let rootInfo: RootInfo

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    accountID = try container.decode(AccountIdentifier.self, forKey: .accountID)
    displayName = try container.decode(AccountName.self, forKey: .name).displayName
    email = try container.decode(String.self, forKey: .email)
    emailVerified = try container.decode(Bool.self, forKey: .emailVerified)
    profilePhotoURL = try container.decodeIfPresent(URL.self, forKey: .profilePhotoURL)
    disabled = try container.decode(Bool.self, forKey: .disabled)
    country = try container.decodeIfPresent(String.self, forKey: .country)
    locale = try container.decode(String.self, forKey: .locale)
    team = try container.decodeIfPresent(Team.self, forKey: .team)
    teamMemberID = try container.decodeIfPresent(String.self, forKey: .teamMemberID)
    accountType = try container.decode(AccountType.self, forKey: .accountType)
    rootInfo = try container.decode(RootInfo.self, forKey: .rootInfo)
  }

  private enum CodingKeys: String, CodingKey {
    case accountID = "account_id"
    case name
    case email
    case emailVerified = "email_verified"
    case profilePhotoURL = "profile_photo_url"
    case disabled
    case country
    case locale
    case team
    case teamMemberID = "team_member_id"
    case accountType = "account_type"
    case rootInfo = "root_info"
  }
}

/// The account's storage usage, from `users/get_space_usage`.
public struct SpaceUsage: Sendable, Equatable, Decodable {
  /// Bytes used by the account.
  public let used: UInt64
  /// Bytes allocated to the account; `nil` when the team's pool is effectively unlimited.
  public let allocated: UInt64?

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    used = try container.decode(UInt64.self, forKey: .used)
    let allocation = try container.nestedContainer(
      keyedBy: AllocationKeys.self,
      forKey: .allocation
    )
    switch try allocation.decode(String.self, forKey: .tag) {
      case "individual":
        allocated = try allocation.decode(UInt64.self, forKey: .allocated)
      case "team":
        // A zero per-member cap means the member draws on the whole team pool.
        let memberCap = try allocation.decode(UInt64.self, forKey: .userWithinTeamSpaceAllocated)
        allocated =
          memberCap == 0 ? try allocation.decode(UInt64.self, forKey: .allocated) : memberCap
      default:
        allocated = nil
    }
  }

  private enum CodingKeys: String, CodingKey {
    case used
    case allocation
  }

  private enum AllocationKeys: String, CodingKey {
    case tag = ".tag"
    case allocated
    case userWithinTeamSpaceAllocated = "user_within_team_space_allocated"
  }
}
