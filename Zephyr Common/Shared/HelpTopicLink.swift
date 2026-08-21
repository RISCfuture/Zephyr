import SwiftUI
import libZephyr

/**
 The system help button — a circled question mark — pointed at one topic in
 Zephyr's help book.

 Wraps `HelpLink` rather than replacing it: that is the real AppKit control,
 and hand-rolling one gets the metrics, the focus ring, and the hover
 treatment subtly wrong. What `HelpLink` doesn't supply is everything around
 it. It labels itself "Help", identically, however many are on screen — eight
 are, in the settings window — and it carries no identifier for the UI tests to
 find. Both come from the anchor's own ``HelpAnchor/accessibilityLabel`` and
 the caller's screen, and pairing them by hand at every call site is how they
 come apart.

 Inherits `controlSize` from its container, which is what lets the same view be
 a full-size button in a pane and a small one riding a `Section` header.
 */
struct HelpTopicLink: View {
  /// The topic in the book this button opens.
  let anchor: HelpAnchor

  /**
   Names the surface the button sits on, in the app's `<screen>.<control>`
   scheme — deliberately not derived from the anchor, which names a topic
   instead and is shared by every surface asking the same question.
   */
  let accessibilityIdentifier: String

  var body: some View {
    HelpLink(anchor: anchor.rawValue)
      .help(anchor.accessibilityLabel)
      .accessibilityLabel(anchor.accessibilityLabel)
      .accessibilityIdentifier(accessibilityIdentifier)
  }
}

#if DEBUG
  // Clicking does nothing here: a preview host registers no help book, so
  // `HelpLink` has nothing to open. This checks the metrics at both sizes a
  // caller's container can hand down.
  #Preview("Help topic link") {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        HelpTopicLink(anchor: .settingsBandwidth, accessibilityIdentifier: "preview.help")
        Text(verbatim: "Regular")
      }
      HStack {
        HelpTopicLink(anchor: .syncIssues, accessibilityIdentifier: "preview.help")
          .controlSize(.small)
        Text(verbatim: "Small")
      }
    }
    .padding()
  }
#endif
