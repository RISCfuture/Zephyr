import Foundation
import Testing

@testable import libZephyr

@Suite("Choosing an account for a shortcut")
struct IntentAccountTests {
  @Test("The only linked account is used without asking")
  func takesTheSoleAccount() throws {
    let only = try shareAccount("First", id: Self.firstID)
    #expect(try IntentAccounts.resolve(nil, among: [only]) == only.accountID)
  }

  @Test("A named account wins even when several are linked")
  func prefersTheNamedAccount() throws {
    let first = try shareAccount("First", id: Self.firstID)
    let second = try shareAccount("Second", id: Self.secondID)
    let resolved = try IntentAccounts.resolve(AccountEntity(second), among: [first, second])
    #expect(resolved == second.accountID)
  }

  @Test("Several linked accounts and none named leaves the choice to be asked")
  func defersWhenSeveralAreLinked() throws {
    let accounts = [
      try shareAccount("First", id: Self.firstID),
      try shareAccount("Second", id: Self.secondID)
    ]
    #expect(try IntentAccounts.resolve(nil, among: accounts) == nil)
  }

  @Test("No linked account is reported, not guessed at")
  func reportsNoLinkedAccount() throws {
    #expect(throws: ScriptingFailure.noAccountLinked) {
      try IntentAccounts.resolve(nil, among: [])
    }
  }

  @Test("An item’s identity survives being written down and read back")
  func roundTripsAnItemIdentity() throws {
    let identity = DropboxItemID(
      account: try AccountIdentifier(validating: Self.firstID),
      item: try DropboxFileIdentifier(validating: "id:abc123")
    )
    #expect(DropboxItemID.entityIdentifier(for: identity.entityIdentifierString) == identity)
  }

  @Test(
    "An identity Zephyr didn’t write resolves to nothing",
    arguments: ["", "no-separator", "dbid:AAA", "notanaccount id:abc", "dbid:AAA notanitem"]
  )
  func rejectsAnIdentityItDidNotWrite(_ stored: String) throws {
    #expect(DropboxItemID.entityIdentifier(for: stored) == nil)
  }
}

@Suite("Reading a path somebody typed")
struct UserTypedPathTests {
  @Test(
    "A path a picker or a person offers resolves the way it reads",
    arguments: [
      ("/", ""),
      ("", ""),
      ("/Documents", "/Documents"),
      ("Documents", "/Documents"),
      ("/Documents/", "/Documents"),
      ("Documents/Taxes/", "/Documents/Taxes")
    ]
  )
  func acceptsWhatAPersonWouldWrite(_ typed: String, _ expected: String) throws {
    #expect(try DropboxPath(userTyped: typed).rawValue == expected)
  }

  @Test("Leniency doesn’t extend to a path that is actually malformed")
  func stillRefusesAMalformedPath() throws {
    #expect(throws: (any Error).self) { try DropboxPath(userTyped: "/Docs//report.txt") }
  }
}

extension IntentAccountTests {
  fileprivate static let firstID = "dbid:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA1"

  fileprivate static let secondID = "dbid:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA2"
}
