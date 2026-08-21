import SwiftUI
import ZephyrCommon

/**
 The Mac App Store build: sandboxed, kept current by the store, and shipping no
 command-line tool.

 Differs from the downloadable build only in the dependencies injected here —
 it passes no `UpdateChecking`, so the Check for Updates command and the
 Settings ▸ Updates controls point at the downloadable edition instead.

 The two editions build modules of the same name, so their entry points
 carry different type names: identically named ones would share a USR, and
 the dead-code check reads a single index built from both.
 */
@main
struct ZephyrMASApp: App {
  var body: some Scene {
    ZephyrScenes(featureFlags: FeatureFlags(isAppStoreBuild: true))
  }
}
