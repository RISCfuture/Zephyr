import Foundation

/**
 The linked-accounts registry: a JSON file in the shared container listing
 every linked account, plus the per-account configuration files.

 All writes go through this actor and land atomically.
 */
actor AccountRegistry {
  private let environment: ZephyrEnvironment

  /**
   Creates a registry over an environment's shared container.

   - Parameter environment: Where the registry and configuration files live.
     Tests point this at a temporary directory; everything else takes the default.
   */
  init(environment: ZephyrEnvironment = .standard) {
    self.environment = environment
  }

  /// The identifiers of all linked accounts.
  func linkedAccounts() throws -> [AccountIdentifier] {
    let url = environment.registryURL
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    return try decoder().decode([AccountIdentifier].self, from: Data(contentsOf: url))
  }

  /// Loads one account's configuration.
  func configuration(for account: AccountIdentifier) throws -> AccountConfiguration {
    try decoder().decode(
      AccountConfiguration.self,
      from: Data(contentsOf: environment.configurationURL(for: account))
    )
  }

  /// Registers an account and stores its configuration.
  func register(_ configuration: AccountConfiguration) throws {
    try environment.ensureAccountDirectories(for: configuration.accountID)
    try save(configuration)
    var accounts = try linkedAccounts()
    if !accounts.contains(configuration.accountID) {
      accounts.append(configuration.accountID)
      try saveRegistry(accounts)
    }
  }

  /// Updates a registered account's configuration.
  func save(_ configuration: AccountConfiguration) throws {
    try write(
      encoder().encode(configuration),
      to: environment.configurationURL(for: configuration.accountID),
      signalling: .configuration(configuration.accountID)
    )
  }

  /**
   Applies a change to a registered account's configuration and stores it.

   - Parameters:
     - account: The account whose configuration to change.
     - change: Applied to the stored configuration before it is written back.
   - Returns: The configuration as stored.
   */
  @discardableResult
  func update(
    _ account: AccountIdentifier,
    _ change: @Sendable (inout AccountConfiguration) -> Void
  ) throws -> AccountConfiguration {
    var updated = try configuration(for: account)
    change(&updated)
    try save(updated)
    return updated
  }

  /// Records the path root `users/get_current_account` reports, which changes
  /// when the member joins or leaves a team.
  @discardableResult
  func updateRoot(
    _ root: RootInfo,
    for account: AccountIdentifier
  ) throws -> AccountConfiguration {
    try update(account) { $0.adoptRoot(root) }
  }

  /// Removes an account's registration and its entire state directory.
  func unregister(_ account: AccountIdentifier) throws {
    let accounts = try linkedAccounts().filter { $0 != account }
    try saveRegistry(accounts)
    try? FileManager.default.removeItem(at: environment.accountDirectory(for: account))
  }

  private func saveRegistry(_ accounts: [AccountIdentifier]) throws {
    try FileManager.default.createDirectory(
      at: environment.baseDirectory,
      withIntermediateDirectories: true
    )
    try write(encoder().encode(accounts), to: environment.registryURL, signalling: nil)
  }

  /**
   Writes one configuration file and tells the other processes it changed.

   - Parameter signal: What to post once the write lands, or `nil` for a file
     nothing watches. Every write goes through here, so this is the one place
     a reader in another process learns anything.
   */
  private func write(_ data: Data, to url: URL, signalling signal: ChangeSignal?) throws {
    try data.write(to: url, options: .atomic)
    signal?.post()
  }

  private func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  private func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }
}
