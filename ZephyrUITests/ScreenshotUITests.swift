import XCTest
import XCUITestKit

/**
 Captures the images the marketing site and the App Store listing ship, so they
 are a build product of the app they show rather than hand-made pictures that
 rot.

 Not part of an ordinary test run: `fastlane screenshots` names this class with
 `-only-testing:`, and CI skips it. The precondition below is the defence that
 survives an edit to either — a machine whose display, accent colour, or
 accessibility settings would change what is drawn skips the whole class rather
 than quietly publishing ten different images.

 Every shot is taken twice, once per appearance, because the site adapts to
 both and a light-only image is the one element on a dark page that doesn't.
 */
final class ScreenshotUITests: XCTestCase {
  /**
   The content sizes the captured windows are pinned to, by title.

   Pinned rather than left to each scene's `defaultSize`, which loses to
   whatever frame the window was last dragged to on the machine the captures
   come from. The heights are deliberately shorter than the seeded content
   needs: both windows resize to their content's minimum, so asking for less
   than that yields the tightest window the app will draw rather than one
   padded out with the empty space a `defaultSize` leaves.
   */
  private static let windowSizes = [
    "Zephyr": CGSize(width: 560, height: 160),
    "Sync Issues": CGSize(width: 560, height: 160)
  ]

  /// How many pages first-run setup walks through, which the animation is made
  /// of. Asserted rather than assumed: a page that stopped being reached would
  /// otherwise just shorten the animation, and nothing would say so.
  private static let setupPageCount = 7

  /**
   The design-layer surfaces captured on their own: the gallery subject to
   launch, and the element that says it has finished arriving.

   Each name is both the subject and the slug its capture is filed under, which
   is what keeps the two from drifting apart.

   The two sheets are waited on for their contents rather than for their window.
   Each opens on a spinner while it reads what it is about, and a spinner is the
   one thing a capture cannot wait out — the area it is in never settles, so the
   run fails naming an animation instead of photographing a sheet. The widget
   layouts read nothing and are up as soon as their window is.
   */
  private static let designSubjects: [(slug: String, readyIdentifier: String?)] = [
    ("file-versions", "versionsList"),
    ("share-upload", "shareAccountPicker"),
    ("widget-small", nil),
    ("widget-medium", nil),
    ("widget-unlinked", nil)
  ]

  override func setUpWithError() throws {
    continueAfterFailure = false
    try XCTSkipUnless(
      ScreenshotPreconditions.machineCanCapture,
      "Screenshots need a capture-ready Mac: \(ScreenshotPreconditions.unmetRequirement)."
    )
  }

  @MainActor
  func testCapturesLightAppearance() { captureEverything(in: .light) }
  @MainActor
  func testCapturesDarkAppearance() { captureEverything(in: .dark) }

  /**
   Every shot, in as few launches as each one allows.

   The first four are of one app in one state, and relaunching per image would
   cost four launches for nothing. The rest each need a window that nothing else
   opens — setup is a once-ever window, and every design-layer surface stands in
   for a host this suite cannot launch — so each of those takes a launch that
   presents it.

   Every capture takes in the shadow around its window, so exactly one window
   may be on screen for each — which is what the launches are divided along.
   The first walks the one chain that closes behind itself: the accounts window
   goes before the panel opens, and the panel is what Settings is opened from,
   since an agent app has no menu bar to open it from and a key equivalent
   needs some window in front to take it.
   */
  @MainActor
  private func captureEverything(in appearance: Zephyr.Appearance) {
    let accounts = MainScreen.launch(
      sampleAccounts: true,
      appearance: appearance,
      windowSizes: Self.windowSizes
    )
    captureAccounts(accounts, in: appearance)
    accounts.close()

    let panel = accounts.openMenuBarPanel()
    captureMenuBarPanel(panel, in: appearance)
    captureSettings(from: panel, in: appearance)

    captureSyncIssues(in: appearance)
    captureSetup(in: appearance)
    captureDesignSubjects(in: appearance)
  }

  /**
   The surfaces the app itself never shows: the two extension sheets, and the
   widget's layouts.

   Each takes a launch of its own, for the same reason the sync-issues window
   does — a capture that takes in a window's shadow needs that window to be the
   only one on screen.
   */
  @MainActor
  private func captureDesignSubjects(in appearance: Zephyr.Appearance) {
    for subject in Self.designSubjects {
      let gallery = DesignScreen.launch(
        subject.slug,
        appearance: appearance,
        readyIdentifier: subject.readyIdentifier
      )
      parkPointer(beside: gallery.window)
      capture(slug(subject.slug, in: appearance), around: gallery.window)
    }
  }

