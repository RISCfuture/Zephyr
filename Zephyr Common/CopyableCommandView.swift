import AppKit
import SwiftUI

/**
 A shell command shown for the user to run, with a button that copies it.

 Zephyr puts a command in front of the user where the sandbox stops it doing
 the work itself. A command that has to be retyped from a screenshot is a
 command that gets mistyped, so it is selectable, monospaced, and one click
 from the pasteboard.
 */
struct CopyableCommandView: View {
  /// How long the button acknowledges the copy before going back to offering
  /// one.
  private static let acknowledgementDuration = Duration.seconds(2)

  let command: String
  var commandIdentifier: String?
  var copyIdentifier: String?

  @State private var didCopy = false

  @ScaledMetric(relativeTo: .body)
  private var commandSize: CGFloat = 10

  private var copyTitle: LocalizedStringResource {
    didCopy
      ? LocalizedStringResource("Copied", bundle: #bundle)
      : LocalizedStringResource("Copy", bundle: #bundle)
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(command)
        .font(.system(size: commandSize, design: .monospaced))
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier(commandIdentifier ?? "")
      Spacer()
      Button(copyTitle) { copy() }
        .accessibilityIdentifier(copyIdentifier ?? "")
    }
  }

  private func copy() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(command, forType: .string)
    didCopy = true
    Task {
      try? await Task.sleep(for: Self.acknowledgementDuration)
      didCopy = false
    }
  }
}

#if DEBUG
  #Preview("Copyable command") {
    CopyableCommandView(command: "xattr -dr com.apple.quarantine \"/Applications/Zephyr.app\"")
      .frame(width: 420)
      .padding()
  }
#endif
