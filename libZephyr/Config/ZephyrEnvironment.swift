import Foundation

/**
 Resolves where Zephyr keeps its shared state: the app-group container that the
 app, the File Provider extension, and the CLI all read.

 Layout under the base directory:
 ```
 Zephyr/
 ├── accounts.json                  the account registry
 ├── install-id                     the crash reports' installation identifier
 └── Accounts/<account_id>/
     ├── config.json                per-account configuration
     ├── index.sqlite               the sync index
     └── cache/                     temporary download staging
 ```
 */
public struct ZephyrEnvironment: Sendable {
  /// The app group shared by every Zephyr process.
  public static let appGroupIdentifier = "group.codes.tim.Zephyr"

  /**
   The environment rooted in the shared app-group container, or `nil` when this
   process has no such container.

   That happens only in a build signed without entitlements — an unsigned local
   build, or a job that turned code signing off. Anything that cannot carry on
   without shared state uses ``standard``, which stops the process instead of
   answering `nil`.
   */
  public static let shared: Self? =
    FileManager.default
    .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    .map {
      Self(baseDirectory: $0.appending(components: "Library", "Application Support", "Zephyr"))
    }

  /// The environment rooted in the shared app-group container.
  public static let standard: Self = {
    guard let shared else {
      preconditionFailure(
        """
        No container for app group \(appGroupIdentifier): this process is missing the \
        com.apple.security.application-groups entitlement.
        """
      )
    }
    return shared
  }()

  /// The directory all Zephyr state lives under.
  public let baseDirectory: URL

  /// The account registry file.
  public var registryURL: URL { baseDirectory.appending(component: "accounts.json") }

  /// The file holding the identifier crash reports are attributed to; see
  /// ``CrashReporting``.
  public var installationIdentifierURL: URL {
    baseDirectory.appending(component: "install-id")
  }

  /// Where the notification level and snooze deadline are stored, beside the
  /// account registry because they belong to the Mac and to no one account.
  public var notificationSettingsURL: URL {
    baseDirectory.appending(component: "notifications.json")
  }

  /// Where the Mac's transfer limits are stored, beside the account registry
  /// because they belong to the same shared container and to no one account.
  public var bandwidthSettingsURL: URL {
    baseDirectory.appending(component: "bandwidth.json")
  }

  /// Creates an environment rooted at an explicit directory (tests, custom setups).
  public init(baseDirectory: URL) {
    self.baseDirectory = baseDirectory
  }

  /// The state directory for one account, created on demand.
  public func accountDirectory(for account: AccountIdentifier) -> URL {
    baseDirectory.appending(components: "Accounts", account.rawValue)
  }

  /// The per-account configuration file.
  public func configurationURL(for account: AccountIdentifier) -> URL {
    accountDirectory(for: account).appending(component: "config.json")
  }

  /// The per-account sync index database.
  public func indexURL(for account: AccountIdentifier) -> URL {
    accountDirectory(for: account).appending(component: "index.sqlite")
  }

  /// The per-account staging directory for in-flight downloads.
  public func cacheDirectory(for account: AccountIdentifier) -> URL {
    accountDirectory(for: account).appending(component: "cache")
  }

  /// Creates the account's directories if they do not exist yet.
  public func ensureAccountDirectories(for account: AccountIdentifier) throws {
    try FileManager.default.createDirectory(
      at: cacheDirectory(for: account),
      withIntermediateDirectories: true
    )
  }
}
