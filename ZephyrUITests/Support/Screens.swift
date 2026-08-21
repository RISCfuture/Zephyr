import XCTest
import XCUITestKit

/// The main window: the account list, its unlink flow, and the link sheet entry.
@MainActor
struct MainScreen {
  let app: XCUIApplication

  var linkButton: XCUIElement { app.buttons["linkAccountButton"] }

  /// The accounts window itself, which is what a capture is framed on.
  var window: XCUIElement { app.windows["Zephyr"] }

  /// Launches the app and waits for the accounts window's toolbar to land.
  static func launch(
    sampleAccounts: Bool,
    appearance: Zephyr.Appearance? = nil,
    windowSizes: [String: CGSize] = [:]
  ) -> Self {
    let screen = Self(
      app: Zephyr.launch(
        sampleAccounts: sampleAccounts,
        appearance: appearance,
        windowSizes: windowSizes
      )
    )
    screen.linkButton.assertExists("Accounts window did not appear")
    return screen
  }

  /// An account's row, located by the name it displays.
  func accountRow(accountID: String) -> XCUIElement {
    app.staticTexts["accountName-\(accountID)"]
  }

  func openLinkSheet() -> LinkSheetScreen {
    linkButton.click()
    let sheet = LinkSheetScreen(app: app)
    sheet.connectButton.assertExists("Link sheet did not appear")
    return sheet
  }

  /**
   Opens the menu-bar panel and returns it.

   Reachable whether or not a window is up: Zephyr is an agent app, so the
   menu-bar item is the way back in once the accounts window is closed.
   */
  func openMenuBarPanel() -> MenuBarPanelScreen {
    MenuBarPanelScreen.open(in: app)
  }

  /**
   Unlinks an account by selecting its row and pressing Delete, then
   confirming the dialog.

   The row's context menu offers the same command, but SwiftUI doesn't carry
   accessibility identifiers onto the `NSMenuItem`s macOS builds a context
   menu from, and locating a menu item by its localized title would tie the
   test to its wording.
   */
  func unlinkAccount(accountID: String) {
    accountRow(accountID: accountID).click()
    app.typeKey(.delete, modifierFlags: [])
    let byIdentifier = app.buttons["confirmUnlinkButton"]
    if byIdentifier.wait(timeout: ScaledTimeouts.short) {
      byIdentifier.click()
    } else {
      app.buttons["Unlink"]
        .assertExists("Unlink confirmation did not appear", timeout: ScaledTimeouts.short)
        .click()
    }
  }

  /// Closes the accounts window and waits for it to go, so nothing that
  /// follows runs while it is still sliding away.
  func close() {
    window.closeWindow(in: app)
  }

  func attachScreenshot(named name: String) {
    Attachments.attach(app.screenshot(), named: name)
  }
}

/**
 The link sheet: the button that runs Dropbox's authorization page, the code
 fallback folded under it, and the sheet's confirm/cancel controls.

 Everything here drives the fallback rather than the button above it. The page
 that button opens is an `ASWebAuthenticationSession`, which runs in another
 process and reaches no accessibility tree this test can query — the same wall
 the menu-bar panel hits. Both halves of the sheet finish at the same token
 exchange, so the fallback is what a test can hold on to.
 */
@MainActor
struct LinkSheetScreen {
  let app: XCUIApplication

  var connectButton: XCUIElement { app.buttons["connectDropboxButton"] }
  var enterCodeButton: XCUIElement { app.buttons["enterCodeInsteadButton"] }
  var codeField: XCUIElement { app.textFields["authorizationCodeField"] }
  var openBrowserButton: XCUIElement { app.buttons["openDropboxButton"] }
  var confirmButton: XCUIElement { app.buttons["confirmLinkButton"] }
  var cancelButton: XCUIElement { app.buttons["cancelLinkButton"] }
  var errorMessage: XCUIElement { app.staticTexts["linkErrorMessage"] }

