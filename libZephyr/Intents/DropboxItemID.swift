import AppIntents
import Foundation

/**
 A Dropbox item's identity in a shortcut: the account holding it, and
 Dropbox's own identifier for it.

 Both halves are needed. A query is handed nothing but these identifiers when
 it reopens a saved shortcut, and Zephyr can have several accounts linked, so
 an identity without an account names an item in no particular Dropbox.

 The identifier rather than the path, so a shortcut saved today still means
 the same file after somebody renames or moves it. An item deleted and made
 again at the same path resolves to nothing, which is the honest answer: it
 is not the file the shortcut was pointed at.
 */
public struct DropboxItemID: Hashable, Sendable {
  /// The account holding the item.
  public let account: AccountIdentifier

  /// Dropbox's identifier for the item.
  public let item: DropboxFileIdentifier

  /// Names an item in an account.
  public init(account: AccountIdentifier, item: DropboxFileIdentifier) {
    self.account = account
    self.item = item
  }
}

extension DropboxItemID: EntityIdentifierConvertible {
  /// The two identifiers, space-separated. Neither carries a space — each is
  /// a fixed prefix followed by URL-safe characters — which is what makes one
  /// separator enough.
  public var entityIdentifierString: String { "\(account.rawValue) \(item.rawValue)" }

  /// Reads back what ``entityIdentifierString`` wrote.
  ///
  /// - Parameter entityIdentifierString: The stored identity.
  /// - Returns: The identity, or `nil` for a string Zephyr did not write —
  ///   which the query reports as an item that is no longer there, the same
  ///   answer it gives for one that has genuinely gone.
  public static func entityIdentifier(for entityIdentifierString: String) -> Self? {
    let halves = entityIdentifierString.split(separator: " ", maxSplits: 1)
    guard halves.count == 2,
      let account = try? AccountIdentifier(validating: String(halves[0])),
      let item = try? DropboxFileIdentifier(validating: String(halves[1]))
    else { return nil }
    return Self(account: account, item: item)
  }
}
