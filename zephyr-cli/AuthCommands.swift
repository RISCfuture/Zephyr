import ArgumentParser
import Foundation
import libZephyr

struct AuthCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "auth",
    abstract: "Link, inspect, or unlink Dropbox accounts.",
    subcommands: [Link.self, List.self, Status.self, Unlink.self]
  )

  struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "List linked accounts and whether each can authenticate."
    )

    @Flag(help: "Emit JSON instead of a table.")
    var json = false

    func run() async {
      await CLI.run {
        let manager = CLI.accountManager()
        let accounts = try await manager.linkedAccounts()
        let authenticatable = Set(try await manager.authenticatableAccounts())
        let orphans = try await manager.orphanedTokenAccounts()

        var entries: [Entry] = []
        for account in accounts {
          entries.append(
            Entry(
              account: account,
              configuration: try? await manager.configuration(for: account),
              authenticated: authenticatable.contains(account)
            )
          )
        }

        if json {
          try Output.json(Listing(accounts: entries, orphanedTokens: orphans.map(\.rawValue)))
          return
        }

        if entries.isEmpty {
          print("No accounts are linked. Run “zephyr auth link” to add one.")
        } else {
          Output.table(
            [["ACCOUNT", "DROPBOX ID", "AUTH"]]
              + entries.map { [$0.email ?? Output.missing, $0.accountID, $0.condition] }
          )
        }

        // An orphan is a credential the user believes they revoked, so it is worth
        // saying loudly even when every linked account is healthy.
        guard !orphans.isEmpty else { return }
        print("")
        print("Warning: \(orphans.count) stored token(s) belong to no linked account:")
        for orphan in orphans { print("  \(orphan.rawValue)") }
        print("Revoke them at https://www.dropbox.com/account/connected_apps.")
      }
    }

    /**
     One linked account's health.

     Every account is read on its own, because one unreadable configuration
     must cost the user that account and no other.
     */
    private struct Entry: Encodable {
      let accountID: String

      /// `nil` when the account's configuration could not be read.
      let email: String?

      let authenticated: Bool

      /// Whether the account's configuration file could be read at all.
      let configurationReadable: Bool

      /// How the account's health reads in the table.
      var condition: String {
        guard configurationReadable else { return "configuration unreadable — relink" }
        return authenticated ? "ok" : "needs relink"
      }

      init(
        account: AccountIdentifier,
        configuration: AccountConfiguration?,
        authenticated: Bool
      ) {
        accountID = account.rawValue
        email = configuration?.email
        configurationReadable = configuration != nil
        self.authenticated = authenticated
      }
    }

    private struct Listing: Encodable {
      let accounts: [Entry]
      let orphanedTokens: [String]
    }
  }

  struct Link: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Link a Dropbox account via OAuth."
    )

    func run() async {
      await CLI.run {
        guard DropboxAppCredentials.isConfigured else {
          throw ValidationError(
            """
            No Dropbox app key is configured. Copy Config/Secrets.example.xcconfig to \
            Config/Secrets.xcconfig, fill in the key, and rebuild.
            """
          )
        }
        let flow = await CLI.accountManager().beginLink()
        print("To authorize Zephyr, open this URL and approve access:")
        print("")
        print("  \(flow.authorizationURL.absoluteString)")
        print("")
        CLI.openInBrowser(flow.authorizationURL)
        print("Enter the authorization code shown by Dropbox:", terminator: " ")
        guard let code = readLine(strippingNewline: true), !code.isEmpty else {
          throw ValidationError("No authorization code entered.")
        }
        let session = try await flow.complete(code: code)
        let account = try await session.accountInfo()
        print("Linked \(account.displayName) <\(account.email)> (\(account.accountID.rawValue)).")
      }
    }
  }

  struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Show the linked account and its usage."
    )

    @Flag(help: "Emit JSON instead of a table.")
    var json = false

    @Option(
      help: "The account to inspect, when several are linked.",
      completion: .linkedAccount
    )
    var account: String?

    func run() async {
      await CLI.run {
        let session = try await CLI.session(account: account)
        let report = Report(
          account: try await session.accountInfo(),
          usage: try await session.spaceUsage()
        )
        if json {
          try Output.json(report)
        } else {
          Output.table(report.rows)
        }
      }
    }

    /// A linked account as Dropbox describes it (also the `--json` shape).
    private struct Report: Encodable {
      let accountID: String
      let displayName: String
      let email: String
      let accountType: String
      let usedBytes: UInt64
      /// `nil` when the account draws on an effectively unlimited team pool.
      let allocatedBytes: UInt64?
      let team: String?

      var rows: [[String]] {
        var rows = [
          ["Account:", "\(displayName) <\(email)>"],
          ["Dropbox ID:", accountID],
          ["Type:", accountType],
          ["Usage:", usage]
        ]
        if let team { rows.append(["Team:", team]) }
        return rows
      }

      private var usage: String {
        guard let allocatedBytes else { return Output.bytes(usedBytes) }
        return "\(Output.bytes(usedBytes)) of \(Output.bytes(allocatedBytes))"
      }

      init(account: FullAccount, usage: SpaceUsage) {
        accountID = account.accountID.rawValue
        displayName = account.displayName
        email = account.email
        accountType = account.accountType.rawValue
        usedBytes = usage.used
        allocatedBytes = usage.allocated
        team = account.team?.name
      }
    }
  }

  struct Unlink: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Unlink an account, revoking Zephyr’s access."
    )

    @Option(
      help: "The account to unlink, when several are linked.",
      completion: .linkedAccount
    )
    var account: String?

    @Flag(name: [.customShort("Y"), .customLong("yes")], help: "Skip the confirmation prompt.")
    var assumeYes = false

    func run() async {
      await CLI.run {
        let session = try await CLI.session(account: account)
        let question = """
          Unlink \(session.configuration.email)? This revokes access and deletes local state.
          """
        guard try CLI.confirm(question, assumeYes: assumeYes) else { return }
        try await CLI.accountManager().unlink(session.accountID)
        print("Unlinked \(session.configuration.email).")
      }
    }
  }
}
