import Foundation
import Synchronization
import Testing

@testable import libZephyr

/// A token store held in memory, which can be made to fail the way a locked or
/// unreachable keychain does.
private final class StubTokenStore: TokenStore {
  private let tokens: Mutex<[AccountIdentifier: String]>
  private let readFailure: OSStatus?

  /// - Parameter readFailure: The status ``refreshToken(for:)`` fails with, or
  ///   `nil` for a store that answers.
  init(tokens: [AccountIdentifier: String] = [:], readFailure: OSStatus? = nil) {
    self.tokens = Mutex(tokens)
    self.readFailure = readFailure
  }

  func refreshToken(for account: AccountIdentifier) throws -> String? {
    if let readFailure { throw AuthenticationFailure.keychain(status: readFailure) }
    return tokens.withLock { $0[account] }
  }

  func store(refreshToken: String, for account: AccountIdentifier) throws {
    tokens.withLock { $0[account] = refreshToken }
  }

  func deleteRefreshToken(for account: AccountIdentifier) throws {
    tokens.withLock { $0[account] = nil }
  }

  func storedAccounts() throws -> [AccountIdentifier] {
    tokens.withLock { Array($0.keys) }
  }
}

/// The container, registry, and accounts a test works against.
private struct AccountFixture {
  let environment: ZephyrEnvironment
  let registry: AccountRegistry
  let directory: URL

  static func make() throws -> Self {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("zephyr-accounts-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let environment = ZephyrEnvironment(baseDirectory: directory)
    return Self(
      environment: environment,
      registry: AccountRegistry(environment: environment),
      directory: directory
    )
  }

  /// Registers an account and leaves an index file in its directory, standing
  /// in for the local state an unlink is meant to take with it.
  func register(_ configuration: AccountConfiguration) async throws {
    try await registry.register(configuration)
    try Data("index".utf8).write(to: environment.indexURL(for: configuration.accountID))
  }

  func manager(tokenStore: any TokenStore) -> AccountManager {
    AccountManager(environment: environment, tokenStore: tokenStore)
  }

  func tearDown() {
    try? FileManager.default.removeItem(at: directory)
  }
}

/// A linked account. Its link date is a whole second, which is the resolution
/// the registry's ISO 8601 encoding keeps, so a stored account compares equal
/// to the one that was stored.
private func account(
  _ id: String,
  email: String,
  displayName: String = "Franz Ferdinand"
) throws -> AccountConfiguration {
  AccountConfiguration(
    accountID: try AccountIdentifier(validating: id),
    email: email,
    displayName: displayName,
    rootNamespaceID: try NamespaceIdentifier(validating: "3235641"),
    linkedAt: Date(timeIntervalSince1970: 1_800_000_000)
  )
}

/// What `users/get_current_account` reports for an account, which is all
/// ``AccountManager/confirm(_:satisfies:)`` has to go on.
private func authorized(_ id: String, email: String) throws -> FullAccount {
  try JSONDecoder().decode(
    FullAccount.self,
    from: Data(
      """
      {
          "account_id": "\(id)",
          "name": {"display_name": "Franz Ferdinand"},
          "email": "\(email)",
          "email_verified": true,
          "disabled": false,
          "locale": "en",
          "account_type": {".tag": "basic"},
          "root_info": {
              ".tag": "user",
              "root_namespace_id": "3235641",
              "home_namespace_id": "3235641"
          }
      }
      """.utf8
    )
  )
}

private let personalID = "dbid:AAH4f99T0taONIb-personal"
private let workID = "dbid:AAH4f99T0taONIb-work"

@Suite
struct `Account registry teardown` {
  @Test
  func `Unregistering takes one account's whole directory and leaves the others standing`()
    async throws
  {
    let fixture = try AccountFixture.make()
    defer { fixture.tearDown() }
    let personal = try account(personalID, email: "franz@example.com")
    let work = try account(workID, email: "franz@acme.com")
    try await fixture.register(personal)
    try await fixture.register(work)

    try await fixture.registry.unregister(personal.accountID)

    #expect(try await fixture.registry.linkedAccounts() == [work.accountID])
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.environment.accountDirectory(for: personal.accountID).path
      )
    )
    // The account that stayed keeps its configuration and its index: teardown
    // that reached beyond the account it was asked about would be silent.
    #expect(try await fixture.registry.configuration(for: work.accountID) == work)
    #expect(
      FileManager.default.fileExists(
        atPath: fixture.environment.indexURL(for: work.accountID).path
      )
    )
  }

  @Test
  func `Unregistering an account that is not registered changes nothing`() async throws {
    let fixture = try AccountFixture.make()
    defer { fixture.tearDown() }
    let personal = try account(personalID, email: "franz@example.com")
    try await fixture.register(personal)

    try await fixture.registry.unregister(personal.accountID)
    // A retry after a teardown that failed part-way must not throw: the second
    // pass finds the entry gone and the directory already removed.
    try await fixture.registry.unregister(personal.accountID)

    #expect(try await fixture.registry.linkedAccounts().isEmpty)
  }

  @Test
  func `Registering an account that is already registered keeps its index and one entry`()
    async throws
  {
    let fixture = try AccountFixture.make()
    defer { fixture.tearDown() }
    let personal = try account(personalID, email: "franz@example.com")
    try await fixture.register(personal)

    var renamed = personal
    renamed.email = "franz@example.net"
    try await fixture.registry.register(renamed)

    #expect(try await fixture.registry.linkedAccounts() == [personal.accountID])
    #expect(
      try await fixture.registry.configuration(for: personal.accountID).email
        == "franz@example.net"
    )
    #expect(
      FileManager.default.fileExists(
        atPath: fixture.environment.indexURL(for: personal.accountID).path
      )
    )
  }
}

