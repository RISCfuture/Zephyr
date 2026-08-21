import ArgumentParser
import Foundation
import libZephyr

/**
 When a shared link stops working, in the forms `--expiry` accepts: an ISO 8601
 instant (`2026-09-01T17:00:00Z`), a calendar day in the same notation
 (`2026-09-01`), or a span from now (`90m`, `48h`, `14d`, `4w`).
 */
struct LinkExpiry: ExpressibleByArgument, Equatable {
  private static let secondsPerUnit: [Character: TimeInterval] = [
    "m": 60,
    "h": 60 * 60,
    "d": 24 * 60 * 60,
    "w": 7 * 24 * 60 * 60
  ]

  let date: Date

  init?(argument: String) {
    guard let date = Self.span(from: argument) ?? Self.instant(from: argument) else { return nil }
    self.date = date
  }

  /// A whole number of minutes, hours, days, or weeks from now.
  private static func span(from argument: String) -> Date? {
    guard let unit = argument.last, let seconds = secondsPerUnit[unit],
      let count = Int(argument.dropLast()), count > 0
    else { return nil }
    return Date(timeIntervalSinceNow: TimeInterval(count) * seconds)
  }

  /// An ISO 8601 instant, or a calendar day, which expires at its UTC start.
  private static func instant(from argument: String) -> Date? {
    if let instant = try? Date(argument, strategy: .iso8601) { return instant }
    let day = Date.ISO8601FormatStyle(dateSeparator: .dash).year().month().day()
    return try? Date(argument, strategy: day)
  }
}

/// Who a `sharelink` command offers a link to. `LinkAudience.other` is
/// response-only, so it is not among them.
enum ShareLinkAudience: String, CaseIterable, ExpressibleByArgument {
  case `public`
  case team
  case noOne = "no-one"

  var linkAudience: LinkAudience {
    switch self {
      case .public: .public
      case .team: .team
      case .noOne: .noOne
    }
  }
}

/// What a `sharelink` command lets a link's audience do.
/// `LinkAccessLevel.other` is response-only, so it is not among them.
enum ShareLinkAccessLevel: String, CaseIterable, ExpressibleByArgument {
  case viewer
  case editor

  var linkAccessLevel: LinkAccessLevel {
    switch self {
      case .viewer: .viewer
      case .editor: .editor
    }
  }
}

/// One shared link as the CLI reports it (also the `--json` shape).
struct ListedSharedLink: Encodable {
  let url: String
  let name: String
  /// `nil` for a link to an item outside the account's own Dropbox.
  let path: String?
  /// What the audience may do, where Dropbox reports it.
  let access: String?
  /// Who the link reaches, where Dropbox reports it.
  let audience: String?
  /// When the link stops working; `nil` for one that never does.
  let expires: Date?
  let requiresPassword: Bool
  let allowDownload: Bool

  init(_ metadata: SharedLinkMetadata) {
    url = metadata.url.absoluteString
    name = metadata.name
    path = metadata.pathLower?.rawValue
    access = metadata.permissions.linkAccessLevel?.rawValue
    audience = metadata.permissions.effectiveAudience?.rawValue
    expires = metadata.expires
    requiresPassword = metadata.permissions.requirePassword
    allowDownload = metadata.permissions.allowDownload
  }
}