  /// Waits for the link flows to be built (the connect button enables once
  /// they are, and so does everything in the fallback).
  func waitUntilFlowReady() -> Bool {
    connectButton.waitFor(NSPredicate(format: "isEnabled == true"))
  }

  /// Opens the code fallback and waits for the field it folds out.
  @discardableResult
  func revealCodeEntry() -> Self {
    enterCodeButton.click()
    codeField.assertExists("The code field did not fold out of the fallback")
    return self
  }

  /**
   Opens the authorization page in the browser from inside the fallback.

   The browser really does open, so the app is brought back to the front: what
   the sheet draws — the focus ring, the buttons' tints — depends on whether it
   is in the active app, and every assertion and capture after this reads it.
   */
  @discardableResult
  func openBrowser() -> Self {
    openBrowserButton.click()
    app.activate()
    return self
  }

  func enterCode(_ code: String) {
    codeField.click()
    codeField.typeText(code)
  }

  /// Submits the entered code expecting Dropbox to reject it, and waits for the
  /// message the sheet shows in its place.
  @discardableResult
  func failToLink(timeout: TimeInterval = ScaledTimeouts.element) -> Self {
    confirmButton.click()
    errorMessage.assertExists("The sheet reported no failure", timeout: timeout)
    return self
  }

  /// Dismisses the sheet without linking and returns the accounts window
  /// behind it.
  @discardableResult
  func cancel() -> MainScreen {
    cancelButton.click()
    return dismissed()
  }

  /**
   Links the account the entered code authorizes and returns the accounts
   window behind the sheet.

   - Parameter timeout: How long the sheet may take to go. The default suits a
     dismissal the app decides on its own; a link that goes to Dropbox for a
     token holds the sheet up for as long as that takes, and is given the same
     budget as the account it is waited on for.
   */
  @discardableResult
  func confirmLink(timeout: TimeInterval = ScaledTimeouts.element) -> MainScreen {
    confirmButton.click()
    return dismissed(within: timeout)
  }

  func attachScreenshot(named name: String) {
    Attachments.attach(app.screenshot(), named: name)
  }

  /// The accounts window the sheet leaves behind, once the sheet itself is gone.
  private func dismissed(within timeout: TimeInterval = ScaledTimeouts.element) -> MainScreen {
    connectButton.assertHidden("Link sheet did not dismiss", timeout: timeout)
    return MainScreen(app: app)
  }
}

/// The sync-issues window: everything Zephyr could not sync, and why.
@MainActor
struct SyncIssuesScreen {
  let app: XCUIApplication

  /// The sync-issues window itself, which is what a capture is framed on.
  var window: XCUIElement { app.windows["Sync Issues"] }

  /// Launches the app onto the sync-issues window alone and waits for it.
  static func launch(
    appearance: Zephyr.Appearance? = nil,
    windowSizes: [String: CGSize] = [:]
  ) -> Self {
    let screen = Self(
      app: Zephyr.launchSyncIssues(appearance: appearance, windowSizes: windowSizes)
    )
    screen.window.assertExists("The sync-issues window never opened.")
    return screen
  }
}

/**
 One design-layer surface, hosted in a window of its own.

 The version-history sheet, the share sheet, and the widget's layouts are drawn
 by hosts a UI test cannot launch or stage — Finder, whichever app is sharing,
 WidgetKit — so the app puts one of them up on its own and the suite
 photographs that. The window is stripped back to the surface inside it, but it
 keeps its title in the accessibility tree, which is what a capture is framed
 on.
 */
@MainActor
struct DesignScreen {
  /// The gallery window's title, which is never drawn and always queryable.
  static let windowTitle = "Design"

  let app: XCUIApplication

  /// The window itself, which is what a capture is framed on.
  var window: XCUIElement { app.windows[Self.windowTitle] }

