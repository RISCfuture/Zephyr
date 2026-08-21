import AppIntents
import Foundation

/// Puts a Dropbox file back to one of the earlier versions Dropbox kept.
struct RestoreRevisionIntent: AppIntent {
  /// The name Shortcuts lists this action under.
  static let title = LocalizedStringResource("Restore Dropbox File", bundle: .libZephyr)

  // periphery:ignore - App Intents reads this out of the extracted metadata; it has a
  // default, so nothing in Zephyr calls it and the dead-code check can't see the system.
  /// What the action does, shown beneath its name.
  static let description = IntentDescription(
    LocalizedStringResource(
      "Puts a Dropbox file back to an earlier version.",
      bundle: .libZephyr
    )
  )

  static let supportedModes: IntentModes = .background

  /// The file to put back. It carries its own account.
  @Parameter(title: LocalizedStringResource("File", bundle: .libZephyr))
  var item: DropboxItemEntity

  /// Which stored version to go back to.
  @Parameter(
    title: LocalizedStringResource("Version", bundle: .libZephyr),
    optionsProvider: FileRevisionOptions()
  )
  var revision: String

  init() {}

  /**
   Restores the file, having asked first.

   Restoring is the one action here the reader cannot undo by running it
   again: whatever the file says now stops being what it says. A shortcut can
   fire while nobody is watching, so this one asks before it does that.
   */
  func perform() async throws -> some IntentResult & ReturnsValue<DropboxItemEntity>
    & ProvidesDialog
  {
    try await requestConfirmation(
      dialog: IntentDialog(
        LocalizedStringResource(
          "Restore “\(item.name)” to an earlier version?",
          bundle: .libZephyr
        )
      )
    )
    let restored = try await withIntentFailures {
      let service = SharedAccountService.shared
      let configuration = try await service.configuration(for: item.id.account)
      let metadata = try await service.restore(
        try DropboxPath(userTyped: item.path),
        to: try FileRevision(validating: revision),
        in: item.id.account
      )
      return DropboxItemEntity(metadata, in: configuration)
    }
    return .result(
      value: restored,
      dialog: IntentDialog(
        LocalizedStringResource("Restored “\(restored.name)”.", bundle: .libZephyr)
      )
    )
  }
}

/// The versions Dropbox is holding of the chosen file.
struct FileRevisionOptions: DynamicOptionsProvider {
  @IntentParameterDependency<RestoreRevisionIntent>(\.$item)
  private var restoring

  init() {}

  /// Each stored version, titled by when Dropbox recorded it — a revision's
  /// own identifier is a hash nobody could choose between.
  func results() async throws -> ItemCollection<String> {
    guard let item = restoring?.item else { return ItemCollection(sections: []) }
    let revisions = try await SharedAccountService.shared.revisions(
      of: item.id.item,
      in: item.id.account,
      limit: AccountSession.defaultRevisionLimit
    )
    let items = revisions.map { revision in
      IntentItem<String>(
        revision.rev.rawValue,
        title: LocalizedStringResource(
          stringLiteral: revision.serverModified.formatted(date: .abbreviated, time: .shortened)
        ),
        subtitle: LocalizedStringResource(
          stringLiteral: revision.size.formatted(.byteCount(style: .file))
        )
      )
    }
    return ItemCollection(sections: [IntentItemSection(items: items)])
  }
}
