import Foundation
import Testing

@testable import libZephyr

@Suite
struct `Choosing an account for a shortcut` {
  @Test
  func `The only linked account is used without asking`() throws {
    let only = try shareAccount("First", id: Self.firstID)
    #expect(try IntentAccounts.resolve(nil, among: [only]) == only.accountID)
  }

  @Test
  func `A named account wins even when several are linked`() throws {
    let first = try shareAccount("First", id: Self.firstID)
    let second = try shareAccount("Second", id: Self.secondID)
    let resolved = try IntentAccounts.resolve(AccountEntity(second), among: [first, second])
    #expect(resolved == second.accountID)
  }

  @Test
  func `Several linked accounts and none named leaves the choice to be asked`() throws {
    let accounts = [
      try shareAccount("First", id: Self.firstID),
      try shareAccount("Second", id: Self.secondID)
    ]
    #expect(try IntentAccounts.resolve(nil, among: accounts) == nil)
  }

  @Test
  func `No linked account is reported, not guessed at`() throws {
    #expect(throws: ScriptingFailure.noAccountLinked) {
      try IntentAccounts.resolve(nil, among: [])
    }
  }

  @Test
  func `An item’s identity survives being written down and read back`() throws {
    let identity = DropboxItemID(
      account: try AccountIdentifier(validating: Self.firstID),
      item: try DropboxFileIdentifier(validating: "id:abc123")
    )
    #expect(DropboxItemID.entityIdentifier(for: identity.entityIdentifierString) == identity)
  }

  @Test(arguments: ["", "no-separator", "dbid:AAA", "notanaccount id:abc", "dbid:AAA notanitem"])
  func `An identity Zephyr didn’t write resolves to nothing`(_ stored: String) throws {
    #expect(DropboxItemID.entityIdentifier(for: stored) == nil)
  }
}

@Suite
struct `Reading a path somebody typed` {
  @Test(arguments: [
    ("/", ""),
    ("", ""),
    ("/Documents", "/Documents"),
    ("Documents", "/Documents"),
    ("/Documents/", "/Documents"),
    ("Documents/Taxes/", "/Documents/Taxes")
  ])
  func `A path a picker or a person offers resolves the way it reads`(
    _ typed: String,
    _ expected: String
  ) throws {
    #expect(try DropboxPath(userTyped: typed).rawValue == expected)
  }

  @Test
  func `Leniency doesn’t extend to a path that is actually malformed`() throws {
    #expect(throws: (any Error).self) { try DropboxPath(userTyped: "/Docs//report.txt") }
  }
}

extension `Choosing an account for a shortcut` {
  fileprivate static let firstID = "dbid:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA1"

  fileprivate static let secondID = "dbid:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA2"
}
