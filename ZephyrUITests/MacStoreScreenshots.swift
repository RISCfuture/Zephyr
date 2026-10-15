import ScreenCaptureKit
import XCTest
import XCUIPromoKit
import XCUITestKit

/**
 Captures the App Store listing's stills for `promokit mac-stills`, which
 exports them from the result bundle for `promokit render` to set on the
 listing's canvas.

 Each window is photographed on its own, in the `window` capture
 promokit.json asks for: over transparency and with the shadow macOS draws
 around it, so the canvas shows through wherever the window doesn't; the
 menu-bar panel is the exception, for the reason its capture gives. Light
 only: the listing shows one appearance. The listing's first still, Finder,
 is photographed in the screenshot VM and named in the storyboard instead.

 Skips outside `promokit mac-stills`, and on a Mac that isn't capture-ready
 for the same reasons as ``ScreenshotUITests``. The test runner needs Screen
 Recording permission.
 */
final class MacStoreScreenshots: XCTestCase {
  /// The design-layer surfaces in the listing, with the element that says each
  /// has finished loading. See ``ScreenshotUITests`` for why they are waited on.
  private static let designSubjects: [(slug: String, readyIdentifier: String?)] = [
    ("file-versions", "versionsList"),
    ("share-upload", "shareAccountPicker"),
    ("widget-medium", nil)
  ]

  /// The app under test's bundle identifier, which is how its menu-bar panel —
  /// a window outside the accessibility tree — is told apart from everyone else's.
  private static let bundleIdentifier = "codes.tim.Zephyr"

  /// A menu-bar panel is taller than this; the status item, which is also a
  /// window of Zephyr's above the normal layer, is not.
  private static let minimumPanelHeight: CGFloat = 100

  private static func isZephyrs(_ window: SCWindow) -> Bool {
    window.owningApplication?.bundleIdentifier == bundleIdentifier
  }

  override func setUpWithError() throws {
    continueAfterFailure = false
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment[PromoLaunch.localeVariable] != nil,
      "Only `promokit mac-stills` captures the Mac App Store stills."
    )
    try XCTSkipUnless(
      ScreenshotPreconditions.machineCanCapture,
      "Screenshots need a capture-ready Mac: \(ScreenshotPreconditions.unmetRequirement)."
    )
  }

  @MainActor
  func testCaptureStills() async throws {
    let accounts = MainScreen.launch(
      sampleAccounts: true,
      appearance: .light,
      windowSizes: CapturedWindows.sizes,
      panelState: "sending"
    )
    try await capture("accounts", window: accounts.window)
    accounts.close()

    let panel = accounts.openMenuBarPanel()
    try await captureMenuBarPanel(panel)

    let settings = panel.openSettings()
    try await capture("settings", window: settings.window)
    settings.close()

    for subject in Self.designSubjects {
      let gallery = DesignScreen.launch(
        subject.slug,
        appearance: .light,
        readyIdentifier: subject.readyIdentifier
      )
      try await capture(subject.slug, window: gallery.window)
    }
  }

  // MARK: - Captures

  @MainActor
  private func capture(_ name: String, window: XCUIElement) async throws {
    parkPointer(beside: window)
    waitForScreenToSettle(within: window.frame)
    try await PromoStill.capture(
      name,
      of: window,
      ownedBy: Self.bundleIdentifier,
      in: self
    )
  }

  /**
   The menu-bar panel, photographed off the screen inside the frame ScreenCaptureKit
   reports for it.

   Not captured as a window on its own like the rest: the panel is drawn in a
   material, and a material captured apart from what lies behind it renders as
   flat grey. On screen it lies over the staged backdrop, which is what it looks
   like on a light desktop. The frame is the panel's alone, without its shadow;
   brand.css rounds and shadows it.
   */
  @MainActor
  private func captureMenuBarPanel(_ panel: MenuBarPanelScreen) async throws {
    parkPointer(beside: panel.statusItem)
    waitForScreenToSettle(within: panel.searchArea)
    captureScreenRegion("menu-bar-panel", within: try await panelFrame())
  }

  /// Where macOS drew Zephyr's menu-bar panel, which is in no accessibility tree.
  private func panelFrame() async throws -> CGRect {
    let content = try await SCShareableContent.excludingDesktopWindows(
      true,
      onScreenWindowsOnly: true
    )
    let panels = content.windows.filter {
      Self.isZephyrs($0) && $0.windowLayer > 0 && $0.frame.height > Self.minimumPanelHeight
    }
    let panel = try XCTUnwrap(panels.first, "Zephyr's menu-bar panel is not on screen.")
    XCTAssertEqual(panels.count, 1, "More than one window looks like Zephyr's menu-bar panel.")
    return panel.frame
  }
}
