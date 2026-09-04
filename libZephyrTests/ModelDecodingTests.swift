import Foundation
import Testing
@testable import libZephyr

@Suite
struct ModelDecodingTests {
  private static let contentHash =
    "599d71033d700ac892a0e48fa61b125d2f5994d274d878af308a468e11f0b12f"
  private static let cursor = "ZtkX9_EHj3x7PMkVuFIhwKYXEpwpLwyxp9vMKomUhllil9q7eWiAu"
  // 2015-05-12T15:50:38Z
  private static let clientModified = Date(timeIntervalSince1970: 1_431_445_838)
  // 2015-05-12T15:51:19Z
  private static let serverModified = Date(timeIntervalSince1970: 1_431_445_879)
  // 2030-01-01T00:00:00Z
  private static let linkExpiration = Date(timeIntervalSince1970: 1_893_456_000)

  private static let fullFileJSON = """
    {
        ".tag": "file",
        "id": "id:a4ayc_80_OEAAAAAAAAAXw",
        "name": "Prime_Numbers.txt",
        "path_lower": "/homework/math/prime_numbers.txt",
        "path_display": "/Homework/math/Prime_Numbers.txt",
        "client_modified": "2015-05-12T15:50:38Z",
        "server_modified": "2015-05-12T15:51:19Z",
        "rev": "a1c10ce0dd78",
        "size": 7212,
        "is_downloadable": true,
        "content_hash": "\(contentHash)",
        "sharing_info": {
            "read_only": true,
            "parent_shared_folder_id": "84528192421",
            "modified_by": "dbid:AAH4f99T0taONIb-OurWxbNQ6ywGRopQngc"
        }
    }
    """

  private static let sharedFolderJSON = """
    {
        ".tag": "folder",
        "id": "id:a4ayc_80_OEAAAAAAAAAXz",
        "name": "math",
        "path_lower": "/homework/math",
        "path_display": "/Homework/math",
        "shared_folder_id": "84528192421"
    }
    """

  private static let plainFolderJSON = """
    {
        ".tag": "folder",
        "id": "id:a4ayc_80_OEAAAAAAAAAXz",
        "name": "math",
        "path_lower": "/homework/math",
        "path_display": "/Homework/math"
    }
    """

  private static let deletedJSON = """
    {
        ".tag": "deleted",
        "name": "Old_Draft.txt",
        "path_lower": "/homework/old_draft.txt",
        "path_display": "/Homework/Old_Draft.txt"
    }
    """

  private static let sharedLinkJSON = """
    {
        ".tag": "file",
        "url": "https://www.dropbox.com/s/2sn712vy1ovegw8/Prime_Numbers.txt?dl=0",
        "id": "id:a4ayc_80_OEAAAAAAAAAXw",
        "name": "Prime_Numbers.txt",
        "path_lower": "/homework/math/prime_numbers.txt",
        "expires": "2030-01-01T00:00:00Z",
        "link_permissions": {
            "can_revoke": true,
            "allow_download": true,
            "resolved_visibility": {".tag": "public"},
            "effective_audience": {".tag": "public"},
            "link_access_level": {".tag": "viewer"},
            "require_password": false
        },
        "client_modified": "2015-05-12T15:50:38Z",
        "server_modified": "2015-05-12T15:51:19Z",
        "rev": "a1c10ce0dd78",
        "size": 7212
    }
    """

  private static let basicAccountJSON = """
    {
        "account_id": "dbid:AAH4f99T0taONIb-OurWxbNQ6ywGRopQngc",
        "name": {
            "given_name": "Franz",
            "surname": "Ferdinand",
            "familiar_name": "Franz",
            "display_name": "Franz Ferdinand (Acme, Inc.)",
            "abbreviated_name": "FF"
        },
        "email": "franz@acme.com",
        "email_verified": true,
        "disabled": false,
        "is_teammate": true,
        "profile_photo_url": "https://dropbox.com/franz.jpg",
        "team_member_id": "dbmid:AAHhy7WsR0x-u4ZCqiDl5Fz5zvuL3kmspwU"
    }
    """

