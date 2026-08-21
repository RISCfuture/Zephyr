import Foundation
import GitHubUpdateChecker
import ZephyrCommon

/**
 Backs the shared Check for Updates command and the Settings ▸ Updates controls
 with the GitHub Releases API.

 Only this target links the checker. The App Store build is kept current by the
 store, so it injects no ``UpdateChecking`` at all and both surfaces disappear.
 */
@MainActor
final class GitHubUpdates: UpdateChecking {
  /// The repository whose releases this build is published from.
  private static let owner = "RISCfuture",
    repo = "Zephyr"

  private let checker = GitHubUpdateChecker(
    owner: GitHubUpdates.owner,
    repo: GitHubUpdates.repo
  )

  var canCheckForUpdates: Bool { checker.canCheckForUpdates }

  var lastCheckDate: Date? { checker.lastCheckDate }

  var cadence: UpdateCheckCadence {
    get { UpdateCheckCadence(checker.preferences.updateCadence) }
    set { checker.preferences.updateCadence = newValue.updateCadence }
  }

  /**
   Starts checking on the user's chosen cadence. The schedule is an in-process
   task, so it only runs while the app does.
   */
  func startAutomaticChecks() { checker.startAutomaticChecks() }

  func checkForUpdatesAndShowUI() async { await checker.checkForUpdatesAndShowUI() }
}

/**
 Translates between the shared UI's cadence and the checker's own. The two
 enumerate the same choices, but mapping the cases keeps the shared UI free of
 any dependency on the checker.
 */
extension UpdateCheckCadence {
  fileprivate var updateCadence: UpdateCadence {
    switch self {
      case .hourly: .hourly
      case .daily: .daily
      case .weekly: .weekly
      case .never: .never
    }
  }

  fileprivate init(_ cadence: UpdateCadence) {
    switch cadence {
      case .hourly: self = .hourly
      case .daily: self = .daily
      case .weekly: self = .weekly
      case .never: self = .never
    }
  }
}
