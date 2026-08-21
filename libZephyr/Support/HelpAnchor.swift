import Foundation

/**
 A named place in Zephyr's help book.

 Every help affordance names one of these rather than a bare string. The
 anchors themselves are `<a name="…">` elements in the HTML under
 `Help/Zephyr.help`, and nothing at compile time can catch a typo: a misspelled
 anchor doesn't fail, it silently opens the book's first page instead of the
 topic the user asked for — the kind of wrongness nobody bothers to report.
 Naming them once here is what lets `Scripts/build-help-book.sh` check each one
 against the book it is about to ship, and fail the build when the two
 disagree.

 Each anchor is a whole page. The book's search index records one target per
 page, so an anchor part-way down a page is reachable by an in-page link but
 not by a ``HelpAnchor`` — which is Apple's own practice in its user guides,
 not a limitation worked around.

 The raw values name the *concept* rather than the control that points at one,
 so moving a setting never invalidates an anchor and two surfaces asking the
 same question can share one. They are identifiers, not prose, and are never
 translated — a localized book repeats these same names in every `.lproj`.

 This sits beside the errors that name it rather than beside the views because
 `libZephyr` compiles into `zephyr-cli` and all three extensions, and an AppKit
 dependency here would not. Opening a book is a `Zephyr Common` concern;
 knowing which page to ask for is not.
 */
public enum HelpAnchor: String, Sendable {

  // MARK: - Getting started

  /// What appears in Finder, and what is actually on the disk.
  case whereFilesLive = "where-files-live"

  /// Linking a Dropbox account, and unlinking one.
  case linkAccount = "link-account"

  // MARK: - Settings

  /// Keeping Zephyr running, so Finder hears about remote changes.
  case settingsGeneral = "settings-general"

  /// Which sync events notify, and the snooze.
  case settingsNotifications = "settings-notifications"

  /// The Mac's transfer limits, and what happens on a metered network.
  case settingsBandwidth = "settings-bandwidth"

  /// The items taken out of syncing, and putting one back.
  case ignoredItems = "ignored-items"

  /// Collecting what a bug report needs.
  case diagnostics = "diagnostics"

  /// Installing and using the `zephyr` command-line tool.
  case commandLineTool = "zephyr-cli"

  /// Zephyr's actions in Shortcuts, Spotlight, and Siri.
  case automateWithShortcuts = "automate-shortcuts"

  /// Update checks, and which edition makes them.
  case settingsUpdates = "settings-updates"

  // MARK: - Topics a problem names

  /// The approvals macOS withholds, and where each is granted.
  case withheldApproval = "withheld-approval"

  /// Reading the items that couldn't sync, and clearing them.
  case syncIssues = "sync-issues"

  /// A revoked authorization, or Dropbox gone quiet.
  case reauthorize = "reauthorize"

  /// A linked account that never reaches the Finder sidebar.
  case dropboxNotInFinder = "dropbox-not-in-finder"

  /// Notifications that never arrive: denied, silenced, or snoozed.
  case notificationsDenied = "notifications-denied"

  /// When the command-line tool's symlink can't be made.
  case commandLineToolInstall = "cli-install"
}
