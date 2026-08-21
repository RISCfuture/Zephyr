import Observation
import SwiftUI
import libZephyr

#if DEBUG
  /// Builds preview models with canned account data.
  @MainActor
  enum PreviewHelper {
    static var sampleAccounts: [AccountConfiguration] {
      [
        configuration(id: "dbid:preview-personal", email: "tim@example.com", name: "Tim Morgan"),
        configuration(
          id: "dbid:preview-work",
          email: "tim@work.example.com",
          name: "Tim Morgan (Work)"
        )
      ]
    }

    /// Two canned issues, so the sync-issues list has something to draw.
    static var sampleIssues: [SyncErrorRecord] {
      [
        issue(path: "/Movies/dive trip.mov", title: "Couldn’t upload the file."),
        issue(path: "/Projects/plan.key", title: "Couldn’t download the file.")
      ]
    }

    /**
     A model on canned data, in whichever edition the preview is showing.

     The editions differ only in what they inject, so a preview names the
     edition it means: the App Store build has no update checker, and the
     downloadable build has both a checker and the command-line tool.
     */
    static func model(
      accounts: [AccountConfiguration] = [],
      withheldApprovals: [SystemApproval] = [],
      updates: (any UpdateChecking)? = nil,
      isAppStoreBuild: Bool = false
    ) -> AppModel {
      let model = AppModel(
        featureFlags: FeatureFlags(isAppStoreBuild: isAppStoreBuild),
        updates: updates,
        usesSampleAccounts: true
      )
      model.accounts = accounts
      model.accountStatuses = sampleStatuses(for: accounts)
      model.withheldApprovals = withheldApprovals
      return model
    }

    static func sampleStatuses(
      for accounts: [AccountConfiguration]
    ) -> [AccountIdentifier: AppModel.AccountStatus] {
      let samples = [
        AppModel.AccountStatus(
          files: 6754,
          folders: 593,
          latestChange: Date(timeIntervalSinceNow: -70)
        ),
        AppModel.AccountStatus(
          files: 1204,
          folders: 88,
          syncErrors: sampleIssues,
          latestChange: Date(timeIntervalSinceNow: -3600 * 5)
        )
      ]
      return Dictionary(
        uniqueKeysWithValues: zip(accounts.map(\.accountID), samples)
      )
    }

    // The paths are fixed literals from this file, so a validation failure is
    // a typo in the sample data.
    private static func issue(path: String, title: String) -> SyncErrorRecord {
      // swiftlint:disable:next force_try
      let dropboxPath = try! DropboxPath(validating: path)
      return SyncErrorRecord(
        pathNormalized: dropboxPath.normalized,
        path: dropboxPath,
        title: title,
        detail: "Your Dropbox is out of space."
      )
    }

    // The identifiers are fixed literals from this file, so a validation
    // failure is a typo in the sample data rather than a runtime condition —
    // and one that any preview render or UI-test launch trips immediately.
    private static func configuration(id: String, email: String, name: String)
      -> AccountConfiguration
    {
      AccountConfiguration(
        // swiftlint:disable:next force_try
        accountID: try! AccountIdentifier(validating: id),
        email: email,
        displayName: name,
        // swiftlint:disable:next force_try
        rootNamespaceID: try! NamespaceIdentifier(validating: "1234567890")
      )
    }
  }

  /**
   An update checker on canned data, so the downloadable edition's update
   controls have something to draw.

   The real checker lives in the downloadable build's own target; a preview
   here reaches its UI without linking the update library.
   */
  @MainActor
  @Observable
  final class PreviewUpdates: UpdateChecking {
    var cadence: UpdateCheckCadence = .daily
    let canCheckForUpdates = true
    let lastCheckDate: Date? = Date(timeIntervalSinceNow: -3600 * 2)

    // A preview has no update to offer, but ``UpdateChecking`` asks for this.
    // swiftlint:disable:next async_without_await
    func checkForUpdatesAndShowUI() async {}
  }
#endif
