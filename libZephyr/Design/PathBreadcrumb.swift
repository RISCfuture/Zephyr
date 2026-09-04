public import SwiftUI

/**
 A path shown the way the Finder shows one: its components divided by chevrons,
 the chevrons a shade lighter than the names they separate.

 Every component stays. Where the row is too narrow the earlier ones give up
 their width first and the last keeps its whole name, because the last is what
 the reader came for -- which is what the Finder's own Go to Folder list does,
 and what no single truncated string can do: ask one `Text` to elide a path and
 it cuts wherever the glyphs happen to land, taking half of one name and all of
 another.

 A menu row or a tooltip cannot lay out a view; those want
 ``DropboxPath/breadcrumb``, which writes the same path into a string.
 */
public struct PathBreadcrumb: View {
  /// The gap either side of a chevron -- narrower than a space, so the eye
  /// groups each name with itself rather than with the divider beside it.
  private static let dividerSpacing: CGFloat = 4

  private let path: DropboxPath

  public var body: some View {
    HStack(spacing: Self.dividerSpacing) {
      ForEach(Array(path.components.enumerated()), id: \.offset) { position, component in
        if position > 0 {
          Text(verbatim: "\u{203A}")
            .foregroundStyle(.secondary)
        }
        PathComponentNameView(component)
          .layoutPriority(isLast(position) ? 1 : 0)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(path.displayPath)
  }

  /// Shows `path` as its components, chevron-divided.
  public init(_ path: DropboxPath) {
    self.path = path
  }

  /// Whether the component at `position` is the one the path names, which is
  /// the one that keeps its width when there is not enough to go round.
  private func isLast(_ position: Int) -> Bool {
    position == path.components.count - 1
  }
}

/**
 One name in a path, which fades out where it is too wide for the room it was
 given rather than ending in an ellipsis.

 A row of ellipses reads as damage -- five names cut to `Alp…` say far less
 than five names cut to `Alp`, and cost a character each to say it. So the name
 is laid out as though it would be truncated, which is what earns it a width
 from the row, and then drawn whole over that width and masked away at the
 edge. A name that fits is drawn untouched: the fade appears only where
 something was actually lost.
 */
private struct PathComponentNameView: View {
  /// How much wider than its room a name has to be before it counts as cut,
  /// so rounding between the measured and the laid-out width doesn't fade a
  /// name that fits.
  private static let widthTolerance: CGFloat = 0.5

  private let name: String

  @State private var givenWidth: CGFloat = 0
  @State private var wholeWidth: CGFloat = 0

  /// Whether the name was given less room than it needs.
  private var isCut: Bool { wholeWidth > givenWidth + Self.widthTolerance }

  var body: some View {
    Text(name)
      .lineLimit(1)
      .truncationMode(.tail)
      .hidden()
      .onGeometryChange(for: CGFloat.self) {
        $0.size.width
      } action: {
        givenWidth = $0
      }
      .overlay(alignment: .leading) {
        Text(name)
          .lineLimit(1)
          .fixedSize()
          .onGeometryChange(for: CGFloat.self) {
            $0.size.width
          } action: {
            wholeWidth = $0
          }
          .mask(alignment: .leading) {
            PathComponentFadeView(isCut: isCut, givenWidth: givenWidth)
          }
      }
      .clipped()
  }

  init(_ name: String) {
    self.name = name
  }
}

/// Opaque over the name, thinning to nothing at the edge where it was cut.
private struct PathComponentFadeView: View {
  /// How far in from the edge the name starts fading. Roughly a character, so
  /// the cut reads as a cut without swallowing a whole letter.
  private static let fadeWidth: CGFloat = 13

  let isCut: Bool
  let givenWidth: CGFloat

  var body: some View {
    if isCut, givenWidth > 0 {
      LinearGradient(
        stops: [
          .init(color: .black, location: 0),
          .init(color: .black, location: max(0, (givenWidth - Self.fadeWidth) / givenWidth)),
          .init(color: .clear, location: 1)
        ],
        startPoint: .leading,
        endPoint: .trailing
      )
      .frame(width: givenWidth)
    } else {
      Color.black
    }
  }
}

#if DEBUG
  // The paths are fixed literals from this file, so a validation failure is a
  // typo in the sample data.
  // swiftlint:disable:next force_try
  private func samplePath(_ raw: String) -> DropboxPath { try! DropboxPath(validating: raw) }

  #Preview("Narrowing a deep path") {
    VStack(alignment: .leading, spacing: 10) {
      ForEach([200.0, 300.0, 440.0], id: \.self) { width in
        PathBreadcrumb(
          samplePath("/Clients/Northwind, LLC/Receipts for Reimbursements/2026/Q3.numbers")
        )
        .frame(width: width, alignment: .leading)
      }
    }
    .padding()
  }

  #Preview("Paths that fit, which never fade") {
    VStack(alignment: .leading, spacing: 10) {
      PathBreadcrumb(samplePath("/Movies/dive trip.mov"))
      PathBreadcrumb(samplePath("/plan.key"))
    }
    .padding()
  }
#endif
