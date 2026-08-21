import SwiftUI
import libZephyr

/// The last page: where Zephyr went, and how to get to the files.
struct ReadyStep: View {
  @Environment(AppModel.self)
  private var model

  var body: some View {
    SetupBookendPage(
      title: LocalizedStringResource("Zephyr Is Ready", bundle: #bundle),
      message: LocalizedStringResource(
        "Zephyr runs in the menu bar — its mark reads what’s syncing. Your Dropbox is in Finder, and files download when you open them.",
        bundle: #bundle
      )
    ) {
      if let account = model.accounts.first {
        Button(LocalizedStringResource("Open in Finder", bundle: #bundle)) {
          Task { await model.revealInFinder(account.accountID) }
        }
        .accessibilityIdentifier("setupRevealButton")
        .padding(.top)
        SidebarNotice()
      }
    }
  }
}

/**
 Where to look when the sidebar has no row for the account.

 Finder keeps every cloud location behind one switch of its own and hides them
 all while it is off, so an account macOS has just been watched to enable can
 still be nowhere in the sidebar. Zephyr can neither read that switch nor throw
 it: the setting lives in a file only full disk access opens, and Finder's
 settings answer to no URL the way a System Settings pane does. So this names
 where the switch is instead of offering to reach it, and says so on every
 finished setup rather than waiting for a state Zephyr cannot observe. The
 button above stays the reliable way in — it opens the folder whatever the
 sidebar is showing.
 */
private struct SidebarNotice: View {
  var body: some View {
    VStack(alignment: .leading) {
      Text(
        "Don’t see it in the sidebar? Choose Finder ▸ Settings, click Sidebar, and switch on Cloud Storage under Locations.",
        bundle: #bundle
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      HelpTopicButton(anchor: .dropboxNotInFinder, accessibilityIdentifier: "setup.sidebarHelp")
    }
    .padding(.top)
  }
}

#if DEBUG
  #Preview("Ready") {
    ReadyStep()
      .environment(PreviewHelper.model(accounts: PreviewHelper.sampleAccounts))
      .inSetupWindow()
  }

  #Preview("Ready — no account") {
    ReadyStep()
      .environment(PreviewHelper.model())
      .inSetupWindow()
  }
#endif
