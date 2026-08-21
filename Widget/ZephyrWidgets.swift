import AppIntents
import SwiftUI
import WidgetKit
import libZephyr

@main
struct ZephyrWidgets: WidgetBundle {
  var body: some Widget {
    SyncStatusWidget()
    PauseSyncingControl()
  }

  init() {
    CrashReporting.start(as: .widget)
  }
}

/**
 The App Intents this extension carries up from `libZephyr`.

 App Intents metadata is extracted per target, and an intent defined in a
 framework is not in the extension's own bundle. Control Center runs
 `SetSyncPausedIntent` out of *this* bundle's metadata, so without this the
 toggle builds, installs, appears in the gallery, and does nothing.
 */
struct ZephyrWidgetsIntentsPackage: AppIntentsPackage {
  static var includedPackages: [any AppIntentsPackage.Type] {
    [ZephyrIntentsPackage.self]
  }
}
