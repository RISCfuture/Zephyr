import SwiftUI
import libZephyr

/// The one-time enablement macOS demands before Finder will serve the domain.
struct FinderExtensionStep: View {
  let setup: SetupModel

  var body: some View {
    // Nothing on the usual page is true of a translocated copy: it is not
    // waiting for a switch, and no switch will appear for it.
    if InstallLocation.isTranslocated {
      TranslocatedNotice()
    } else {
      EnablementPage(setup: setup)
    }
  }
}

/// The usual Finder page: the switch macOS is waiting for, and where to find it.
private struct EnablementPage: View {
  let setup: SetupModel

  @Environment(AppModel.self)
  private var model
  @Environment(\.openURL)
  private var openURL

  var body: some View {
    SetupPageLayout(
      title: LocalizedStringResource("Enable Zephyr in Finder", bundle: #bundle),
      message: LocalizedStringResource(
        "macOS keeps every file provider switched off until you turn it on. Open System Settings and switch on Zephyr.",
        bundle: #bundle
      )
    ) {
      Button(LocalizedStringResource("Open System Settings", bundle: #bundle)) {
        openURL(SystemSettings.fileProviders)
      }
      .accessibilityIdentifier("setupOpenFileProvidersButton")
      if model.accounts.isEmpty {
        Text(
          "Zephyr appears in that list once an account is linked — go back a step first.",
          bundle: #bundle
        )
        .font(.callout)
        .foregroundStyle(ZephyrPalette.caution)
        .fixedSize(horizontal: false, vertical: true)
      }
    } status: {
      ApprovalStatusView(
        isGranted: setup.isGranted(.finderExtension),
        waiting: LocalizedStringResource("Waiting for Zephyr to be switched on", bundle: #bundle),
        granted: LocalizedStringResource(
          "Enabled. Your Dropbox is in Finder.",
          bundle: #bundle
        ),
        helpAnchor: .dropboxNotInFinder
      )
    }
  }
}

/**
 What the Finder step says when macOS is running Zephyr from a throwaway copy.

 A translocated Zephyr is not one switch away from working: macOS will not run
 its File Provider at all, so it never reaches the list the usual page sends
 the user to, and the usual page would have them hunting for a row that cannot
 appear. Zephyr cannot put this right from inside the sandbox either, and the
 remedy that does not need it — clearing the quarantine flag by hand — is a
 Terminal command, which is no thing to meet in the first five minutes of an
 app. So the page offers the installer instead: it writes the bundle straight
 into place, and nothing it installs is ever flagged. The command is still in
 the help book, for someone who would rather not download anything again.
 */
private struct TranslocatedNotice: View {
  @Environment(\.openURL)
  private var openURL

  var body: some View {
    SetupPageLayout(
      title: LocalizedStringResource("Zephyr Is Running From a Copy", bundle: #bundle),
      message: LocalizedStringResource(
        "macOS runs an app dragged out of a downloaded disk image from a temporary copy of its own, and it won’t put a Dropbox in Finder while it does. Zephyr’s installer puts it in place properly. Download it, run it, and open Zephyr again.",
        bundle: #bundle
      )
    ) {
      // No approval status here: this page cannot watch for its own answer. The
      // installer takes effect on the next launch, by which time Zephyr is
      // running from somewhere else and never sees this page.
      Button(LocalizedStringResource("Download the Installer", bundle: #bundle)) {
        openURL(FeatureFlags.websiteURL)
      }
      .accessibilityIdentifier("setupDownloadInstallerButton")
      HelpTopicButton(
        anchor: .dropboxNotInFinder,
        accessibilityIdentifier: "setup.translocationHelp"
      )
    }
  }
}

#if DEBUG
  #Preview("Finder — waiting") {
    FinderExtensionStep(setup: SetupModel(step: .finderExtension))
      .environment(PreviewHelper.model(accounts: PreviewHelper.sampleAccounts))
      .inSetupWindow()
  }

  #Preview("Finder — enabled") {
    FinderExtensionStep(
      setup: SetupModel(step: .finderExtension, grantedApprovals: [.finderExtension])
    )
    .environment(PreviewHelper.model(accounts: PreviewHelper.sampleAccounts))
    .inSetupWindow()
  }

  #Preview("Finder — running from a copy") {
    TranslocatedNotice()
      .inSetupWindow()
  }

  #Preview("Finder — no account yet") {
    FinderExtensionStep(setup: SetupModel(step: .finderExtension))
      .environment(PreviewHelper.model())
      .inSetupWindow()
  }
#endif
