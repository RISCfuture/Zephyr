import SwiftUI
import libZephyr

/// Notification authorization, asked for in place when macOS still allows it.
struct NotificationsStep: View {
  let setup: SetupModel

  @Environment(\.openURL)
  private var openURL

  var body: some View {
    SetupPageLayout(
      title: LocalizedStringResource("Allow Notifications", bundle: #bundle),
      message: LocalizedStringResource(
        "Zephyr tells you when your files change and when something couldn’t sync. How much it says is up to you in Settings.",
        bundle: #bundle
      )
    ) {
      // Once macOS has taken an answer it won't ask again, so the button stops
      // offering to ask and starts opening the place the answer can be changed.
      if setup.hasAnsweredNotificationPrompt {
        Button(LocalizedStringResource("Open Notifications", bundle: #bundle)) {
          openURL(SystemSettings.notifications)
        }
        .accessibilityIdentifier("setupOpenNotificationsButton")
      } else {
        Button(LocalizedStringResource("Allow Notifications", bundle: #bundle)) {
          Task { await setup.allowNotifications() }
        }
        .accessibilityIdentifier("setupAllowNotificationsButton")
      }
    } status: {
      ApprovalStatusView(
        isGranted: setup.isGranted(.notifications),
        waiting: LocalizedStringResource("Not allowed yet", bundle: #bundle),
        granted: LocalizedStringResource("Allowed.", bundle: #bundle),
        helpAnchor: .notificationsDenied
      )
    }
  }
}

#if DEBUG
  #Preview("Notifications") {
    NotificationsStep(setup: SetupModel(step: .notifications))
      .inSetupWindow()
  }

  #Preview("Notifications — already answered") {
    NotificationsStep(
      setup: SetupModel(
        step: .notifications,
        grantedApprovals: [.notifications],
        hasAnsweredNotificationPrompt: true
      )
    )
    .inSetupWindow()
  }
#endif
