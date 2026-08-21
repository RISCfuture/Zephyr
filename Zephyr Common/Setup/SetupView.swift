import Combine
import SwiftUI
import libZephyr

/**
 First-run setup: one page at a time in a window of its own, the way a Mac
 setup assistant works — explain, then ask, then confirm it landed.
 */
struct SetupView: View {
  private static let size = (width: 580.0, height: 470.0)

  @Environment(\.dismissWindow)
  private var dismissWindow

  @State private var setup = SetupModel(
    usesCannedApprovals: AppModel.launchesWithSetupPresented
  )

  var body: some View {
    VStack(spacing: 0) {
      SetupPage(setup: setup)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(Metrics.pageInsets)
      SetupFooter(setup: setup, finish: finish)
    }
    .frame(width: Self.size.width, height: Self.size.height)
    // No accessibility identifier on this container. SwiftUI hands a
    // container's identifier down to everything inside it, so one here would
    // report itself as the identifier of the Continue button, the Back button,
    // and every control the pages put up — and the window already has a title
    // to be found by.
    .task {
      recordStart()
      await setup.refreshApprovals()
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    { _ in
      Task { await setup.refreshApprovals() }
    }
  }

  /// Notes that a run is under way, so one the user breaks off is offered
  /// again next launch instead of being taken for an upgrade that never
  /// needed setting up.
  private func recordStart() {
    guard !AppModel.launchesWithSetupPresented else { return }
    UserDefaults.standard.set(true, forKey: AppModel.hasStartedSetupDefaultsKey)
  }

  private func finish() {
    UserDefaults.standard.set(true, forKey: AppModel.hasCompletedSetupDefaultsKey)
    dismissWindow(id: WindowID.setup)
  }
}

/// The page for the step being shown.
private struct SetupPage: View {
  let setup: SetupModel

  var body: some View {
    switch setup.step {
      case .welcome: WelcomeStep()
      case .whatZephyrNeeds: WhatZephyrNeedsStep()
      case .account: AccountStep()
      case .finderExtension: FinderExtensionStep(setup: setup)
      case .notifications: NotificationsStep(setup: setup)
      case .loginItem: LoginItemStep(setup: setup)
      case .ready: ReadyStep()
    }
  }
}

/// The window's navigation, in the place a Mac setup assistant keeps it.
private struct SetupFooter: View {
  let setup: SetupModel
  let finish: () -> Void

  var body: some View {
    HStack {
      Spacer()
      if setup.canGoBack {
        Button(LocalizedStringResource("Back", bundle: #bundle)) { setup.goBack() }
          .accessibilityIdentifier("setupBackButton")
      }
      if setup.isOnLastStep {
        Button(LocalizedStringResource("Done", bundle: #bundle), action: finish)
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("setupDoneButton")
      } else {
        Button(LocalizedStringResource("Continue", bundle: #bundle)) { setup.advance() }
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("setupContinueButton")
      }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 14)
    .background(.bar)
  }
}

#if DEBUG
  #Preview("Setup") {
    SetupView()
      .environment(PreviewHelper.model())
  }
#endif
