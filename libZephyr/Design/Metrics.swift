public import SwiftUI

/**
 The gaps Zephyr draws when the platform default is the wrong one.

 Almost every gap in the app is default — a stack with no `spacing:`, a bare
 `.padding()` — because the default adapts to the fonts on either side of it,
 which a frozen number cannot. What lives here is the short list of gaps that
 have to say something the default does not: that two lines are one line, or
 that one group has ended and another has begun.

 A value earns a place here by being *much* bigger or smaller than default for
 a structural or semantic reason. A gap that merely wants to be a few points
 different is a gap that should be default.

 Menu-bar panel metrics are deliberately not here: those describe an AppKit
 menu item rather than Zephyr's own rhythm, and they live beside the panel that
 draws them.
 */
public enum Metrics {
  /**
   Between a line and the smaller one under it, which read as one line in two
   parts rather than as two lines.

   Only for a pairing the default would loosen — heterogeneous children, or a
   list whose rows would stop reading as a list. Two plain `Text`s already sit
   this close at default, so they take no argument.
   */
  public static let tight: CGFloat = 2

  /// Between a line of text and the symbol that trails it, close enough that
  /// the symbol reads as part of the line rather than as its own element.
  public static let beforeTrailingSymbol: CGFloat = 4

  /// Between one group of content or controls and the next: twice default, so
  /// it reads as a break rather than as a nudge.
  public static let betweenGroups: CGFloat = 16

  /// Between a page's heading and the body it introduces — the one gap on a
  /// page that has to read as a page turning.
  public static let beforeBody: CGFloat = 24

  /// The inset every band of an extension sheet is laid out to, so the bands
  /// line up down the sheet.
  public static let sheetGutter: CGFloat = 14

  /// The inset the setup window leaves around whichever page it is showing.
  public static let pageInsets = EdgeInsets(top: 28, leading: 36, bottom: 28, trailing: 36)
}