  private static func teamAccountJSON(rootTag: String = "team") -> String {
    """
    {
        "account_id": "dbid:AAH4f99T0taONIb-OurWxbNQ6ywGRopQngc",
        "name": {
            "given_name": "Franz",
            "surname": "Ferdinand",
            "familiar_name": "Franz",
            "display_name": "Franz Ferdinand (Acme, Inc.)",
            "abbreviated_name": "FF"
        },
        "email": "franz@acme.com",
        "email_verified": true,
        "disabled": false,
        "locale": "en",
        "account_type": {".tag": "business"},
        "team": {
            "id": "dbtid:AAFdgehTzw7WlXhZJsbGCLePe8RvQGYDr-I",
            "name": "Acme, Inc."
        },
        "team_member_id": "dbmid:AAHhy7WsR0x-u4ZCqiDl5Fz5zvuL3kmspwU",
        "root_info": {
            ".tag": "\(rootTag)",
            "root_namespace_id": "7684224",
            "home_namespace_id": "3235641",
            "home_path": "/Franz Ferdinand"
        }
    }
    """
  }

  private static func decode<Model: Decodable>(_ type: Model.Type, from json: String) throws
    -> Model
  {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(type, from: Data(json.utf8))
  }

  private static func fileJSON(
    id: String = "id:a4ayc_80_OEAAAAAAAAAXw",
    rev: String = "a1c10ce0dd78",
    pathLower: String = "/homework/math/prime_numbers.txt",
    appending additionalFields: String = ""
  ) -> String {
    let suffix = additionalFields.isEmpty ? "" : ",\n    \(additionalFields)"
    return """
      {
          "id": "\(id)",
          "name": "Prime_Numbers.txt",
          "path_lower": "\(pathLower)",
          "path_display": "/Homework/math/Prime_Numbers.txt",
          "client_modified": "2015-05-12T15:50:38Z",
          "server_modified": "2015-05-12T15:51:19Z",
          "rev": "\(rev)",
          "size": 7212,
          "content_hash": "\(contentHash)"\(suffix)
      }
      """
  }

  private static func personalAccountJSON(accountType: String = "pro") -> String {
    """
    {
        "account_id": "dbid:AAH4f99T0taONIb-OurWxbNQ6ywGRopQngc",
        "name": {
            "given_name": "Franz",
            "surname": "Ferdinand",
            "familiar_name": "Franz",
            "display_name": "Franz Ferdinand (Personal)",
            "abbreviated_name": "FF"
        },
        "email": "franz@dropbox.com",
        "email_verified": true,
        "disabled": false,
        "country": "US",
        "locale": "en",
        "referral_link": "https://db.tt/ZITNuhtI",
        "is_paired": true,
        "account_type": {".tag": "\(accountType)"},
        "root_info": {
            ".tag": "user",
            "root_namespace_id": "3235641",
            "home_namespace_id": "3235641"
        },
        "profile_photo_url": \
    "https://dl-web.dropbox.com/account_photo/get/dbaphid%3AAAHWGmIXV3s?vers=1556069330102&size=128x128"
    }
    """
  }

  private static func teamSpaceUsageJSON(memberCap: UInt64) -> String {
    """
    {
        "used": 314159265,
        "allocation": {
            ".tag": "team",
            "used": 27182818284,
            "allocated": 4398046511104,
            "user_within_team_space_allocated": \(memberCap),
            "user_within_team_space_limit_type": {".tag": "off"}
        }
    }
    """
  }

  private static func namespace(_ rawValue: String) throws -> NamespaceIdentifier {
    try NamespaceIdentifier(validating: rawValue)
  }

  // MARK: - FileMetadata

