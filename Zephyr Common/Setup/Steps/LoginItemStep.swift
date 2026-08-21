import SwiftUI
import libZephyr

/// The login item, which is what keeps remote changes arriving promptly.
struct LoginItemStep: View {
  let setup: SetupModel

  var body: some View {
    SetupPageLayout(
      title: LocalizedStringResource("Open Zephyr at Login", bundle: #bundle),
      message: LocalizedStringResource(
        "Zephyr is what tells Finder that Dropbox has changed. While it isn’t running, Finder catches up the next time you open it instead.",
        bundle: #bundle
      )
    ) {
      Button(LocalizedStringResource("Open at Login", bundle: #bundle)) {
        Task { await setup.openAtLogin() }
      }
      .disabled(setup.isGranted(.loginItem))
      .accessibilityIdentifier("setupOpenAtLoginButton")
      if let failure = setup.loginItemFailure {
        LoginItemFailureView(message: failure)
      }
    } status: {
      ApprovalStatusView(
        isGranted: setup.isGranted(.loginItem),
        waiting: LocalizedStringResource("Not opening at login yet", bundle: #bundle),
        granted: LocalizedStringResource("Zephyr opens at login.", bundle: #bundle),
        helpAnchor: .withheldApproval
      )
    }
  }
}

/// Why macOS refused the login item, and the one place it can be granted by
/// hand — which rides with the message rather than under it, because on its own
/// it says nothing about why it is being offered.
private struct LoginItemFailureView: View {
  let message: String

  @Environment(\.openURL)
  private var openURL

  var body: some View {
    VStack(alignment: .leading) {
      Text(message)
        .font(.callout)
        .foregroundStyle(ZephyrPalette.alert)
        .fixedSize(horizontal: false, vertical: true)
      Button(LocalizedStringResource("Open System Settings", bundle: #bundle)) {
        openURL(SystemSettings.loginItemsAndExtensions)
      }
      .controlSize(.small)
    }
  }
}

#if DEBUG
  #Preview("Open at login") {
    LoginItemStep(setup: SetupModel(step: .loginItem))
      .inSetupWindow()
  }

  #Preview("Open at login — granted") {
    LoginItemStep(setup: SetupModel(step: .loginItem, grantedApprovals: [.loginItem]))
      .inSetupWindow()
  }

  #Preview("Login item refused") {
    LoginItemFailureView(message: "Couldn’t open Zephyr at login. macOS refused the request.")
      .padding()
      .frame(width: 420)
  }
#endif
