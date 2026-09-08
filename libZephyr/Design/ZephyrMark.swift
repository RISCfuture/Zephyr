import AppKit
public import SwiftUI

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

 A syncing badge turns, so its arrows chase each other for as long as there is
 work in flight. It holds still under Reduce Motion, where the badge's shape,
 its color, and the summary beside it carry the reading on their own.
 */
public struct ZephyrMark: View {
  /// How long a syncing badge takes to come back round. Its two arrowheads sit
  /// half a turn apart, so this is two arrivals a second — work being done,
  /// rather than a strobe in something that is on screen permanently.
  nonisolated public static let badgeRevolution: TimeInterval = 2

  private let activity: SyncActivity?
  private let style: ZephyrMarkStyle
  private let size: CGFloat

  @Environment(\.colorScheme)
  private var colorScheme

  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  @Environment(\.zephyrMarksTurn)
  private var marksTurn

  public var body: some View {
    let parts = Self.parts(activity, style: style, size: size, colorScheme: colorScheme)
    BadgedMark(
      mark: parts.mark,
      badge: parts.badge,
      isTurning: isTurning,
      label: Self.label(activity)
    )
  }

  /// Whether the badge turns: a sync is running, and motion is welcome.
  private var isTurning: Bool { activity?.state == .syncing && !reduceMotion && marksTurn }

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

public extension EnvironmentValues {
  /**
   Whether a syncing ``ZephyrMark`` may turn, for the surfaces that need one
   still for a reason of their own — a screenshot that has to settle, or a
   preview of how the mark rests.

   Reduce Motion holds the badge still on its own; this is the other half of
   the same question, and either answer stops it.
   */
  @Entry var zephyrMarksTurn: Bool = true
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

