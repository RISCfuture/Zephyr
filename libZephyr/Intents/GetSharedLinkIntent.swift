import AppIntents
import Foundation

/**
 Answers with a Dropbox share link for an item.

 The link is returned rather than put on the clipboard. Shortcuts already has
 a Copy to Clipboard action to follow this one with, and an unattended
 automation that replaced the clipboard without being asked would be taking
 something the reader was in the middle of using.
 */
struct GetSharedLinkIntent: AppIntent {
  /// The name Shortcuts lists this action under.
  static let title = LocalizedStringResource("Get Dropbox Share Link", bundle: .libZephyr)

  // periphery:ignore - App Intents reads this out of the extracted metadata; it has a
  // default, so nothing in Zephyr calls it and the dead-code check can't see the system.
  /// What the action does, shown beneath its name.
  static let description = IntentDescription(
    LocalizedStringResource(
      "Gets a link to a Dropbox file or folder, making one if it doesn’t already have one.",
      bundle: .libZephyr
    )
  )

  static let supportedModes: IntentModes = .background

  /// The item to link to. It carries its own account, so this action does not
  /// ask which Dropbox a second time.
  @Parameter(title: LocalizedStringResource("Item", bundle: .libZephyr))
  var item: DropboxItemEntity

  init() {}

  /// Answers with the item's share link.
  func perform() async throws -> some IntentResult & ReturnsValue<URL> & ProvidesDialog {
    let link = try await withIntentFailures {
      let path = try DropboxPath(userTyped: item.path)
      return try await SharedAccountService.shared.sharedLink(
        for: path,
        in: item.id.account
      )
    }
    return .result(
      value: link.url,
      dialog: IntentDialog(
        LocalizedStringResource("Here’s a link to “\(item.name)”.", bundle: .libZephyr)
      )
    )
  }
}