  @Test
  func `full file fixture decodes every field`() throws {
    let file = try Self.decode(FileMetadata.self, from: Self.fullFileJSON)
    #expect(file.id.rawValue == "id:a4ayc_80_OEAAAAAAAAAXw")
    #expect(file.name == "Prime_Numbers.txt")
    #expect(file.pathLower?.rawValue == "/homework/math/prime_numbers.txt")
    #expect(file.pathDisplay?.rawValue == "/Homework/math/Prime_Numbers.txt")
    #expect(file.clientModified == Self.clientModified)
    #expect(file.serverModified == Self.serverModified)
    #expect(file.rev.rawValue == "a1c10ce0dd78")
    #expect(file.size == 7212)
    #expect(file.symlinkTarget == nil)
    #expect(file.isShared)
    #expect(file.modifiedBy?.rawValue == "dbid:AAH4f99T0taONIb-OurWxbNQ6ywGRopQngc")
    #expect(file.isDownloadable)
    #expect(file.contentHash?.rawValue == Self.contentHash)
  }

  @Test
  func `minimal file defaults sharing and downloadability`() throws {
    let file = try Self.decode(FileMetadata.self, from: Self.fileJSON())
    #expect(!file.isShared)
    #expect(file.modifiedBy == nil)
    #expect(file.symlinkTarget == nil)
    #expect(file.isDownloadable)
    #expect(file.contentHash?.rawValue == Self.contentHash)
  }

  @Test
  func `symlink info yields symlink target`() throws {
    let json = Self.fileJSON(appending: #""symlink_info": {"target": "../foo"}"#)
    let file = try Self.decode(FileMetadata.self, from: json)
    #expect(file.symlinkTarget == "../foo")
  }

  // MARK: - FolderMetadata

  @Test
  func `folder with shared folder identifier is shared`() throws {
    let folder = try Self.decode(FolderMetadata.self, from: Self.sharedFolderJSON)
    #expect(folder.id.rawValue == "id:a4ayc_80_OEAAAAAAAAAXz")
    #expect(folder.name == "math")
    #expect(folder.pathLower?.rawValue == "/homework/math")
    #expect(folder.pathDisplay?.rawValue == "/Homework/math")
    #expect(folder.isShared)
  }

  @Test
  func `folder without sharing keys is not shared`() throws {
    let folder = try Self.decode(FolderMetadata.self, from: Self.plainFolderJSON)
    #expect(!folder.isShared)
  }

  // MARK: - ItemMetadata union

  @Test
  func `metadata union decodes each tagged case`() throws {
    let json = "[\(Self.fullFileJSON), \(Self.sharedFolderJSON), \(Self.deletedJSON)]"
    let entries = try Self.decode([ItemMetadata].self, from: json)
    try #require(entries.count == 3)
    guard
      case .file(let file) = entries[0],
      case .folder(let folder) = entries[1],
      case .deleted(let deleted) = entries[2]
    else {
      Issue.record("Entries decoded to unexpected cases: \(entries)")
      return
    }
    #expect(file.name == "Prime_Numbers.txt")
    #expect(folder.name == "math")
    #expect(deleted.name == "Old_Draft.txt")
    #expect(deleted.pathLower?.rawValue == "/homework/old_draft.txt")
    #expect(deleted.pathDisplay?.rawValue == "/Homework/Old_Draft.txt")
  }

  @Test
  func `unknown metadata tag is rejected`() {
    #expect(throws: DecodingError.self) {
      try Self.decode(ItemMetadata.self, from: #"{".tag": "weird", "name": "mystery"}"#)
    }
  }

  // MARK: - ListFolderPage

  @Test
  func `list folder page decodes entries cursor and paging flag`() throws {
    let json = """
      {
          "entries": [\(Self.fullFileJSON), \(Self.deletedJSON)],
          "cursor": "\(Self.cursor)",
          "has_more": true
      }
      """
    let page = try Self.decode(ListFolderPage.self, from: json)
    #expect(page.entries.count == 2)
    #expect(page.cursor.rawValue == Self.cursor)
    #expect(page.hasMore)
  }

  @Test
  func `a page skips entries of an unrecognized kind and keeps the rest`() throws {
    let json = """
      {
          "entries": [
              {".tag": "hologram", "name": "Something_New.txt"},
              \(Self.fullFileJSON)
          ],
          "cursor": "\(Self.cursor)",
          "has_more": false
      }
      """
    let page = try Self.decode(ListFolderPage.self, from: json)
    #expect(page.entries.map(\.name) == ["Prime_Numbers.txt"])
  }

  // MARK: - FullAccount

  @Test
  func `personal account decodes with user root info`() throws {
    let account = try Self.decode(FullAccount.self, from: Self.personalAccountJSON())
    #expect(account.accountID.rawValue == "dbid:AAH4f99T0taONIb-OurWxbNQ6ywGRopQngc")
    #expect(account.displayName == "Franz Ferdinand (Personal)")
    #expect(account.email == "franz@dropbox.com")
    #expect(account.emailVerified)
    #expect(account.profilePhotoURL?.host() == "dl-web.dropbox.com")
    #expect(!account.disabled)
    #expect(account.country == "US")
    #expect(account.locale == "en")
    #expect(account.team == nil)
    #expect(account.teamMemberID == nil)
    #expect(account.accountType == .pro)
    let expectedRoot = RootInfo.user(
      rootNamespaceID: try Self.namespace("3235641"),
      homeNamespaceID: try Self.namespace("3235641")
    )
    #expect(account.rootInfo == expectedRoot)
  }

  @Test
  func `team account decodes with team root info`() throws {
    let account = try Self.decode(FullAccount.self, from: Self.teamAccountJSON())
    #expect(
      account.team == Team(id: "dbtid:AAFdgehTzw7WlXhZJsbGCLePe8RvQGYDr-I", name: "Acme, Inc.")
    )
    #expect(account.teamMemberID == "dbmid:AAHhy7WsR0x-u4ZCqiDl5Fz5zvuL3kmspwU")
    #expect(account.accountType == .business)
    #expect(account.profilePhotoURL == nil)
    #expect(account.country == nil)
    let expectedRoot = RootInfo.team(
      rootNamespaceID: try Self.namespace("7684224"),
      homeNamespaceID: try Self.namespace("3235641"),
      homePath: "/Franz Ferdinand"
    )
    #expect(account.rootInfo == expectedRoot)
  }

