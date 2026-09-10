import XCTest
import XCUITestKit

/**
 Photographs the menu-bar panel in each of the states it can be in.

 A class of its own, apart from ``ScreenshotUITests``, and deliberately so.
 That suite's captures are published — `fastlane screenshots` names it with
 `-only-testing:`, and `Scripts/export-screenshots.sh` owns the site's and the
 help book's image directories outright, filing whatever attachments it finds
 into them. An attachment added there is a picture shipped inside every app
 bundle and served from the site, whether or not a page ever embeds it. These
 are for reading a change by, so they are taken where the export cannot reach
 them; a state that later earns a place on a page is moved across deliberately,
 with a slug in `SCREENSHOTS` and an embed to match.

 Every state takes a launch of its own. The panel is arranged at launch rather
 than driven into shape, because most of these are not states a Mac can be asked
 to enter on cue — a hotspot joined, a route lost, an approval withheld, a token
 revoked.
 */
final class PanelStateScreenshotTests: XCTestCase {
  /// The panel arrangements captured, each named as ``PanelState`` names it so
  /// the launch argument and the file are the same word.
  private static let states = [
    "sending",
    "metered",
    "low-data-mode",
    "offline",
    "unreachable",
    "withheld-approvals",
    "paused",
    "account-failure",
    "sync-issues"
  ]

  /// The accounts window is closed before the panel opens, so its size only has
  /// to be one the window will take.
  private static let windowSizes = ["Zephyr": CGSize(width: 560, height: 160)]

  /**
   The frame these captures are laid over.

   ``MenuBarPanelScreen/publishedSize`` is a promise to the pages that embed it:
   one size in both appearances, declared in their markup. These states are not
   published and make no such promise, so they take a frame of their own rather
   than pulling that one about — a state that grows past it is a bigger picture
   here, and a page edit there.
   */
  private static let stateSize = CGSize(width: 448, height: 520)

  override func setUpWithError() throws {
    continueAfterFailure = false
    try XCTSkipUnless(
      ScreenshotPreconditions.machineCanCapture,
      "Screenshots need a capture-ready Mac: \(ScreenshotPreconditions.unmetRequirement)."
    )
  }

  @MainActor
  func testCapturesPanelStatesInLightAppearance() { capturePanels(in: .light) }
  @MainActor
  func testCapturesPanelStatesInDarkAppearance() { capturePanels(in: .dark) }

  @MainActor
  private func capturePanels(in appearance: Zephyr.Appearance) {
    for state in Self.states {
      capturePanel(in: state, appearance: appearance)
    }
  }

  /**
   One arrangement of the panel.

   The accounts window is closed first, which leaves the panel alone on the
   backdrop — and being alone on it is what lets the capture pick the panel out
   of an area at all, since a `MenuBarExtra`'s window reaches no accessibility
   tree to be measured.
   */
  @MainActor
  private func capturePanel(in state: String, appearance: Zephyr.Appearance) {
    let accounts = MainScreen.launch(
      sampleAccounts: true,
      appearance: appearance,
      windowSizes: Self.windowSizes,
      panelState: state
    )
    defer { accounts.app.terminate() }
    accounts.close()

    let panel = accounts.openMenuBarPanel()
    parkPointer(beside: panel.statusItem)
    captureScreenContent(
      slug("panel-\(state)", in: appearance),
      within: panel.searchArea,
      framedTo: Self.stateSize
    )
  }

  /// The name a capture is filed under: the light one is the slug itself, and
  /// the dark one is that slug with a suffix — the same pairing the published
  /// captures use, so a reader of both sets reads one naming scheme.
  @MainActor
  private func slug(_ name: String, in appearance: Zephyr.Appearance) -> String {
    switch appearance {
      case .light: name
      case .dark: "\(name)-dark"
    }
  }
}
