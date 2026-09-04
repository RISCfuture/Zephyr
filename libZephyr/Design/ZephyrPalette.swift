import AppKit
public import SwiftUI

/**
 Zephyr's palette, drawn from the aviation weather charts the app is named
 after.

 Backgrounds are never painted — every surface stays on a system material — so
 these colors carry only the mark's badge and the sync-status semantics.
 */
public enum ZephyrPalette {
  // periphery:ignore
  /**
   The accent: the blue of a low-altitude enroute chart.

   SwiftUI reads the accent from `AccentColor.colorset`, which no code can
   reference; this is where those two swatches are defined.
   */
  public static let blue = dynamic(light: 0x2C_6E_8F, dark: 0x5A_9C_BD)

  /// The badge's tint while files are moving.
  public static let active = dynamic(light: 0x3E_8F_B0, dark: 0x7F_B6_CE)

  /// Aviation caution amber, for items that couldn't sync.
  public static let caution = dynamic(light: 0xB0_66_16, dark: 0xE0_91_2F)

  /**
   Aviation warning red, for a failure that stopped an account outright — a
   step above ``caution``, which reports items the account survived.
   */
  public static let alert = dynamic(light: 0xA3_2A_1F, dark: 0xE0_6C_5C)

  /// The badge's tint at rest, and secondary linework.
  public static let idle = dynamic(light: 0x6C_7A_85, dark: 0x94_A3_AE)

  private static func dynamic(light: Int, dark: Int) -> Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor(hex: isDark ? dark : light)
      }
    )
  }
}

private extension NSColor {
  convenience init(hex: Int) {
    self.init(
      srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
      green: CGFloat((hex >> 8) & 0xFF) / 255,
      blue: CGFloat(hex & 0xFF) / 255,
      alpha: 1
    )
  }
}
