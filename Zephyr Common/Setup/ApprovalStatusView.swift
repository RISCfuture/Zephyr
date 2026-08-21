import SwiftUI
import libZephyr

/// Whether an approval has landed yet, reported where the user just acted.
struct ApprovalStatusView: View {
  let isGranted: Bool
  let waiting: LocalizedStringResource
  let granted: LocalizedStringResource

  /**
   The help topic for this page's approval, offered only while it is still
   waiting.

   Setup explains each approval where it asks for it, so a help button beside a
   granted one would answer a question nobody is asking. It appears when the
   page has said what to do and the user is looking at it having done that,
   which is the moment the fuller article — the one covering a prompt already
   refused — starts to earn its place.
   */
  let helpAnchor: HelpAnchor

  var body: some View {
    VStack(alignment: .leading) {
      Label {
        Text(isGranted ? granted : waiting)
      } icon: {
        Image(systemName: isGranted ? "checkmark.circle.fill" : "circle.dashed")
          .foregroundStyle(isGranted ? ZephyrPalette.active : Color.secondary)
      }
      .font(.callout)
      .foregroundStyle(.secondary)
      if !isGranted {
        HelpTopicButton(
          anchor: helpAnchor,
          accessibilityIdentifier: "setup.approvalHelp-\(helpAnchor.rawValue)"
        )
      }
    }
  }
}

#if DEBUG
  #Preview("Approval status") {
    VStack(alignment: .leading, spacing: 24) {
      ForEach([false, true], id: \.self) { isGranted in
        ApprovalStatusView(
          isGranted: isGranted,
          waiting: "Waiting for Zephyr to be switched on",
          granted: "Enabled. Your Dropbox is in Finder.",
          helpAnchor: .dropboxNotInFinder
        )
      }
    }
    .padding()
    .frame(width: 420)
  }
#endif