  /**
   Launches the app onto one subject alone and waits for it to arrive.

   - Parameter readyIdentifier: An element inside the surface that appears only
     once it has finished loading, for a subject that loads anything. A surface
     still reading is a surface still showing a spinner, and a spinner is what a
     capture can never wait out.
   */
  static func launch(
    _ subject: String,
    appearance: Zephyr.Appearance,
    readyIdentifier: String? = nil
  ) -> Self {
    let screen = Self(app: Zephyr.launchDesign(subject, appearance: appearance))
    screen.window.assertExists("The design gallery never opened “\(subject)”.")
    if let readyIdentifier {
      screen.app
        .descendant(id: readyIdentifier)
        .assertExists("“\(subject)” never finished loading.")
    }
    return screen
  }
}

/// First-run setup: the window it runs in, and the footer button that walks it.
@MainActor
struct SetupScreen {
  let app: XCUIApplication

  /// The setup window itself, which is what a capture is framed on.
  var window: XCUIElement { app.windows["Welcome to Zephyr"] }

  /// The footer's Continue button, which the last page offers as Done instead.
  var continueButton: XCUIElement { app.buttons["setupContinueButton"] }

  /**
   Whether a page follows the one on screen.

   Read off the Continue button, since the last page offers Done in its place —
   and clicking that would write the “setup finished” flag onto the machine
   taking the pictures.
   */
  var hasNextPage: Bool { continueButton.exists }

  /// Launches the app onto first-run setup and waits for its window.
  static func launch(appearance: Zephyr.Appearance? = nil) -> Self {
    let screen = Self(app: Zephyr.launchSetup(appearance: appearance))
    screen.window.assertExists("The setup window never opened.")
    return screen
  }

  /**
   Advances to the next page.

   The page that arrives is not waited on here: setup's pages carry nothing to
   tell them apart in the accessibility tree, so the wait is the caller's
   check that what is on screen has changed.
   */
  func showNextPage() {
    continueButton.click()
  }
}

/**
 Zephyr's menu-bar item and the panel it opens.

 Written around the item rather than around the panel, because the item is the
 only part of this screen that can be queried: SwiftUI puts a `MenuBarExtra`'s
 window into no accessibility tree at all — not the window, not one control
 inside it — so the panel is reached by where it is drawn relative to the item,
 and by what opening it leads to.
 */
@MainActor
struct MenuBarPanelScreen {
  /// How far around the item to look for the panel: wide enough on either side
  /// that one macOS has nudged sideways to fit on screen is still inside, and
  /// tall enough for the longest panel Zephyr draws.
  private static let searchSize = CGSize(width: 900, height: 800)

  /**
   The size the panel's capture is published at.

   Stated rather than measured, because the panel has to be published at one
   size in both appearances and the only measurement of it available is of its
   pixels — which take in a shadow that fades out sooner on a dark backdrop than
   on a light one. So the capture searches ``searchArea`` for the panel and lays
   a frame of this size over what it finds, and fails if the panel outgrows it.

   The width is the panel's own 320 points with the same 64-point margin every
   window capture carries on either side of its subject. The height is that
   margin again around the tallest panel Zephyr draws, with room for a row or
   two more — the panel grows with the number of accounts linked and with what
   macOS is holding back, and none of that is fixed the way the width is.
   */
  static let publishedSize = CGSize(width: 448, height: 480)

  let app: XCUIApplication

  /// Zephyr's item in the menu bar. Scoped to the app, because the menu bar
  /// holds every other app's too and Zephyr's is the only one this process
  /// vends.
  var statusItem: XCUIElement { app.statusItems.firstMatch }

  /**
   Where the panel is on screen: under the item that opened it.

   Only the panel and the backdrop are in here, which is what a search for the
   panel needs; how much of the area the panel actually fills does not matter.
   */
  var searchArea: CGRect {
    let item = statusItem.frame
    return CGRect(
      x: item.midX - Self.searchSize.width / 2,
      y: item.maxY,
      width: Self.searchSize.width,
      height: Self.searchSize.height
    )
  }

  /**
   Clicks Zephyr's menu-bar item and returns the panel it opens.

   The item is waited on rather than the panel, which reaches no accessibility
   tree to be waited on. The app is brought forward first, so the click lands
   on Zephyr's item rather than on whatever is in front.
   */
  static func open(in app: XCUIApplication) -> Self {
    app.activate()
    let screen = Self(app: app)
    screen.statusItem
      .assertExists("Zephyr put no item in the menu bar.")
      .click()
    return screen
  }