@Suite
struct `Which accounts can be authenticated` {
  @Test
  func `A keychain that can't be read fails the question rather than answering “no token”`()
    async throws
  {
    let fixture = try AccountFixture.make()
    defer { fixture.tearDown() }
    let personal = try account(personalID, email: "franz@example.com")
    try await fixture.register(personal)
    let manager = fixture.manager(
      tokenStore: StubTokenStore(readFailure: errSecInteractionNotAllowed)
    )

    // Answering with an empty list would read as "this account is no longer
    // linked", which is what makes the domain reconcile discard its replica.
    await #expect(throws: AuthenticationFailure.keychain(status: errSecInteractionNotAllowed)) {
      try await manager.authenticatableAccounts()
    }
    #expect(try await manager.linkedAccounts() == [personal.accountID])
  }

  @Test
  func `An account with no stored token is simply one this process can't act as`() async throws {
    let fixture = try AccountFixture.make()
    defer { fixture.tearDown() }
    let personal = try account(personalID, email: "franz@example.com")
    let work = try account(workID, email: "franz@acme.com")
    try await fixture.register(personal)
    try await fixture.register(work)
    let manager = fixture.manager(
      tokenStore: StubTokenStore(tokens: [personal.accountID: "refresh"])
    )

    #expect(try await manager.authenticatableAccounts() == [personal.accountID])
    #expect(try await manager.linkedAccounts().count == 2)
  }
}

@Suite
struct `Which account may complete a link` {
  @Test
  func `Adding an account refuses the one already linked, naming it`() async throws {
    let fixture = try AccountFixture.make()
    defer { fixture.tearDown() }
    let personal = try account(personalID, email: "franz@example.com")
    try await fixture.register(personal)
    let manager = fixture.manager(
      tokenStore: StubTokenStore(tokens: [personal.accountID: "refresh"])
    )

    // Dropbox approves as whoever the browser is signed in as, so pressing +
    // and approving again is the ordinary way a second account fails to be one.
    await #expect(throws: LinkRefusal.alreadyLinked(email: "franz@example.com")) {
      try await manager.confirm(
        try authorized(personalID, email: "franz@example.com"),
        satisfies: .newAccount
      )
    }
    try await manager.confirm(
      try authorized(workID, email: "franz@acme.com"),
      satisfies: .newAccount
    )
  }

  @Test
  func `An account the app linked is still one the CLI's own keychain may authorize`() async throws
  {
    let fixture = try AccountFixture.make()
    defer { fixture.tearDown() }
    let personal = try account(personalID, email: "franz@example.com")
    try await fixture.register(personal)
    let manager = fixture.manager(tokenStore: StubTokenStore())

    // The registry is shared between app and CLI; the keychains are not. Being
    // in the registry is therefore not, by itself, being linked here.
    try await manager.confirm(
      try authorized(personalID, email: "franz@example.com"),
      satisfies: .newAccount
    )
  }

  @Test
  func `A repair refuses any account but the one it is repairing, naming both`() async throws {
    let fixture = try AccountFixture.make()
    defer { fixture.tearDown() }
    let personal = try account(personalID, email: "franz@example.com")
    let work = try account(workID, email: "franz@acme.com")
    try await fixture.register(personal)
    try await fixture.register(work)
    let manager = fixture.manager(
      tokenStore: StubTokenStore(tokens: [personal.accountID: "refresh"])
    )

    // Repairing the work account by re-approving the healthy personal one would
    // otherwise overwrite the personal token and report the work one repaired.
    await #expect(
      throws: LinkRefusal.notTheAccountBeingRepaired(
        approved: "franz@example.com",
        repairing: "franz@acme.com"
      )
    ) {
      try await manager.confirm(
        try authorized(personalID, email: "franz@example.com"),
        satisfies: .repairing(work.accountID)
      )
    }
    try await manager.confirm(
      try authorized(workID, email: "franz@acme.com"),
      satisfies: .repairing(work.accountID)
    )
  }

  @Test
  func `A repair of an account whose configuration won't load names it by identifier`() async throws
  {
    let fixture = try AccountFixture.make()
    defer { fixture.tearDown() }
    let work = try AccountIdentifier(validating: workID)
    let manager = fixture.manager(tokenStore: StubTokenStore())

    // An unreadable configuration is exactly what one of the two relink
    // affordances repairs, so it must not leave the refusal with nothing to say.
    await #expect(
      throws: LinkRefusal.notTheAccountBeingRepaired(
        approved: "franz@example.com",
        repairing: workID
      )
    ) {
      try await manager.confirm(
        try authorized(personalID, email: "franz@example.com"),
        satisfies: .repairing(work)
      )
    }
  }

  @Test
  func `A link with no account in mind takes whichever one approves`() async throws {
    let fixture = try AccountFixture.make()
    defer { fixture.tearDown() }
    let personal = try account(personalID, email: "franz@example.com")
    try await fixture.register(personal)
    let manager = fixture.manager(
      tokenStore: StubTokenStore(tokens: [personal.accountID: "refresh"])
    )

    // `zephyr auth link` re-authorizing an account it linked is how a broken
    // CLI credential is replaced.
    try await manager.confirm(
      try authorized(personalID, email: "franz@example.com"),
      satisfies: .anyAccount
    )
  }
}
