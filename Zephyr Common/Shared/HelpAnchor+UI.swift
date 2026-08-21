import AppKit
import libZephyr

extension HelpAnchor {

  /**
   The help book this app bundle registered, read from `Info.plist` rather
   than written here.

   `Bundle.main` is the app — never `ZephyrCommon.framework`, which ships no
   book of its own, and never an extension, which doesn't open help.
   */
  private static var bookName: NSHelpManager.BookName? {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleHelpBookName") as? NSHelpManager.BookName
  }

  /**
   What a control pointing here is about, for VoiceOver and the tooltip.

   `HelpLink` labels itself "Help" and offers no way to say more, which in a
   settings window with eight of them means eight identical buttons with
   nothing to tell them apart. Each label is a whole sentence rather than
   "Help with" plus a noun, because the preposition inflects in languages that
   decline.
   */
  var accessibilityLabel: String {
    switch self {
      case .whereFilesLive:
        String(
          localized: "Help with where your files are kept",
          bundle: #bundle,
          comment: "Help button label"
        )
      case .linkAccount:
        String(
          localized: "Help with linking a Dropbox account",
          bundle: #bundle,
          comment: "Help button label"
        )
      case .settingsGeneral:
        String(
          localized: "Help with keeping Zephyr running",
          bundle: #bundle,
          comment: "Help button label"
        )
      case .settingsNotifications:
        String(localized: "Help with notifications", bundle: #bundle, comment: "Help button label")
      case .settingsBandwidth:
        String(
          localized: "Help with transfer limits",
          bundle: #bundle,
          comment: "Help button label"
        )
      case .ignoredItems:
        String(
          localized: "Help with items that aren’t syncing",
          bundle: #bundle,
          comment: "Help button label"
        )
      case .diagnostics:
        String(
          localized: "Help with diagnostic reports",
          bundle: #bundle,
          comment: "Help button label"
        )
      case .commandLineTool:
        String(
          localized: "Help with the command-line tool",
          bundle: #bundle,
          comment: "Help button label"
        )
      case .automateWithShortcuts:
        String(
          localized: "Help with using Zephyr in a shortcut",
          bundle: #bundle,
          comment: "Help button label"
        )
      case .settingsUpdates:
        String(localized: "Help with update checks", bundle: #bundle, comment: "Help button label")
      case .withheldApproval:
        String(
          localized: "Help with granting what Zephyr needs",
          bundle: #bundle,
          comment: "Help button label"
        )
      case .syncIssues:
        String(
          localized: "Help with items that couldn’t sync",
          bundle: #bundle,
          comment: "Help button label"
        )
      case .reauthorize:
        String(
          localized: "Help with reconnecting a Dropbox account",
          bundle: #bundle,
          comment: "Help button label"
        )
      case .dropboxNotInFinder:
        String(
          localized: "Help with a Dropbox that isn’t in Finder",
          bundle: #bundle,
          comment: "Help button label"
        )
      case .notificationsDenied:
        String(
          localized: "Help with notifications that don’t arrive",
          bundle: #bundle,
          comment: "Help button label"
        )
      case .commandLineToolInstall:
        String(
          localized: "Help with installing the command-line tool",
          bundle: #bundle,
          comment: "Help button label"
        )
    }
  }

  /**
   Opens the help book at this topic.

   For the affordances a `HelpLink` can't be: one that has to read as a
   sentence rather than a question mark, and one that sits inline against a
   line of caption-sized text. A pane with room for the real system control
   uses ``HelpTopicLink``.
   */
  @MainActor
  func open() {
    NSHelpManager.shared.openHelpAnchor(rawValue, inBook: Self.bookName)
  }
}