  @Test
  func `an unrecognized root kind decodes as personal so linking still succeeds`() throws {
    let account = try Self.decode(
      FullAccount.self,
      from: Self.teamAccountJSON(rootTag: "enterprise")
    )
    let expectedRoot = RootInfo.user(
      rootNamespaceID: try Self.namespace("7684224"),
      homeNamespaceID: try Self.namespace("3235641")
    )
    #expect(account.rootInfo == expectedRoot)
  }

  @Test
  func `unknown account type decodes as other`() throws {
    let account = try Self.decode(
      FullAccount.self,
      from: Self.personalAccountJSON(accountType: "plus_plus")
    )
    #expect(account.accountType == .other)
  }

  // MARK: - BasicAccount

  @Test
  func `basic account takes the display form of the name`() throws {
    let account = try Self.decode(BasicAccount.self, from: Self.basicAccountJSON)
    #expect(account.accountID.rawValue == "dbid:AAH4f99T0taONIb-OurWxbNQ6ywGRopQngc")
    #expect(account.displayName == "Franz Ferdinand (Acme, Inc.)")
    #expect(account.email == "franz@acme.com")
    #expect(account.profilePhotoURL?.absoluteString == "https://dropbox.com/franz.jpg")
  }

  // MARK: - SpaceUsage

  @Test
  func `individual allocation yields allocated bytes`() throws {
    let json =
      #"{"used": 314159265, "allocation": {".tag": "individual", "allocated": 10613916672}}"#
    let usage = try Self.decode(SpaceUsage.self, from: json)
    #expect(usage.used == 314_159_265)
    #expect(usage.allocated == 10_613_916_672)
  }

  @Test
  func `team allocation with zero member cap draws on team pool`() throws {
    let usage = try Self.decode(SpaceUsage.self, from: Self.teamSpaceUsageJSON(memberCap: 0))
    #expect(usage.allocated == 4_398_046_511_104)
  }

  @Test
  func `team allocation with member cap uses the cap`() throws {
    let usage = try Self.decode(
      SpaceUsage.self,
      from: Self.teamSpaceUsageJSON(memberCap: 2_199_023_255_552)
    )
    #expect(usage.allocated == 2_199_023_255_552)
  }