   `badgeRotation` turns the badge in its hole, for the one caller that has to
   play a turn out of still images: see ``ZephyrMarkFilmstrip``.
   */
  static func image(
    _ activity: SyncActivity?,
    style: ZephyrMarkStyle = .branded,
    size: CGFloat,
    colorScheme: ColorScheme,
    badgeRotation: Angle = .zero
  ) -> NSImage {
    guard let symbols = Self.symbols(activity, size: size) else { return NSImage() }

    let layout = ZephyrMarkLayout(mark: symbols.mark, badge: symbols.badge, size: size)
    let palette = Self.palette(style, activity)
    let appearance = Self.appearance(for: colorScheme)
    let image = NSImage(size: layout.canvas, flipped: false) { _ in
      var drawn = false
      appearance.performAsCurrentDrawingAppearance {
        drawn = Self.draw(symbols, palette: palette, in: layout, turnedBy: badgeRotation)
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

  /// The mark's glyph and its badge's, each rasterized at the size it is drawn
  /// at — the boxes ``ZephyrMarkLayout`` arranges. A symbol's box isn't its
  /// point size, so there is nothing to lay out until they exist.
  static func symbols(_ activity: SyncActivity?, size: CGFloat)
    -> (mark: NSImage, badge: NSImage?)?
  {
    guard let mark = Self.symbol(Self.markSymbolName, in: #bundle, size: size, weight: .regular)
    else { return nil }
    let badge = activity.flatMap {
      Self.symbol(
        Self.badgeSymbolName(for: $0.state),
        in: nil,
        size: size * Self.badgeScale,
        weight: .semibold
      )
    }
    return (mark, badge)
  }

  static func symbol(_ name: String, in bundle: Bundle?, size: CGFloat, weight: NSFont.Weight)
    -> NSImage?
  {
    let image =
      bundle.map { NSImage(symbolName: name, bundle: $0, variableValue: 1) }
      ?? NSImage(systemSymbolName: name, accessibilityDescription: nil)
    return image?.withSymbolConfiguration(.init(pointSize: size, weight: weight))
  }

  /**
   The mark and its badge as separate layers, for the views that turn one over
   the other.

   The mark layer fills the whole composite with the badge's clearance already
   bitten out of it, and the badge layer is exactly the box the layout puts in
   the composite's bottom-trailing corner — so a view lands the badge on its
   hole by alignment alone, with no arithmetic of its own to drift.
   */
  static func parts(
    _ activity: SyncActivity?,
    style: ZephyrMarkStyle,
    size: CGFloat,
    colorScheme: ColorScheme
  ) -> (mark: NSImage, badge: NSImage?) {
    guard let symbols = Self.symbols(activity, size: size) else { return (NSImage(), nil) }

    let layout = ZephyrMarkLayout(mark: symbols.mark, badge: symbols.badge, size: size)
    let palette = Self.palette(style, activity)
    let appearance = Self.appearance(for: colorScheme)
    let mark = NSImage(size: layout.canvas, flipped: false) { _ in
      var drawn = false
      appearance.performAsCurrentDrawingAppearance {
        drawn = Self.drawMark(symbols.mark, tinted: palette?.mark, in: layout)
      }
      return drawn
    }
    mark.isTemplate = palette == nil
    mark.accessibilityDescription = Self.label(activity)

    guard let badgeSymbol = symbols.badge, let placement = layout.badge else { return (mark, nil) }
    let badge = NSImage(size: placement.rect.size, flipped: false) { bounds in
      appearance.performAsCurrentDrawingAppearance {
        Self.drawBadge(badgeSymbol, tinted: palette?.badge, in: bounds)
      }
      return true
    }
    badge.isTemplate = palette == nil
    return (mark, badge)
  }

  /// Draws the mark, bites the badge's clearance out of it, then drops the
  /// badge into the hole, turned by `rotation`.
  static func draw(
    _ symbols: (mark: NSImage, badge: NSImage?),
    palette: (mark: NSColor, badge: NSColor)?,
    in layout: ZephyrMarkLayout,
    turnedBy rotation: Angle
  ) -> Bool {
    guard drawMark(symbols.mark, tinted: palette?.mark, in: layout) else { return false }
    guard let badge = symbols.badge, let placement = layout.badge else { return true }
    drawBadge(badge, tinted: palette?.badge, into: placement, turnedBy: rotation)
    return true
  }

  /// Draws the mark, and takes the badge's clearance back out of it so the two
  /// never touch.
  static func drawMark(_ mark: NSImage, tinted color: NSColor?, in layout: ZephyrMarkLayout)
    -> Bool
  {
    guard let context = NSGraphicsContext.current?.cgContext else { return false }
    mark.draw(in: layout.markRect)
    if let color { tint(layout.markRect, color) }

    guard let placement = layout.badge else { return true }
    context.setBlendMode(.destinationOut)
    // Whatever tinted the mark may be less than fully opaque, and a partly
    // opaque bite leaves a ghost of the mark behind the badge.
    context.setFillColor(NSColor.black.cgColor)
    context.fillEllipse(in: placement.clearance)
    context.setBlendMode(.normal)
    return true
  }

  /// Drops the badge into the hole the mark left, turned by `rotation` about
  /// the hole's own center.
  static func drawBadge(
    _ badge: NSImage,
    tinted color: NSColor?,
    into placement: ZephyrMarkLayout.Badge,
    turnedBy rotation: Angle
  ) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    context.saveGState()
    defer { context.restoreGState() }

    // Clipped to the hole, because the badge's own box is square: its corners
    // still hold mark, and tinting them would paint the mark's edge the
    // badge's color. Clipping ahead of the turn keeps the hole still while the
    // glyph turns inside it.
    context.addEllipse(in: placement.clearance)
    context.clip()

    let center = CGPoint(x: placement.rect.midX, y: placement.rect.midY)
    context.translateBy(x: center.x, y: center.y)
    // An image drawn `flipped: false` is drawn y-up, where a positive angle
    // turns counter-clockwise — the way `rotationEffect` turns for a negative
    // one. Turning back is what makes the drawn badge and the turned view
    // agree on which way round a revolution goes.
    context.rotate(by: -rotation.radians)
    context.translateBy(x: -center.x, y: -center.y)
    drawBadge(badge, tinted: color, in: placement.rect)
  }

  /// Paints the badge on its own, for the layer a view turns.
  static func drawBadge(_ badge: NSImage, tinted color: NSColor?, in rect: NSRect) {
    badge.draw(in: rect)
    if let color { tint(rect, color) }
  }

  static func tint(_ rect: NSRect, _ color: NSColor) {
    color.set()
    rect.fill(using: .sourceAtop)
  }
}

// MARK: - Layout

/**
 Where a badged mark's parts sit: the box the whole composite fills, the box
 the mark is drawn in, and where the badge lands in it.

 The badge is anchored to the composite's bottom-trailing corner, and its
 clearance is concentric with it — so a badge turns about the middle of its own
 hole, and a view lays a turning badge over a still mark by alignment alone,
 with no second copy of this arithmetic to drift from this one.
 */
private struct ZephyrMarkLayout {
  /// The clearance bitten out of the mark around the badge, as a share of the
  /// mark's point size, so the two never touch.
  private static let clearanceScale = 0.073

  /// How far the badge hangs past the mark's trailing edge, as a share of the
  /// badge's own width.
  private static let overhang = 0.34

  let canvas: NSSize
  let markRect: NSRect
  let badge: Badge?

  init(mark: NSImage, badge badgeSymbol: NSImage?, size: CGFloat) {
    let markRect = NSRect(origin: .zero, size: mark.size)
    let canvas = NSSize(
      width: markRect.width + (badgeSymbol.map { $0.size.width * Self.overhang } ?? 0),
      height: markRect.height
    )
    self.markRect = markRect
    self.canvas = canvas
    badge = badgeSymbol.map { symbol in
      let rect = NSRect(
        x: canvas.width - symbol.size.width,
        y: 0,
        width: symbol.size.width,
        height: symbol.size.height
      )
      let clearance = size * Self.clearanceScale
      return Badge(rect: rect, clearance: rect.insetBy(dx: -clearance, dy: -clearance))
    }
  }

  /// Where the badge is drawn, and the hole bitten out of the mark for it.
  struct Badge {
    let rect: NSRect
    let clearance: NSRect
  }
}

// MARK: - Turning

/**
 The mark with its badge laid into the hole bitten for it, the badge a layer of
 its own so a syncing one can turn while the mark holds still.

 The badge needs no placing beyond the corner it belongs in: the mark image is
 the whole composite and the badge image is exactly the box ``ZephyrMarkLayout``
 puts in that corner, so the two register by construction.
 */
private struct BadgedMark: View {
  let mark: NSImage
  let badge: NSImage?
  let isTurning: Bool
  let label: String

  var body: some View {
    Image(nsImage: mark)
      .accessibilityLabel(label)
      .overlay(alignment: .bottomTrailing) {
        if let badge {
          if isTurning {
            TurningBadge(badge: badge)
          } else {
            BadgeLayer(badge: badge)
          }
        }
      }
  }
}

/// The badge as it rests, laid over the hole the mark left for it.
private struct BadgeLayer: View {
  let badge: NSImage

  var body: some View {
    Image(nsImage: badge)
      // The mark beside it already says what the reading is, and two images
      // here would be two elements where there is one.
      .accessibilityHidden(true)
  }
}

/**
 The badge while a sync runs, turning linearly and forever — which is what
 reads as turning at all, an eased revolution reading as a stutter and a
 reversed one as arrows retreating.

 It is a view of its own so that the turn ends when the sync does. An animation
 that repeats forever outlives the modifier that asked for it: handed a badge
 that has meanwhile become a checkmark, it keeps the revolution and spends it
 dissolving one glyph into the other, over and over. Nothing calls it off but
 taking the view away.
 */
private struct TurningBadge: View {
  let badge: NSImage

  @State private var turn = Angle.zero

  var body: some View {
    BadgeLayer(badge: badge)
      .rotationEffect(turn)
      .onAppear {
        let revolution = Animation.linear(duration: ZephyrMark.badgeRevolution)
        withAnimation(revolution.repeatForever(autoreverses: false)) {
          turn = .degrees(360)
        }
      }
  }
}

/**
 The frames of a syncing mark's turn, for the menu bar — where the status
 item's label has to be an `NSImage`, and an image is not something a view can
 turn in place.

 The strip is drawn once and played for as long as the sync lasts. Every
 revolution is the same handful of small bitmaps, and rasterizing one per tick
 would redraw the whole mark just to move the badge.
 */
public struct ZephyrMarkFilmstrip {
  /// How many frames a revolution is cut into. Fifteen degrees apart is below
  /// where a glyph this small starts reading as stepping rather than turning.
  private static let frameCount = 24

  /// How long a frame stays up.
  public static let frameInterval: TimeInterval =
    ZephyrMark.badgeRevolution / Double(frameCount)

  private let frames: [NSImage]

  /// Draws every frame of the turn, at the one size, style, and appearance the
  /// strip will be played at.
  @MainActor
  public init(
    _ activity: SyncActivity,
    style: ZephyrMarkStyle = .branded,
    size: CGFloat,
    colorScheme: ColorScheme
  ) {
    frames = (0..<Self.frameCount).map { frame in
      ZephyrMark.image(
        activity,
        style: style,
        size: size,
        colorScheme: colorScheme,
        badgeRotation: .degrees(360 * Double(frame) / Double(Self.frameCount))
      )
    }
  }

  /**
   Which of `count` frames a moment falls in.

   How far into a revolution the clock is picks the frame, rather than a tally
   of ticks: a tick the system coalesces away then drops a frame instead of
   stretching the turn, and two marks started at different moments turn
   together rather than each from its own zero.
   */
  static func frameIndex(at date: Date, of count: Int) -> Int {
    let turns = date.timeIntervalSinceReferenceDate / ZephyrMark.badgeRevolution
    // The fraction is taken by subtracting the floor rather than by remainder,
    // which is negative for the dates before the reference date that a clock
    // set wrong can hand us — and a negative index is a trap, not a wrong
    // pixel. The clamp covers a fraction that rounds up to a whole turn.
    return min(Int((turns - turns.rounded(.down)) * Double(count)), count - 1)
  }

  /// The frame `date` falls in.
  public func frame(at date: Date) -> NSImage {
    frames[Self.frameIndex(at: date, of: frames.count)]
  }
}

// MARK: - Previews

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

/**
 The drawn turn beside the turned one: every frame of a revolution laid out in
 order, over the same mark played as the menu bar plays it and turned as a view
 turns it.

 This is the only place the drawn rotation can be checked without launching the
 app — that the badge stays centered in its hole at every angle, and that all
 three turn the same way round.
 */
private struct ZephyrMarkFilmstripGallery: View {
  private static let size: CGFloat = 44
  private static let activity = SyncActivity(latestChange: Date(), hasIssues: false)
  private static let frameCount = 12

  @Environment(\.colorScheme)
  private var colorScheme

  var body: some View {
    let filmstrip = ZephyrMarkFilmstrip(Self.activity, size: Self.size, colorScheme: colorScheme)
    VStack(alignment: .leading, spacing: 24) {
      HStack(spacing: 24) {
        ZephyrMark(Self.activity, size: Self.size)
        TimelineView(.periodic(from: .now, by: ZephyrMarkFilmstrip.frameInterval)) { context in
          Image(nsImage: filmstrip.frame(at: context.date))
            .accessibilityHidden(true)
        }
        Text(verbatim: "Turned by a view, then played from the strip")
      }
      HStack(spacing: 8) {
        ForEach(0..<Self.frameCount, id: \.self) { frame in
          Image(
            nsImage: ZephyrMark.image(
              Self.activity,
              size: Self.size,
              colorScheme: colorScheme,
              badgeRotation: .degrees(360 * Double(frame) / Double(Self.frameCount))
            )
          )
          .accessibilityHidden(true)
        }
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

#Preview("Zephyr mark, held still") {
  ZephyrMarkGallery()
    .environment(\.zephyrMarksTurn, false)
}

#Preview("Zephyr mark, turning") {
  ZephyrMarkFilmstripGallery()
}
