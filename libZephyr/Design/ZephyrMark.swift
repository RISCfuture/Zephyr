import AppKit
import SwiftUI

/**
 How a ``ZephyrMark`` is colored: menu-bar marks stay monochrome so they read
 on any wallpaper and take the menu bar's own light, dark, and inactive
 treatments; everywhere else the badge carries Zephyr's color.
 */
public enum ZephyrMarkStyle: Sendable {
  /// Monochrome, so it reads on any wallpaper and takes the menu bar's own
  /// light, dark, and inactive treatments.
  case menuBar
  /// Badged in Zephyr's color, for everywhere but the menu bar.
  case branded
}

/**
 Zephyr's mark: the logomark the app icon is built from — a stack of sheets
 parted by the wind — badged with what an account's sync is doing.

 Ask for it without a reading wherever Zephyr is naming itself rather than
 reporting on an account. `size` is a point size, as a font's is: the mark
 covers about three quarters of it, and sits in a box as tall as a line of
 text set at the same size, so it lines up with the labels beside it.
 */
public struct ZephyrMark: View {
  private let activity: SyncActivity?
  private let style: ZephyrMarkStyle
  private let size: CGFloat

  @Environment(\.colorScheme)
  private var colorScheme

  public var body: some View {
    Image(nsImage: Self.image(activity, style: style, size: size, colorScheme: colorScheme))
      .accessibilityLabel(Self.label(activity))
  }

  /// The mark on its own, for the places Zephyr is naming itself.
  public init(size: CGFloat) {
    activity = nil
    style = .branded
    self.size = size
  }

  /// The mark badged with what an account's sync is doing.
  public init(_ activity: SyncActivity, style: ZephyrMarkStyle = .branded, size: CGFloat) {
    self.activity = activity
    self.style = style
    self.size = size
  }
}

// MARK: - Drawing

public extension ZephyrMark {
  /**
   The mark as an image — what a `MenuBarExtra` label needs, since a SwiftUI
   `Shape` doesn't render as one.

   A mark with no sync issues to report is a template image, so the menu bar
   inverts it for the wallpaper behind it and dims it while Zephyr isn't the
   active app. One reporting issues is drawn in caution amber instead, which is
   the whole point of it.

   `colorScheme` decides which half of each dynamic color the drawing gets.
   SwiftUI rasterizes an `NSImage` outside any window's appearance, so it is
   the only thing that tells `labelColor` and ``ZephyrPalette`` whether they
   are being drawn onto a light surface or a dark one.
   */
  static func image(
    _ activity: SyncActivity?,
    style: ZephyrMarkStyle = .branded,
    size: CGFloat,
    colorScheme: ColorScheme
  ) -> NSImage {
    let mark = Self.symbol(Self.markSymbolName, in: #bundle, size: size, weight: .regular)
    let badge = activity.flatMap {
      Self.symbol(
        Self.badgeSymbolName(for: $0.state),
        in: nil,
        size: size * Self.badgeScale,
        weight: .semibold
      )
    }
    guard let mark else { return NSImage() }

    let palette = Self.palette(style, activity)
    let canvas = Self.canvas(mark: mark, badge: badge)
    let appearance = Self.appearance(for: colorScheme)
    let image = NSImage(size: canvas, flipped: false) { _ in
      var drawn = false
      appearance.performAsCurrentDrawingAppearance {
        drawn = Self.draw(mark: mark, badge: badge, palette: palette, in: canvas, size: size)
      }
      return drawn
    }
    image.isTemplate = palette == nil
    image.accessibilityDescription = Self.label(activity)
    return image
  }
}

private extension ZephyrMark {
  static let markSymbolName = "zephyr.logomark"

  /// The badge's point size, as a share of the mark's.
  static let badgeScale = 0.50

  /// The clearance bitten out of the mark around the badge, as a share of the
  /// mark's point size, so the two never touch.
  static let badgeClearance = 0.073

  /// How far the badge hangs past the mark's trailing edge, as a share of the
  /// badge's own width.
  static let badgeOverhang = 0.34

