import SwiftUI
import libZephyr

/// The Dropbox link, which everything after it depends on.
struct AccountStep: View {
  @Environment(AppModel.self)
  private var model

  var body: some View {
    SetupPageLayout(
      title: LocalizedStringResource("Link Your Dropbox Account", bundle: #bundle),
      message: LocalizedStringResource(
        "Zephyr signs in through Dropbox itself, so your password never reaches it.",
        bundle: #bundle
      )
    ) {
      if model.accounts.isEmpty {
        LinkAccountForm()
      } else {
        LinkedAccountsView(accounts: model.accounts)
      }
    } status: {
      ApprovalStatusView(
        isGranted: !model.accounts.isEmpty,
        waiting: LocalizedStringResource("Not linked yet", bundle: #bundle),
        granted: LocalizedStringResource(
          "Linked. You can add more accounts later from the Account menu.",
          bundle: #bundle
        ),
        helpAnchor: .linkAccount
      )
    }
  }
}

/// The accounts linked so far, once at least one is.
private struct LinkedAccountsView: View {
  private static let markSize: CGFloat = 17

  let accounts: [AccountConfiguration]

  var body: some View {
    VStack(alignment: .leading, spacing: SetupMetrics.betweenRows) {
      ForEach(accounts, id: \.accountID) { account in
        Label {
          VStack(alignment: .leading, spacing: Metrics.tight) {
            Text(account.displayName)
            Text(account.email)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        } icon: {
          ZephyrMark(size: Self.markSize)
        }
      }
    }
  }
}

#if DEBUG
  #Preview("Account — not linked") {
    AccountStep()
      .environment(PreviewHelper.model())
      .inSetupWindow()
  }

  #Preview("Account — linked") {
    AccountStep()
      .environment(PreviewHelper.model(accounts: PreviewHelper.sampleAccounts))
      .inSetupWindow()
  }
#endif
