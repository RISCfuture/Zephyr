import SwiftUI
import libZephyr

/**
 A settings `Section` header with the topic's help button on its trailing edge.

 macOS puts a pane's help button in the window's bottom-trailing corner, which
 works when a settings window is a set of panes. Zephyr's is one scrolling
 `Form`: a single button there could only ever point at one topic for all eight
 sections, and the reader who wants the one about transfer limits is looking at
 the transfer limits, not at the corner. Putting the button on the section it
 explains is what keeps a help button a promise about what it will open.

 `controlSize(.small)` is not decoration. A grouped `Form` sets its headers in
 secondary text, and a full-size bezel against that reads as a control the
 section owns rather than an affordance beside its name.
 */
struct SectionHeader: View {
  private let title: LocalizedStringResource
  private let anchor: HelpAnchor
  private let accessibilityIdentifier: String

  var body: some View {
    HStack {
      Text(title)
      Spacer(minLength: 0)
      HelpTopicLink(anchor: anchor, accessibilityIdentifier: accessibilityIdentifier)
        .controlSize(.small)
    }
  }

  /**
   Creates a section header that offers one help topic.

   - Parameters:
     - title: The section's name.
     - help: The topic in the help book that explains this section.
     - accessibilityIdentifier: Names the section, in the app's
       `<screen>.<control>` scheme, so a test can tell eight otherwise
       identical buttons apart.
   */
  init(
    _ title: LocalizedStringResource,
    help anchor: HelpAnchor,
    accessibilityIdentifier: String
  ) {
    self.title = title
    self.anchor = anchor
    self.accessibilityIdentifier = accessibilityIdentifier
  }
}

#if DEBUG
  #Preview("Section header") {
    Form {
      Section {
        Toggle(isOn: .constant(true)) {
          Text(verbatim: "Launch at login")
        }
      } header: {
        SectionHeader(
          LocalizedStringResource("General", bundle: #bundle),
          help: .settingsGeneral,
          accessibilityIdentifier: "preview.help"
        )
      }
    }
    .formStyle(.grouped)
    .frame(width: 460)
  }
#endif