  /// What the mark says it is: the reading it carries, or Zephyr's name where
  /// it carries none.
  static func label(_ activity: SyncActivity?) -> String {
    activity?.summary ?? String(localized: "Zephyr", bundle: #bundle)
  }

  static func badgeSymbolName(for state: SyncActivity.State) -> String {
    switch state {
      case .needsSetup: "ellipsis.circle.fill"
      case .syncing: "arrow.trianglehead.2.clockwise.rotate.90.circle.fill"
      case .upToDate: "checkmark.circle.fill"
      case .issues: "xmark.circle.fill"
      case .waitingForCheaperNetwork: "pause.circle.fill"
      case .offline: "bolt.horizontal.circle.fill"
    }
  }

  /// What the mark and its badge are painted with, or `nil` to leave the whole
  /// composite a template image for the menu bar to color itself.
  static func palette(_ style: ZephyrMarkStyle, _ activity: SyncActivity?) -> (
    mark: NSColor, badge: NSColor
  )? {
    switch style {
      case .menuBar:
        guard activity?.hasIssues == true else { return nil }
        let caution = NSColor(ZephyrPalette.caution)
        return (caution, caution)
      case .branded:
        return (.labelColor, NSColor(badgeColor(for: activity?.state)))
    }
  }

  static func badgeColor(for state: SyncActivity.State?) -> Color {
    switch state {
      case .syncing: ZephyrPalette.active
      case .issues: ZephyrPalette.caution
      // None of an outage, a deliberate wait, or an unfinished setup is a
      // fault, so all are painted like rest rather than like alarm: the badge
      // says why nothing is moving, without asking.
      case .offline, .waitingForCheaperNetwork, .upToDate, .needsSetup, nil: ZephyrPalette.idle
    }
  }

  /// The appearance the mark's dynamic colors resolve against while it draws.
  static func appearance(for colorScheme: ColorScheme) -> NSAppearance {
    NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua) ?? .currentDrawing()
  }

  static func symbol(_ name: String, in bundle: Bundle?, size: CGFloat, weight: NSFont.Weight)
    -> NSImage?
  {
    let image =
      bundle.map { NSImage(symbolName: name, bundle: $0, variableValue: 1) }
      ?? NSImage(systemSymbolName: name, accessibilityDescription: nil)
    return image?.withSymbolConfiguration(.init(pointSize: size, weight: weight))
  }

  static func canvas(mark: NSImage, badge: NSImage?) -> NSSize {
    NSSize(
      width: mark.size.width + (badge.map { $0.size.width * badgeOverhang } ?? 0),
      height: mark.size.height
    )
  }

  /// Draws the mark, bites the badge's clearance out of it, then drops the
  /// badge into the hole.
  static func draw(
    mark: NSImage,
    badge: NSImage?,
    palette: (mark: NSColor, badge: NSColor)?,
    in canvas: NSSize,
    size: CGFloat
  ) -> Bool {
    guard let context = NSGraphicsContext.current?.cgContext else { return false }
    let markRect = NSRect(origin: .zero, size: mark.size)
    mark.draw(in: markRect)
    if let palette { tint(markRect, palette.mark) }

    guard let badge else { return true }
    let badgeRect = NSRect(
      x: canvas.width - badge.size.width,
      y: 0,
      width: badge.size.width,
      height: badge.size.height
    )
    let hole = badgeRect.insetBy(dx: -size * badgeClearance, dy: -size * badgeClearance)
    context.setBlendMode(.destinationOut)
    // Whatever tinted the mark may be less than fully opaque, and a partly
    // opaque bite leaves a ghost of the mark behind the badge.
    context.setFillColor(NSColor.black.cgColor)
    context.fillEllipse(in: hole)
    context.setBlendMode(.normal)

    // Clipped to the hole, because the badge's own box is square: its corners
    // still hold mark, and tinting them would paint the mark's edge the
    // badge's color.
    context.saveGState()
    context.addEllipse(in: hole)
    context.clip()
    badge.draw(in: badgeRect)
    if let palette { tint(badgeRect, palette.badge) }
    context.restoreGState()
    return true
  }

  static func tint(_ rect: NSRect, _ color: NSColor) {
    color.set()
    rect.fill(using: .sourceAtop)
  }
}

/// Every reading the mark can carry, at every size and style it is drawn at.
private struct ZephyrMarkGallery: View {
  private static let readings: [(String, SyncActivity)] = [
    ("Syncing", SyncActivity(latestChange: Date(), hasIssues: false)),
    ("Up to date", .idle),
    ("Sync issues", SyncActivity(latestChange: nil, hasIssues: true))
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      ForEach(Self.readings, id: \.0) { name, activity in
        HStack(spacing: 20) {
          ZephyrMark(activity, size: 56)
          ZephyrMark(activity, size: 20)
          ZephyrMark(activity, style: .menuBar, size: 18)
          Text(name)
        }
      }
      HStack(spacing: 20) {
        ZephyrMark(size: 56)
        ZephyrMark(size: 20)
        Text("No reading")
      }
    }
    .padding(40)
  }
}

#Preview("Zephyr mark") {
  ZephyrMarkGallery()
}

#Preview("Zephyr mark, dark") {
  ZephyrMarkGallery()
    .preferredColorScheme(.dark)
}