  /**
   Opens Settings from the panel and returns its window.

   The panel is what makes ⌘, land anywhere at all: an agent app has no menu
   bar to open Settings from, and a key equivalent needs some window in front
   to take it. Opening Settings dismisses the panel.
   */
  func openSettings() -> SettingsScreen {
    let window = app.openSettings()
    window.assertExists("Settings never opened from the menu-bar panel.")
    return SettingsScreen(app: app, window: window)
  }
}

/// Settings, which is one scrolling form rather than a set of tabs.
@MainActor
struct SettingsScreen {
  /**
   How far above a section's heading a band of the form is cut.

   The same distance is taken above the heading that follows, so a band holds
   one section and an equal share of the space on either side of it — which is
   what makes the cut read as a band of the form rather than as a rule drawn
   through it.
   */
  private static let headingInset: CGFloat = 14

  let app: XCUIApplication

  /// The Settings window itself, which is what a capture is framed on.
  let window: XCUIElement

  /**
   The Bandwidth section on its own, across the whole width of the window.

   Bounded by the two headings around it rather than by the section itself: a
   `Section` of a `Form` reaches the accessibility tree as its contents and not
   as one element, so there is nothing whose frame is the heading, the rows, and
   the footer together. Each heading does carry one element that can be asked
   for by name — the help link on its trailing edge — and the space between two
   of them is the section between them.

   Measured rather than searched for, which is what lets both appearances be
   published at one size: a form's layout is the same in either, where the
   pixels it is drawn in are not.

   The band is the section this help page is about and nothing else, which is
   the point of framing it at all. Settings is where the two editions differ,
   and the whole window says things — that the store keeps Zephyr up to date,
   that the command-line tool comes with the download — that are true of the
   edition the capture is taken from and false for a reader of the other one.
   The help book is built into both.
   */
  var bandwidthSection: CGRect {
    let bandwidth = helpLink(ofSection: "bandwidth")
      .assertExists("Settings showed no Bandwidth section.")
      .frame
    let metered = helpLink(ofSection: "meteredNetworks")
      .assertExists("Settings showed no Metered Networks section, which is what bounds Bandwidth.")
      .frame
    let top = bandwidth.minY - Self.headingInset
    let band = CGRect(
      x: window.frame.minX,
      y: top,
      width: window.frame.width,
      height: metered.minY - Self.headingInset - top
    )
    XCTAssertTrue(
      window.frame.contains(band),
      "The Bandwidth section is not wholly inside the settings window, so the band would be cut. "
        + "Settings opens at the size its scene declares and scrolls from the top, which is what "
        + "puts this section in view."
    )
    return band
  }

  /// Closes Settings and waits for it to go, so nothing that follows runs
  /// while it is still sliding away.
  func close() {
    window.closeWindow(in: app)
  }

  /// The help link a section's heading carries, named in the app's
  /// `<screen>.<control>` scheme — which is what tells eight otherwise
  /// identical buttons apart.
  private func helpLink(ofSection section: String) -> XCUIElement {
    app.buttons["settings.\(section).help"]
  }
}

/// Screenshot attachment plumbing shared by the screen objects.
@MainActor
enum Attachments {
  static func attach(_ screenshot: XCUIScreenshot, named name: String) {
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = name
    attachment.lifetime = .keepAlways
    XCTContext.runActivity(named: name) { activity in
      activity.add(attachment)
    }
  }
}

/// Window plumbing shared by the screen objects.
@MainActor
extension XCUIElement {
  /**
   Closes this window and waits for it to go.

   The window is clicked first so that ⌘W, which is sent to the app rather
   than to a close button, lands on this one.
   */
  func closeWindow(in app: XCUIApplication) {
    click()
    app.typeKey("w", modifierFlags: .command)
    assertHidden()
  }
}
