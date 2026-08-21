import Foundation
import Sentry
import Testing

@testable import libZephyr

@Suite("Redacting a crash report")
struct ReportRedactionTests {
  private let placeholder = ReportRedaction.placeholder

  @Test(
    "removes what a report must not carry",
    arguments: [
      "Couldn't read /Users/tim/Dropbox/Taxes 2025.pdf: no such file",
      "~/Library/Group Containers/group.codes.tim.Zephyr is gone",
      "file:///Users/tim/Dropbox/a%20b.txt could not be opened",
      "Upload rejected for /Quarterly Reports/Q3.numbers",
      "Couldn\u{2019}t read Receipts \u{203A} 2026 \u{203A} Ledger.numbers",
      "Account tim@example.com is unlinked",
      "Refreshing with sl.ABCDEFGHIJKLMNOPQRSTUVWXYZ012345 failed"
    ]
  )
  func stripsPathsAddressesAndTokens(_ message: String) {
    let redacted = ReportRedaction.redacted(message)
    #expect(redacted.contains(placeholder))
    for leak in [
      "Taxes", "Zephyr.Zephyr", "a%20b", "Quarterly", "Receipts", "Ledger", "tim@example.com",
      "sl.ABCDEF"
    ] {
      #expect(!redacted.contains(leak))
    }
  }

  @Test(
    "leaves alone what a report is triaged from",
    arguments: [
      "POST https://api.dropboxapi.com/2/files/upload_session/append_v2 failed with 429",
      "Retrying 3 of 5 after 1.5s",
      "The item is a folder and/or a symlink; N/A"
    ]
  )
  func keepsRoutesCountsAndPlainProse(_ message: String) {
    #expect(ReportRedaction.redacted(message) == message)
  }

  @Test("takes a path to the end of its line and no further")
  func stopsAtTheLineEnd() {
    let redacted = ReportRedaction.redacted("Trapped in /Taxes/2025.pdf\nwhile enumerating")
    #expect(redacted == "Trapped in \(placeholder)\nwhile enumerating")
  }

  @Test("reaches every string an event carries")
  func redactsAcrossAnEvent() {
    let event = Event()
    event.message = SentryMessage(formatted: "Failed on /Taxes/2025.pdf")
    let exception = Exception(value: "No such file: /Taxes/2025.pdf", type: "ItemSyncFailure")
    event.exceptions = [exception]
    event.extra = ["destination": "/Archive/2025", "attempt": 2]

    let redacted = ReportRedaction.redacting(event)

    #expect(redacted.message?.formatted == "Failed on \(placeholder)")
    #expect(redacted.exceptions?.first?.value == "No such file: \(placeholder)")
    #expect(redacted.exceptions?.first?.type == "ItemSyncFailure")
    #expect(redacted.extra?["destination"] as? String == placeholder)
    #expect(redacted.extra?["attempt"] as? Int == 2)
  }

  @Test("reaches a breadcrumb's message and its data")
  func redactsAcrossABreadcrumb() {
    let breadcrumb = Breadcrumb(level: .info, category: "transfers")
    breadcrumb.message = "Uploading /Taxes/2025.pdf"
    breadcrumb.setData(value: "/Taxes", key: "folder")
    breadcrumb.setData(value: 4096, key: "bytes")

    let redacted = ReportRedaction.redacting(breadcrumb)

    #expect(redacted.message == "Uploading \(placeholder)")
    #expect(redacted.data?["folder"] as? String == placeholder)
    #expect(redacted.data?["bytes"] as? Int == 4096)
  }
}