  // MARK: - Shared links

  @Test
  func `shared link metadata decodes link permissions`() throws {
    let link = try Self.decode(SharedLinkMetadata.self, from: Self.sharedLinkJSON)
    #expect(
      link.url.absoluteString == "https://www.dropbox.com/s/2sn712vy1ovegw8/Prime_Numbers.txt?dl=0"
    )
    #expect(link.name == "Prime_Numbers.txt")
    #expect(link.pathLower?.rawValue == "/homework/math/prime_numbers.txt")
    #expect(link.expires == Self.linkExpiration)
    #expect(link.permissions.canRevoke)
    #expect(link.permissions.allowDownload)
    #expect(link.permissions.effectiveAudience == .public)
    #expect(link.permissions.linkAccessLevel == .viewer)
    #expect(!link.permissions.requirePassword)
  }

  @Test
  func `link permissions default omitted fields`() throws {
    let permissions = try Self.decode(LinkPermissions.self, from: #"{"can_revoke": false}"#)
    #expect(!permissions.canRevoke)
    #expect(permissions.allowDownload)
    #expect(!permissions.requirePassword)
    #expect(permissions.effectiveAudience == nil)
    #expect(permissions.linkAccessLevel == nil)
  }

  @Test
  func `list shared links result decodes page`() throws {
    let json = """
      {
          "links": [\(Self.sharedLinkJSON)],
          "has_more": true,
          "cursor": "\(Self.cursor)"
      }
      """
    let result = try Self.decode(ListSharedLinksResult.self, from: json)
    #expect(result.links.count == 1)
    #expect(result.links.first?.name == "Prime_Numbers.txt")
    #expect(result.hasMore)
    #expect(result.cursor == Self.cursor)
  }

  // MARK: - Shared folders

  @Test
  func `a completed share yields the shared folder`() throws {
    let json = """
      {
          ".tag": "complete",
          "shared_folder_id": "84528192421",
          "name": "math",
          "path_lower": "/homework/math",
          "is_team_folder": false,
          "access_type": {".tag": "owner"}
      }
      """
    let launch = try Self.decode(ShareFolderLaunch.self, from: json)
    let folder = try #require(launch.sharedFolder)
    #expect(folder.sharedFolderID == "84528192421")
    #expect(folder.pathLower?.rawValue == "/homework/math")
    #expect(!folder.isTeamFolder)
  }

  @Test
  func `an asynchronous share yields its job identifier`() throws {
    let json = #"{".tag": "async_job_id", "async_job_id": "34g93hh34h04y384084"}"#
    let launch = try Self.decode(ShareFolderLaunch.self, from: json)
    #expect(launch == .inProgress(jobID: "34g93hh34h04y384084"))
    #expect(launch.sharedFolder == nil)
  }

  // MARK: - LongpollResult

  @Test
  func `longpoll result maps backoff to seconds`() throws {
    let result = try Self.decode(LongpollResult.self, from: #"{"changes": true, "backoff": 60}"#)
    #expect(result.changes)
    #expect(result.backoff == .seconds(60))
  }

  @Test
  func `longpoll result without backoff has none`() throws {
    let result = try Self.decode(LongpollResult.self, from: #"{"changes": false}"#)
    #expect(!result.changes)
    #expect(result.backoff == nil)
  }

  // MARK: - Strict validation

  @Test
  func `non hexadecimal revision is rejected`() {
    #expect(throws: DecodingError.self) {
      try Self.decode(FileMetadata.self, from: Self.fileJSON(rev: "XYZ NOT HEX"))
    }
  }

  @Test
  func `file identifier without prefix is rejected`() {
    #expect(throws: DecodingError.self) {
      try Self.decode(FileMetadata.self, from: Self.fileJSON(id: "a4ayc_80_OEAAAAAAAAAXw"))
    }
  }

  @Test
  func `path lower without leading slash is rejected`() {
    #expect(throws: DecodingError.self) {
      try Self.decode(FileMetadata.self, from: Self.fileJSON(pathLower: "no-leading-slash"))
    }
  }
}
