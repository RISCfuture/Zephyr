import XCTest
import XCUITestKit

/**
 Launches the app in UI-test mode. Every test starts here, so the launch
 arguments and the screenshot staging live in one place rather than being
 repeated per test.
 */
@MainActor
enum Zephyr {

  /**
   Launches the app and returns it once its accounts window is up.

   - Parameter sampleAccounts: Whether to swap in the canned accounts, which
     also keeps the app off the keychain, the domains, and the network.
   - Parameter appearance: The appearance to pin the whole process to. Asking
     for one also stages the app for capture, so only the screenshot suite pays
     for any of it.
   - Parameter windowSizes: Content sizes to pin windows to, by title, for
     captures that must not depend on where a window was last dragged to.
   */
  static func launch(
    sampleAccounts: Bool,
    appearance: Appearance? = nil,
    windowSizes: [String: CGSize] = [:]
  ) -> XCUIApplication {
    let app = configure(appearance: appearance, windowSizes: windowSizes)
    // Zephyr's own switches go last. The argument domain reads the token after
    // a `-key` as that key's value, and these carry none — so a switch placed
    // before a defaults pair swallows that pair's key and the setting never
    // takes effect. Nothing reads these out of the argument domain anyway; the
    // app looks for them in `ProcessInfo.arguments`.
    app.launchArguments.append("--uitest-skip-setup")
    if sampleAccounts {
      app.launchArguments.append("--uitest-sample-accounts")
    }
    app.launchAndWaitUntilReady(readyElement: { $0.buttons["linkAccountButton"] })
    bringToFront(app)
    return app
  }

  /**
   Launches the app onto the sync-issues window alone, and returns it once that
   window is up.

   A launch of its own because a capture that takes in a window's shadow needs
   that window to be the only one on screen, and the sync-issues window is
   otherwise opened from behind the accounts window.
   */
  static func launchSyncIssues(
    appearance: Appearance? = nil,
    windowSizes: [String: CGSize] = [:]
  ) -> XCUIApplication {
    let app = configure(appearance: appearance, windowSizes: windowSizes)
    app.launchArguments.append("--uitest-show-sync-issues")
    app.launchArguments.append("--uitest-sample-accounts")
    app.launchAndWaitUntilReady(readyElement: { $0.descendant(id: "syncIssuesList") })
    bringToFront(app)
    return app
  }

  /**
   Launches the app onto first-run setup, and returns it once that window is up.

   Setup is a once-ever window with no command that reopens it — Zephyr is an
   agent app, so it has no menu bar to put one in — which is why this takes a
   launch of its own rather than a click in the launch every other capture
   shares.
   */
  static func launchSetup(appearance: Appearance? = nil) -> XCUIApplication {
    let app = configure(appearance: appearance, windowSizes: [:])
    app.launchArguments.append("--uitest-show-setup")
    // The canned accounts as well, so the pages that name one have something to
    // name: the account page shows the link that has just been made, and the
    // last page offers to open it in Finder.
    app.launchArguments.append("--uitest-sample-accounts")
    // The footer's own button: it is on every page but the last, and waiting
    // for it means waiting for a page that has been laid out rather than for a
    // window that has merely opened.
    app.launchAndWaitUntilReady(readyElement: { $0.buttons["setupContinueButton"] })
    bringToFront(app)
    return app
  }

  /**
   Launches the app onto one design-layer surface alone, and returns it once
   that window is up.

   The surfaces are the ones no host a UI test can reach ever shows: the two
   extension sheets, and the widget's layouts. Each is a window of its own, and
   a capture that takes in a window's shadow needs it to be the only one on
   screen — so each subject takes a launch, as setup and the sync-issues window
   do.
   */
  static func launchDesign(_ subject: String, appearance: Appearance) -> XCUIApplication {
    let app = configure(appearance: appearance, windowSizes: [:])
    app.launchArguments.append("--uitest-show-design=\(subject)")
    // The canned accounts as well: the share sheet lists them, and the widget
    // layouts are drawn on their figures.
    app.launchArguments.append("--uitest-sample-accounts")
    app.launchAndWaitUntilReady(readyElement: { $0.windows[DesignScreen.windowTitle] })
    bringToFront(app)
    return app
  }

  /**
   Brings the launched app to the front.

   Zephyr is an agent app, so a launch leaves its window up behind whatever was
   already frontmost. A click on an inactive app's window is spent activating
   it rather than pressing what it landed on, which costs a test whatever its
   first interaction was.
   */
  private static func bringToFront(_ app: XCUIApplication) {
    app.activate()
  }

  /// Everything every launch shares: the arguments that must precede Zephyr's
  /// own switches, and the screenshot staging when a capture asked for it.
  private static func configure(
    appearance: Appearance?,
    windowSizes: [String: CGSize]
  ) -> XCUIApplication {
    let app = XCUIApplication()
    // AppKit reopens the windows a launch left behind rather than the ones the
    // scene declares. A test-run app is killed rather than quit, so what it
    // leaves is whatever it happened to be holding. Ignoring the saved state
    // makes every launch open the scene as declared.
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    if let appearance { stageForScreenshots(app, in: appearance, windowSizes: windowSizes) }
    return app
  }

  /**
   Turns on the app's screenshot staging and settles the two things on screen
   that move on their own: an overlay scrollbar fading out after a scroll, and
   a text field's blinking insertion point. Both settings live in
   `NSGlobalDomain`, which the argument domain outranks, so neither touches the
   developer's own preferences.
   */
  private static func stageForScreenshots(
    _ app: XCUIApplication,
    in appearance: Appearance,
    windowSizes: [String: CGSize]
  ) {
    app.launchEnvironment["UITEST_SCREENSHOTS"] = "1"
    app.launchEnvironment["UITEST_APPEARANCE"] = appearance.rawValue
    if !windowSizes.isEmpty {
      app.launchEnvironment["UITEST_WINDOW_SIZES"] =
        windowSizes
        .map { "\($0.key)=\(Int($0.value.width))x\(Int($0.value.height))" }
        .joined(separator: ";")
    }
    app.launchArguments += ["-AppleShowScrollBars", "WhenScrolling"]
    app.launchArguments += ["-NSTextInsertionPointBlinkPeriodOff", "999999"]
  }

  /// The appearance the whole app process is pinned to (mirrors `UITEST_APPEARANCE`).
  enum Appearance: String, CaseIterable {
    case light
    case dark
  }
}
