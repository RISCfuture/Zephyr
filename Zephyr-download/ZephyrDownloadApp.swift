import SwiftUI
import ZephyrCommon

/**
 The Developer ID build: notarized, published as a disk image on a GitHub
 release, and responsible for keeping itself current.

 Differs from the Mac App Store build only in the dependencies injected here —
 it embeds the `zephyr` command-line tool and passes an ``UpdateChecking``, so
 the Check for Updates command and the Settings ▸ Updates controls appear.

 The two editions build modules of the same name, so their entry points
 carry different type names: identically named ones would share a USR, and
 the dead-code check reads a single index built from both.
 */
@main
struct ZephyrDownloadApp: App {
  private let updates = GitHubUpdates()

  var body: some Scene {
    ZephyrScenes(featureFlags: FeatureFlags(isAppStoreBuild: false), updates: updates)
  }

  init() {
    updates.startAutomaticChecks()
  }
}
