public import AppIntents
import Foundation

/**
 Finds the Dropbox items a shortcut can name.

 Every answer comes out of the sync index, which describes the whole account
 rather than the bytes on this disk — so a folder nothing has ever downloaded
 is offered, and resolves, exactly like one that is fully materialized. That
 is the thing a client searching a local folder could not do.

 Answers arrive in a section per account, because an item's account is part of
 which item it is: two Dropboxes can each hold a `/Documents`, and a list
 showing both without saying which is which would be asking the reader to
 guess.
 */
public struct DropboxItemQuery: EntityStringQuery {
  /// How many items one account contributes to a search.
  private static let matchesPerAccount: UInt = 25

  /// How many items one account contributes to the opening picker.
  private static let suggestionsPerAccount = 100

  public init() {}

  /// Builds one section per account from whatever `records` finds in each.
  private static func collection(
    _ records: (AccountIdentifier) async throws -> [IndexEntryRecord]
  ) async throws -> IntentItemCollection<DropboxItemEntity> {
    var sections: [IntentItemSection<DropboxItemEntity>] = []
    for configuration in try await SharedAccountService.shared.scriptableAccounts() {
      let found = try await records(configuration.accountID)
      guard !found.isEmpty else { continue }
      sections.append(
        IntentItemSection(
          LocalizedStringResource(stringLiteral: configuration.displayName),
          items: found.map { DropboxItemEntity($0, in: configuration) }
        )
      )
    }
    return IntentItemCollection(sections: sections)
  }

  /// The items these identities name, leaving out any the index no longer
  /// holds — which reads as an item that has gone, rather than as a broken
  /// shortcut.
  public func entities(for identifiers: [DropboxItemID]) async throws -> [DropboxItemEntity] {
    var found: [DropboxItemEntity] = []
    for (account, identities) in Dictionary(grouping: identifiers, by: \.account) {
      guard let configuration = try? await SharedAccountService.shared.configuration(for: account)
      else {
        continue
      }
      for identity in identities {
        let record = try await SharedAccountService.shared.indexedItem(identity.item, in: account)
        guard let record else { continue }
        found.append(DropboxItemEntity(record, in: configuration))
      }
    }
    return found
  }

  /**
   The items matching what somebody typed.

   A string beginning with `/` is tried as a path first and put at the front
   when it names something: somebody who typed a whole path meant that item,
   not everything sharing a word with it.
   */
  public func entities(
    matching string: String
  ) async throws -> IntentItemCollection<DropboxItemEntity> {
    try await Self.collection { account in
      var records: [IndexEntryRecord] = []
      if string.hasPrefix("/"), let path = try? DropboxPath(userTyped: string),
        let exact = try await SharedAccountService.shared.indexedItem(atPath: path, in: account)
      {
        records.append(exact)
      }
      let named = try await SharedAccountService.shared.indexedItems(
        named: string,
        in: account,
        limit: Self.matchesPerAccount
      )
      records.append(
        contentsOf: named.filter { candidate in
          !records.contains { $0.dbxID == candidate.dbxID }
        }
      )
      return records
    }
  }

  /// What the picker opens on: each account's top level.
  public func suggestedEntities() async throws -> IntentItemCollection<DropboxItemEntity> {
    try await Self.collection { account in
      Array(
        try await SharedAccountService.shared.topLevelItems(in: account).prefix(
          Self.suggestionsPerAccount
        )
      )
    }
  }
}
