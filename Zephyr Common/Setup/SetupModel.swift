import Foundation
import Observation

/// First-run setup's own state: which page is showing, and what macOS has
/// granted so far, so each page can report whether its request has landed.
@MainActor
@Observable
final class SetupModel {
  /// The page on screen.
  private(set) var step: SetupStep = .welcome

  /// The approvals macOS is granting right now.
  private(set) var grantedApprovals: Set<SystemApproval> = []

  /// Whether the user has already answered the notification prompt. Once they
  /// have, macOS never shows it again, so setup must send them to System
  /// Settings instead of asking a second time.
  private(set) var hasAnsweredNotificationPrompt = false

  /// Why registering the login item failed, or `nil` when it hasn't.
  private(set) var loginItemFailure: String?

  /// Whether this launch keeps the approvals it was given rather than reading
  /// the ones macOS has granted. The screenshot suite walks setup on a
  /// developer's Mac, where half of them are already granted and the
  /// notification prompt has long since been answered — every page would
  /// report that machine's history instead of a first run.
  private let usesCannedApprovals: Bool

  var canGoBack: Bool { step.previous != nil }

  var isOnLastStep: Bool { step.next == nil }

  /**
   Starts setup on a given page, with a given set of approvals already granted
   and a given answer already given to the notification prompt.

   The defaults are the real first run; naming a page and the state it is in is
   how previews and tests reach a page in the middle without walking there, and
   how they reach the branch a Mac that has already answered macOS shows.
   */
  init(
    step: SetupStep = .welcome,
    grantedApprovals: Set<SystemApproval> = [],
    hasAnsweredNotificationPrompt: Bool = false,
    usesCannedApprovals: Bool = false
  ) {
    self.step = step
    self.grantedApprovals = grantedApprovals
    self.hasAnsweredNotificationPrompt = hasAnsweredNotificationPrompt
    self.usesCannedApprovals = usesCannedApprovals
  }

  func advance() {
    guard let next = step.next else { return }
    step = next
  }

  func goBack() {
    guard let previous = step.previous else { return }
    step = previous
  }

  func isGranted(_ approval: SystemApproval) -> Bool {
    grantedApprovals.contains(approval)
  }

  /// Re-reads every approval, unless this launch was handed a canned set.
  /// Setup calls this whenever it returns to the front, since these are
  /// granted in System Settings rather than in Zephyr.
  func refreshApprovals() async {
    guard !usesCannedApprovals else { return }
    var granted: Set<SystemApproval> = []
    for approval in SystemApproval.allCases where await SystemApprovalAudit.isGranted(approval) {
      granted.insert(approval)
    }
    grantedApprovals = granted
    hasAnsweredNotificationPrompt = await SystemApprovalAudit.hasAnsweredNotificationPrompt()
  }

  /// Shows macOS's notification prompt, then records what it decided.
  func allowNotifications() async {
    _ = await SystemApprovalAudit.requestNotificationAuthorization()
    await refreshApprovals()
  }

  /// Registers the login item, reporting a refusal rather than failing quietly.
  func openAtLogin() async {
    do {
      try LaunchAtLogin.setEnabled(true)
      loginItemFailure = nil
    } catch {
      loginItemFailure = AppModel.alertText(for: error)
    }
    await refreshApprovals()
  }
}
