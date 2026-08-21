import AppIntents
import ZephyrCommon
import libZephyr

/**
 The App Intents this edition ships.

 App Intents metadata is extracted per target, and a framework's does not
 reach the app that links it on its own. Naming `ZephyrCommonIntentsPackage`
 here is what pulls the whole chain — `ZephyrCommon`, and `libZephyr` beneath
 it — into this app's own metadata.

 The two editions build modules of the same name, so this type and the
 downloadable edition's carry different names for the same reason their entry
 points do: identically named ones would share a USR, and the dead-code check
 reads a single index built from both.
 */
struct ZephyrMASIntentsPackage: AppIntentsPackage {
  static var includedPackages: [any AppIntentsPackage.Type] {
    [ZephyrCommonIntentsPackage.self]
  }
}

/**
 The actions macOS offers without being asked: in Spotlight, in the Shortcuts
 app's App Shortcuts list, and to Siri.

 The three that answer a question about Zephyr itself, rather than reaching
 into a Dropbox. An App Shortcut runs with whatever it was given and no
 chance to ask, so an action needing a file or a folder chosen first belongs
 in a shortcut somebody built, not on this list.
 */
struct ZephyrMASShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: PauseSyncingIntent(),
      phrases: ["Pause syncing in \(.applicationName)"],
      shortTitle: "Pause Syncing",
      systemImageName: "pause.circle"
    )
    AppShortcut(
      intent: SnoozeNotificationsIntent(),
      phrases: ["Snooze \(.applicationName) notifications"],
      shortTitle: "Snooze Notifications",
      systemImageName: "bell.slash"
    )
    AppShortcut(
      intent: SyncStatusIntent(),
      phrases: ["Check \(.applicationName) sync status"],
      shortTitle: "Sync Status",
      systemImageName: "arrow.trianglehead.2.clockwise"
    )
  }
}
