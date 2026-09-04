public import Foundation

/// The kind of namespace an account's path-based calls resolve against.
public enum AccountRootType: String, Sendable, Equatable, Codable {
  /// A personal Dropbox, whose root namespace is the member's home namespace.
  case personal

  /// A Dropbox Business team space, which contains the member's home folder.
  case team
}

/**
 The per-account configuration and cached account facts, stored as JSON in the
 account's directory. Everything here is either user-settable or refreshable
 from the API — the source of truth for sync state is the index database.

 ## Transfers are not configured here

 Two different reasons, and neither of them is per-account.

 Concurrency is the system's. Under the File Provider replicated model there is
 no local folder to walk and no queue of Zephyr's own: `fileproviderd` decides
 how many `fetchContents` and `createItem` calls are in flight and times each
 one. A parallelism cap inside the extension could only queue work the system
 had already scheduled, and would risk stalling a call the system is timing.

 Bandwidth is the Mac's. A cap exists because of the link this computer is on,
 and a link does not know which Dropbox is using it — so the caps live in
 ``BandwidthSettings``, once for the machine, and every account's transfers
 share them.
 */
public struct AccountConfiguration: Sendable, Equatable, Codable {
  public let accountID: AccountIdentifier

  public var email: String

  public var displayName: String

  /**
   The account's path-root namespace, sent as `Dropbox-API-Path-Root` on every
   path-based call.

   Dropbox invalidates it when the member joins or leaves a team, so it is
   re-resolved from `users/get_current_account` and written back through
   `AccountRegistry.updateRoot(_:for:)`.
   */
  public var rootNamespaceID: NamespaceIdentifier

  /// Whether ``rootNamespaceID`` names a personal Dropbox or a team space.
  public var rootType: AccountRootType

  /// The member's home folder inside the team space; `nil` for a personal root.
  public var teamHome: TeamHome?

  /// When the account was linked.
  public let linkedAt: Date

  public init(
    accountID: AccountIdentifier,
    email: String,
    displayName: String,
    rootNamespaceID: NamespaceIdentifier,
    rootType: AccountRootType = .personal,
    teamHome: TeamHome? = nil,
    linkedAt: Date = Date()
  ) {
    self.accountID = accountID
    self.email = email
    self.displayName = displayName
    self.rootNamespaceID = rootNamespaceID
    self.rootType = rootType
    self.teamHome = teamHome
    self.linkedAt = linkedAt
  }

  /// Creates a configuration from the account details `users/get_current_account` reports.
  public init(
    accountID: AccountIdentifier,
    email: String,
    displayName: String,
    root: RootInfo,
    linkedAt: Date = Date()
  ) {
    self.init(
      accountID: accountID,
      email: email,
      displayName: displayName,
      rootNamespaceID: root.rootNamespaceID,
      rootType: root.configuredType,
      teamHome: root.configuredTeamHome,
      linkedAt: linkedAt
    )
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    accountID = try container.decode(AccountIdentifier.self, forKey: .accountID)
    email = try container.decode(String.self, forKey: .email)
    displayName = try container.decode(String.self, forKey: .displayName)
    rootNamespaceID = try container.decode(NamespaceIdentifier.self, forKey: .rootNamespaceID)
    linkedAt = try container.decode(Date.self, forKey: .linkedAt)
    // Settings that postdate a stored configuration decode as their defaults.
    rootType = try container.decodeIfPresent(AccountRootType.self, forKey: .rootType) ?? .personal
    teamHome = try container.decodeIfPresent(TeamHome.self, forKey: .teamHome)
  }

  /// Adopts the path root `users/get_current_account` reports, which changes
  /// when the member joins or leaves a team.
  public mutating func adoptRoot(_ root: RootInfo) {
    rootNamespaceID = root.rootNamespaceID
    rootType = root.configuredType
    teamHome = root.configuredTeamHome
  }

  /// A team member's own home folder within the team space.
  public struct TeamHome: Sendable, Equatable, Codable {
    /// The namespace of the member's home folder.
    public let namespaceID: NamespaceIdentifier

    /// The home folder's path within the team space, such as `/Franz Ferdinand`.
    public let path: String

    public init(namespaceID: NamespaceIdentifier, path: String) {
      self.namespaceID = namespaceID
      self.path = path
    }
  }

  private enum CodingKeys: String, CodingKey {
    case accountID, email, displayName, rootNamespaceID, rootType, teamHome, linkedAt
  }
}

extension RootInfo {
  fileprivate var configuredType: AccountRootType {
    switch self {
      case .user: .personal
      case .team: .team
    }
  }

  fileprivate var configuredTeamHome: AccountConfiguration.TeamHome? {
    guard case let .team(_, homeNamespaceID, homePath) = self else { return nil }
    return AccountConfiguration.TeamHome(namespaceID: homeNamespaceID, path: homePath)
  }
}