struct ShareLinkCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "sharelink",
    abstract: "Create, list, or revoke shared links.",
    subcommands: [Create.self, List.self, Revoke.self]
  )

  /// The columns `--long` adds, and the cells that fill them.
  fileprivate static func longRow(of link: ListedSharedLink) -> [String] {
    [
      link.url,
      link.access ?? Output.missing,
      link.audience ?? Output.missing,
      link.expires.map { Output.date($0) } ?? "never",
      link.path ?? link.name
    ]
  }

  struct Create: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Create a shared link for a file or folder.",
      discussion: """
        Passwords, expiry times, and audience restrictions need a paid Dropbox plan; on a free \
        account Dropbox refuses the settings rather than quietly dropping them. Settings left \
        unset keep Dropbox’s defaults for the item.
        """
    )

    @Argument(help: "The Dropbox path to share.", completion: .dropboxPath)
    var path: String

    @Option(
      name: [.short, .customLong("password")],
      help: "Protect the link with a password."
    )
    var password: String?

    @Option(
      name: [.short, .customLong("expiry")],
      help: ArgumentHelp(
        """
        When the link stops working: an ISO 8601 date or time, or a span from now such as 90m, \
        48h, 14d, or 4w.
        """,
        valueName: "when"
      )
    )
    var expiry: LinkExpiry?

    @Option(help: "Who may use the link.")
    var audience: ShareLinkAudience?

    @Option(help: "What the link’s audience may do.")
    var access: ShareLinkAccessLevel?

    @Flag(inversion: .prefixedNo, help: "Whether the audience may download the item.")
    var allowDownload: Bool?

    @Flag(help: "Emit JSON instead of the link URL.")
    var json = false

    @OptionGroup var accountOptions: AccountOptions

    private var settings: SharedLinkSettings {
      SharedLinkSettings(
        password: password,
        expires: expiry?.date,
        audience: audience?.linkAudience,
        accessLevel: access?.linkAccessLevel,
        allowDownload: allowDownload
      )
    }

    func run() async {
      await CLI.run {
        let session = try await CLI.session(account: accountOptions.account)
        let link = try await session.createSharedLink(
          for: try CLI.dropboxPath(path),
          settings: settings
        )
        if json {
          try Output.json(ListedSharedLink(link))
        } else {
          print(link.url.absoluteString)
        }
      }
    }
  }

  struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "List shared links.",
      discussion: """
        With no paths, every shared link in the account is listed. With paths, only the links to \
        those items are.
        """
    )

    @Argument(help: "Restrict to these Dropbox paths.", completion: .dropboxPath)
    var paths: [String] = []

    @Flag(
      name: [.short, .long],
      help: "Long format: access, audience, and expiry columns."
    )
    var long = false

    @Flag(help: "Emit JSON instead of a table.")
    var json = false

    @OptionGroup var accountOptions: AccountOptions

    /// Every link to the given paths, in the order the paths were named and
    /// without repeating a link two of them share.
    private static func links(
      for paths: [String],
      in session: AccountSession
    ) async throws -> [ListedSharedLink] {
      guard !paths.isEmpty else {
        return try await session.listSharedLinks().map(ListedSharedLink.init)
      }
      var seen = Set<URL>()
      var links: [ListedSharedLink] = []
      for path in paths {
        let found = try await session.listSharedLinks(for: try CLI.dropboxPath(path))
        links += found.filter { seen.insert($0.url).inserted }.map(ListedSharedLink.init)
      }
      return links
    }

    func run() async {
      await CLI.run {
        let session = try await CLI.session(account: accountOptions.account)
        let links = try await Self.links(for: paths, in: session)
        if json {
          try Output.json(links)
        } else if long {
          Output.table(
            [["URL", "ACCESS", "AUDIENCE", "EXPIRES", "PATH"]]
              + links.map(ShareLinkCommand.longRow)
          )
        } else {
          Output.table(links.map { [$0.url, $0.path ?? $0.name] })
        }
      }
    }
  }

  struct Revoke: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Revoke shared links."
    )

    @Argument(help: "The link URLs to revoke.")
    var urls: [String]

    @OptionGroup var accountOptions: AccountOptions

    func run() async {
      await CLI.run {
        let session = try await CLI.session(account: accountOptions.account)
        for urlString in urls {
          guard let url = URL(string: urlString) else {
            throw ValidationError("“\(urlString)” is not a URL.")
          }
          try await session.revokeSharedLink(url)
          print("Revoked \(urlString).")
        }
      }
    }
  }
}
