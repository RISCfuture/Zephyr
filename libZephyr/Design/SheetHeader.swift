import SwiftUI

/// The band at the top of an extension's sheet that says which app is asking.
///
/// An app extension's sheet is presented by the host — the share sheet, or
/// Finder — and carries none of the app's own chrome, so this is the only
/// thing telling the reader whose window they are looking at.
struct SheetHeader: View {
  private static let markSize: CGFloat = 15

  var body: some View {
    HStack(spacing: 5) {
      ZephyrMark(size: Self.markSize)
      Text("Zephyr", bundle: #bundle)
        .font(.system(size: 13, weight: .semibold))
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 7)
  }
}
