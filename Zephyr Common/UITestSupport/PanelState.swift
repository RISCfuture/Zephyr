#if DEBUG
  import Foundation
  import libZephyr

  /**
   One arrangement of the menu-bar panel, staged on canned data.

   The panel's whole job is to say what is happening, and most of what can
   happen is something this Mac cannot be asked to do on cue: join a hotspot,
   lose its route, have an approval withheld, have Dropbox revoke a token. Each
   case here is one of those, described rather than provoked, so a preview can
   be looked at and a screenshot can be taken of it.

   Nothing is stubbed to achieve this. Every case sets fields ``AppModel``
   already publishes, and a canned-data launch never calls the system APIs that
   would otherwise fill them — so what is staged is what the real reading would
   have been, arriving by a shorter road.
   */
  @MainActor
  enum PanelState: String, CaseIterable {
    /// Two healthy accounts, one of them with changes waiting to go out.
    case sending
    /// A path macOS reads as expensive, which Zephyr's own setting can overrule.
    case metered
    /// Low Data Mode, which it cannot.
    case lowDataMode = "low-data-mode"
    /// A route that has just gone, which is not yet worth calling trouble.
    case offline
    /// A route gone long enough to name.
    case unreachable
    /// All three approvals withheld at once, of which the panel should list
    /// the one that actually stops Zephyr working.
    case withheldApprovals = "withheld-approvals"
    /// Every transfer stopped by the user.
    case paused
    /// A token Dropbox revoked, which linking again is what clears.
    case accountFailure = "account-failure"
    /// Items that couldn't sync.
    case syncIssues = "sync-issues"

    /// Arranges `model` to read this way. The accounts are already canned; this
    /// is what happened to them.
    func stage(_ model: AppModel) {
      clearIssuesUnlessTheyAreTheSubject(in: model)
      switch self {
        case .sending:
          model.pendingChanges = [model.accounts[0].accountID: 128]
        case .metered:
          model.networkConditions = NetworkConditions(isExpensive: true)
          model.pendingChanges = [model.accounts[0].accountID: 128]
        case .lowDataMode:
          model.networkConditions = NetworkConditions(isConstrained: true)
          model.pendingChanges = [model.accounts[0].accountID: 128]
        case .offline:
          // Short of the wait a row is raised for: the panel should say
          // nothing at all, which is itself worth photographing.
          outage(in: model, lasting: 30)
        case .unreachable:
          outage(in: model, lasting: 20 * 60)
        case .withheldApprovals:
          model.withheldApprovals = [.finderExtension, .notifications, .loginItem]
        case .paused:
          Task { await model.setSyncPaused(true) }
        case .accountFailure:
          revokeFirstAccount(in: model)
        case .syncIssues:
          break  // The second canned account already carries two.
      }
    }

    /**
     Takes the canned accounts' sync errors away from every state but the one
     they are the subject of.

     Issues outrank every other reading, and rightly: they outlast an outage and
     still want the user. But that makes them a backdrop nothing else can be
     photographed against — a Mac staged as unreachable, or as holding back on a
     hotspot, would be captured under a header saying "Sync issues" and the state
     under test would appear nowhere in its own picture.
     */
    private func clearIssuesUnlessTheyAreTheSubject(in model: AppModel) {
      guard self != .syncIssues else { return }
      for account in model.accounts.map(\.accountID) {
        model.accountStatuses[account]?.syncErrors = []
      }
    }

    /// Dates every account's outage far enough back for the panel to read it as
    /// one wait rather than as several — the Mac's route, not one Dropbox's.
    private func outage(in model: AppModel, lasting seconds: TimeInterval) {
      let since = Date(timeIntervalSinceNow: -seconds)
      for account in model.accounts.map(\.accountID) {
        model.accountStatuses[account]?.offlineSince = since
      }
    }

    /// Stops the first account the way a revoked authorization stops one, so
    /// the panel offers the way back.
    private func revokeFirstAccount(in model: AppModel) {
      guard let account = model.accounts.first?.accountID else { return }
      model.accountStatuses[account]?.accountFailure = AppModel.AccountFailure(
        AuthenticationFailure.tokenRevoked
      )
    }
  }
#endif
