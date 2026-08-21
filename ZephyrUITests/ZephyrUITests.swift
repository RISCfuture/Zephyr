import XCTest
import XCUITestKit

final class ZephyrUITests: XCTestCase {
  private static let codeTimeout: TimeInterval = ScaledTimeouts.scaled(900)
  private static let linkTimeout: TimeInterval = ScaledTimeouts.scaled(180)

  /// A code shaped like Dropbox's own but authorizing nothing, so submitting it
  /// reaches the same rejection a mistyped one does.
  private static let rejectedCode = "not-a-real-authorization-code"

  /// The accounts window's content size, pinned so the sheet over it is
  /// photographed at the same width however the window was last left.
  private static let windowSizes = ["Zephyr": CGSize(width: 560, height: 160)]

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  @MainActor
  func testSampleAccountsListAndUnlinkFlow() throws {
    let screen = MainScreen.launch(sampleAccounts: true)

    screen.accountRow(accountID: "dbid:preview-personal").assertExists()
    screen.accountRow(accountID: "dbid:preview-work").assertExists()
    screen.attachScreenshot(named: "accounts-list")

    screen.unlinkAccount(accountID: "dbid:preview-personal")

    screen.accountRow(accountID: "dbid:preview-personal").assertHidden()
    screen.accountRow(accountID: "dbid:preview-work").assertExists()
  }

  /**
   Walks the sheet's code fallback and the failure it can end in.

   Staged for capture, which is what keeps the run hermetic as much as it is
   what makes the attachments legible: a staged launch holds the trip to
   Dropbox inside the app, so a test run never flings the machine's browser at
   dropbox.com. Every state is attached as it is reached, so the sequence the
   sheet draws is readable from a test run rather than only from the app.
   */
  @MainActor
  func testLinkSheetWalksItsCodeFallbackAndCancels() throws {
    let screen = MainScreen.launch(
      sampleAccounts: true,
      appearance: .light,
      windowSizes: Self.windowSizes
    )

    let sheet = screen.openLinkSheet()
    XCTAssertTrue(sheet.waitUntilFlowReady())
    sheet.codeField.assertHidden("The code field must wait to be asked for")
    XCTAssertFalse(sheet.confirmButton.exists, "Link must wait for a code to link with")
    var previous = capture("link-sheet-1-connect", around: screen.window)

    sheet.revealCodeEntry()
    XCTAssertFalse(sheet.confirmButton.isEnabled, "Link must be disabled without a code")
    previous = capture("link-sheet-2-code-empty", around: screen.window, changedFrom: previous)

    sheet.openBrowser()
    sheet.enterCode(Self.rejectedCode)
    XCTAssertTrue(sheet.confirmButton.isEnabled, "Link must enable once a code is entered")
    previous = capture("link-sheet-3-code-entered", around: screen.window, changedFrom: previous)

    sheet.failToLink(timeout: Self.linkTimeout)
    sheet.codeField.assertExists("The sheet must keep the code for a retry")
    capture("link-sheet-4-rejected", around: screen.window, changedFrom: previous)

    let accounts = sheet.cancel()
    accounts.linkButton.assertExists("The accounts window did not come back")
  }

  /**
   Links a real Dropbox account through the app, end to end, by the sheet's code
   fallback.

   By the fallback and not by the button above it, which is the way a user links
   an account: that button opens an `ASWebAuthenticationSession`, which runs in
   another process and puts nothing in the app's accessibility tree for a test
   to drive. Both halves of the sheet end at the same token exchange with
   Dropbox, which is the part worth proving against the real service.

   Runs only when `ZEPHYR_UITEST_CODE_FILE` names a file path: the test opens
   the authorization page in the default browser, then waits for that file to
   appear and pastes its contents as the authorization code.
   */
  @MainActor
  func testLiveLinkThroughRealDropboxByPastedCode() throws {
    guard let codeFilePath = ProcessInfo.processInfo.environment["ZEPHYR_UITEST_CODE_FILE"] else {
      throw XCTSkip("Set ZEPHYR_UITEST_CODE_FILE to run the live link flow.")
    }

    let screen = MainScreen.launch(sampleAccounts: false)
    let sheet = screen.openLinkSheet()
    XCTAssertTrue(sheet.waitUntilFlowReady())
    sheet.revealCodeEntry()
    sheet.openBrowser()

    let code = try waitForCode(atPath: codeFilePath)
    sheet.enterCode(code)
    let accounts = sheet.confirmLink(timeout: Self.linkTimeout)

    accounts.accountRow(accountID: "dbid:AABz-XgvoTj7WeGRnZdbwQHgdAPhbL-hl8I")
      .assertExists("The linked account row never appeared", timeout: Self.linkTimeout)
    accounts.attachScreenshot(named: "linked-account")
  }

  private func waitForCode(atPath path: String) throws -> String {
    let appeared = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in FileManager.default.fileExists(atPath: path) },
      object: nil
    )
    guard XCTWaiter().wait(for: [appeared], timeout: Self.codeTimeout) == .completed else {
      throw XCTSkip("No authorization code arrived within \(Int(Self.codeTimeout)) seconds.")
    }
    let code = try String(contentsOfFile: path, encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    XCTAssertFalse(code.isEmpty, "The code file was empty")
    return code
  }
}
