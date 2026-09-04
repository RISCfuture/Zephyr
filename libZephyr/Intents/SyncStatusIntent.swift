public import AppIntents
import Foundation

/// Reports what Zephyr's index says about an account, without asking Dropbox.
public struct SyncStatusIntent: AppIntent {
  /// The name Shortcuts lists this action under.
  public static let title = LocalizedStringResource("Get Sync Status", bundle: .libZephyr)

  // periphery:ignore - App Intents reads this out of the extracted metadata; it has a
  // default, so nothing in Zephyr calls it and the dead-code check can't see the system.
  /// What the action does, shown beneath its name.
  public static let description = IntentDescription(
    LocalizedStringResource(
      "Reports how much of a Dropbox account Zephyr has indexed, and anything it couldn’t sync.",
      bundle: .libZephyr
    )
  )

  /// Answered from the index alone, so it neither needs the app in front nor
  /// costs a round trip to Dropbox.
  public static let supportedModes: IntentModes = .background

  /// The account to report on, or nothing to take the only one linked.
  @Parameter(title: LocalizedStringResource("Account", bundle: .libZephyr))
  public var account: AccountEntity?

  public init() {}

  /// Reads the account's index and reports what it holds.
  public func perform() async throws -> some IntentResult & ReturnsValue<SyncStatusEntity>
    & ProvidesDialog
  {
    let entity = try await withIntentFailures {
      let service = SharedAccountService.shared
      let linked = try await service.scriptableAccounts()
      guard let accountID = try IntentAccounts.resolve(account, among: linked) else {
        throw $account.needsValueError(IntentAccounts.accountPrompt)
      }
      let configuration = try await service.configuration(for: accountID)
      return SyncStatusEntity(
        try await service.syncStatus(of: accountID),
        accountName: configuration.displayName
      )
    }
    return .result(value: entity, dialog: entity.summary)
  }
}

/// One account's sync state, as a shortcut reads it.
///
/// Transient because it has no identity to come back to: it is a reading taken
/// at a moment, not a thing in the account that a later shortcut could name.
public struct SyncStatusEntity: TransientAppEntity {
  /// The name Shortcuts gives this kind of value.
  public static let typeDisplayRepresentation = TypeDisplayRepresentation(
    name: LocalizedStringResource("Dropbox Sync Status", bundle: .libZephyr)
  )

  /// The account this reading is of.
  @Property(title: LocalizedStringResource("Account", bundle: .libZephyr))
  public var accountName: String

  /// Files the index holds.
  @Property(title: LocalizedStringResource("Files", bundle: .libZephyr))
  public var files: Int

  /// Folders the index holds.
  @Property(title: LocalizedStringResource("Folders", bundle: .libZephyr))
  public var folders: Int

  /// Items Dropbox and this Mac could not agree on.
  @Property(title: LocalizedStringResource("Sync Issues", bundle: .libZephyr))
  public var syncIssues: Int

  /// Whether Zephyr is still building its first picture of the account.
  @Property(title: LocalizedStringResource("Indexing", bundle: .libZephyr))
  public var isIndexing: Bool

  /// What stopped the account syncing, or nothing when it is running.
  @Property(title: LocalizedStringResource("Problem", bundle: .libZephyr))
  public var problem: String?

  public var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "\(accountName)")
  }

  /// The reading in a sentence, for the shortcut to speak or show.
  public var summary: IntentDialog {
    if let problem {
      return IntentDialog(LocalizedStringResource(stringLiteral: problem))
    }
    if isIndexing {
      return IntentDialog(
        LocalizedStringResource(
          "Zephyr is still indexing \(accountName): \(files, format: .number) files so far.",
          bundle: .libZephyr
        )
      )
    }
    return IntentDialog(
      LocalizedStringResource(
        """
        \(accountName) has \(files, format: .number) files in \(folders, format: .number) folders, \
        with \(syncIssues, format: .number) sync issues.
        """,
        bundle: .libZephyr
      )
    )
  }

  public init() {}

  /// Describes a reading of one account.
  public init(_ status: SyncStatus, accountName: String) {
    self.init()
    self.accountName = accountName
    files = Int(status.files)
    folders = Int(status.folders)
    syncIssues = Int(status.syncIssueCount)
    isIndexing = status.indexState != .complete
    problem = status.accountFailure.map { failure in
      [failure.title, failure.detail].compactMap(\.self).joined(separator: " ")
    }
  }
}