  /// The accounts window: what Zephyr is syncing, per account.
  @MainActor
  private func captureAccounts(_ accounts: MainScreen, in appearance: Zephyr.Appearance) {
    parkPointer(beside: accounts.window)
    capture(slug("accounts", in: appearance), around: accounts.window)
  }

  /// The sync-issues window, in a launch that presents it on its own.
  @MainActor
  private func captureSyncIssues(in appearance: Zephyr.Appearance) {
    let issues = SyncIssuesScreen.launch(appearance: appearance, windowSizes: Self.windowSizes)
    parkPointer(beside: issues.window)
    capture(slug("sync-issues", in: appearance), around: issues.window)
  }

  /**
   Settings, which is one scrolling form rather than a set of tabs.

   Opened from the panel, which is still up from the capture before this one.
   Opening Settings dismisses the panel, which is what leaves Settings alone on
   screen.

   Framed twice out of the one window, since nothing about it changes between
   the two. The site shows the whole of it, where the point is the breadth of
   what Zephyr lets you decide; a help page explaining one control wants that
   control legible instead.
   */
  @MainActor
  private func captureSettings(from panel: MenuBarPanelScreen, in appearance: Zephyr.Appearance) {
    let settings = panel.openSettings()
    parkPointer(beside: settings.window)
    capture(slug("settings", in: appearance), around: settings.window)
    captureBandwidthSettings(settings, in: appearance)
    settings.close()
  }

  /**
   The Bandwidth section of Settings on its own.

   A band of the window rather than the window, so that what a reader of the
   help book sees is the two sliders the page is about. Framing it this closely
   also keeps every edition-specific line out: the whole window says which
   edition it belongs to, in the Updates section and in the Command-Line Tool
   one, and the help book is built into both editions from this one capture run.

   Nothing is scrolled or clicked to reach it. The band is measured off the
   headings around it, and the window opens tall enough to draw them both.
   */
  @MainActor
  private func captureBandwidthSettings(
    _ settings: SettingsScreen,
    in appearance: Zephyr.Appearance
  ) {
    captureScreenRegion(
      slug("settings-bandwidth", in: appearance),
      within: settings.bandwidthSection
    )
  }

  /**
   First-run setup, page by page, in a launch of its own.

   Every page is captured, and they are filed as numbered frames rather than as
   one image: setup is a sequence, and the site plays it back as one. Only
   Continue is ever clicked — the pages' own buttons open System Settings, ask
   macOS for notification permission, and register the login item, and a
   capture run may do none of those to the Mac it runs on.
   */
  @MainActor
  private func captureSetup(in appearance: Zephyr.Appearance) {
    let setup = SetupScreen.launch(appearance: appearance)
    var lastPage: Data?
    var pages = 0
    while true {
      pages += 1
      parkPointer(beside: setup.window)
      lastPage = capture(
        "\(slug("setup", in: appearance))-\(pages)",
        around: setup.window,
        changedFrom: lastPage
      )
      guard setup.hasNextPage else { break }
      setup.showNextPage()
    }
    XCTAssertEqual(
      pages,
      Self.setupPageCount,
      "Setup walked \(pages) pages. The animation is every page there is, so a page gained or "
        + "lost is a change to make deliberately."
    )
  }

  /**
   The menu-bar panel, which is the app's front door.

   Searched for in an area of the screen rather than framed on a window: a
   `MenuBarExtra`'s window reaches no accessibility tree, so there is no frame to
   grow and nothing to park the pointer beside either. The accounts window is
   closed before this runs, which leaves the panel alone on the backdrop — and
   that is what lets it be picked out of the area at all. It is left open, as
   the way to Settings.

   The frame the panel is published in is stated rather than taken from what the
   search found, because what the search finds includes a shadow that reads
   further on a light backdrop than on a dark one — and the two appearances have
   to be published at one size.
   */
  @MainActor
  private func captureMenuBarPanel(_ panel: MenuBarPanelScreen, in appearance: Zephyr.Appearance) {
    parkPointer(beside: panel.statusItem)
    captureScreenContent(
      slug("menu-bar-panel", in: appearance),
      within: panel.searchArea,
      framedTo: MenuBarPanelScreen.publishedSize
    )
  }

  /// The name a capture is filed under: the light one is the slug itself, and
  /// the dark one is that slug with a suffix, which is the pairing the site's
  /// `<picture>` sources are written against.
  @MainActor
  private func slug(_ name: String, in appearance: Zephyr.Appearance) -> String {
    switch appearance {
      case .light: name
      case .dark: "\(name)-dark"
    }
  }
}
