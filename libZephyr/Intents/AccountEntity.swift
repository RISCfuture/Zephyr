import AppIntents
import Foundation

/// A linked Dropbox account, as a shortcut names one.
public struct AccountEntity: AppEntity {
  /// The name Shortcuts gives this kind of value.
  public static let typeDisplayRepresentation = TypeDisplayRepresentation(
    name: LocalizedStringResource("Dropbox Account", bundle: .libZephyr)
  )

  /// Where Shortcuts looks accounts up.
  public static let defaultQuery = AccountEntityQuery()

  /// The account's `dbid:` identifier.
  ///
  /// The raw string rather than ``AccountIdentifier`` itself: an entity's
  /// identity has to be `EntityIdentifierConvertible`, which the wrapper is
  /// not, and a validating accessor is less code than conforming it.
  public let id: String

  /// The account holder's name, as Dropbox reports it.
  public let displayName: String

  /// The account's email address, which is what tells two of them apart.
  public let email: String

  /// The identifier this entity names.
  ///
  /// - Throws: `IdentifierValidationFailure` when the stored string is not
  ///   one Zephyr wrote — a shortcut carried over from somewhere else.
  public var accountID: AccountIdentifier {
    get throws { try AccountIdentifier(validating: id) }
  }

  public var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "\(displayName)", subtitle: "\(email)")
  }

  /// Describes a linked account.
  public init(_ configuration: AccountConfiguration) {
    id = configuration.accountID.rawValue
    displayName = configuration.displayName
    email = configuration.email
  }
}

/// Finds the accounts a shortcut may act as.
public struct AccountEntityQuery: EntityQuery, EntityStringQuery {
  public init() {}

  /// The accounts named by these identifiers, leaving out any that are no
  /// longer linked — which reads to the reader as an account that has gone,
  /// rather than as a broken shortcut.
  public func entities(for identifiers: [String]) async throws -> [AccountEntity] {
    let linked = try await SharedAccountService.shared.scriptableAccounts()
    return identifiers.compactMap { identifier in
      linked.first { $0.accountID.rawValue == identifier }.map(AccountEntity.init)
    }
  }

  /// The accounts whose name or email address contains `string`, so somebody
  /// can type an address rather than reach for the picker.
  public func entities(matching string: String) async throws -> [AccountEntity] {
    try await SharedAccountService.shared.scriptableAccounts()
      .filter {
        $0.displayName.localizedStandardContains(string)
          || $0.email.localizedStandardContains(string)
      }
      .map(AccountEntity.init)
  }

  /// Every account a shortcut may act as.
  ///
  /// There is deliberately no `defaultResult()`. Offering the sole account
  /// there would write it into the saved shortcut, so linking a second account
  /// later would leave the shortcut still running against the first without
  /// saying so. Leaving the parameter empty is what keeps “the only account,
  /// unless you say otherwise” a question asked afresh every run.
  public func suggestedEntities() async throws -> [AccountEntity] {
    try await SharedAccountService.shared.scriptableAccounts().map(AccountEntity.init)
  }
}
