import AppKit

/*
 A neutral, opaque backdrop for the system captures.

 The subjects in `capture-system-shots.sh` are surfaces macOS draws in Liquid
 Glass, and glass is contextual: a menu, a Control Center panel and a sheet all
 sample whatever sits behind them. Photograph one over a desktop and the desktop
 comes with it — the wallpaper's colour tints the whole panel, and any window
 left open behind it shows through. That is what makes an otherwise correct
 capture unpublishable, and it is not something cropping can undo.

 This paints a plain gradient across every screen at a level above the desktop
 and its icons but below ordinary windows, so the subject still floats over
 something and still refracts it, but what it refracts is chosen rather than
 whatever the machine happened to be showing. It holds until it is killed.
 */

let dark = CommandLine.arguments.contains("--dark")

/*
 How high to put it.

 Above the desktop is enough when the subject is a Finder window, which has to
 stay on top of this. It is not enough for Control Center or System Settings:
 their panels are translucent and reach across whatever else is on screen, and
 desktop widgets and stray windows draw above a desktop-level backdrop — so one
 half of a panel refracts the backdrop and the other half refracts the wallpaper,
 with a hard seam down the middle where they meet. Those subjects hide every app
 first and want this over the top of everything that is left.
 */
let aboveWindows = CommandLine.arguments.contains("--above-windows")

let app = NSApplication.shared

app.setActivationPolicy(.accessory)

/// Muted enough that the glass above it stays neutral, graded enough that the
/// material has something to refract and doesn't read as a flat fill.
func backdropColors() -> [CGColor] {
  dark
    ? [NSColor(calibratedWhite: 0.20, alpha: 1).cgColor, NSColor(calibratedWhite: 0.10, alpha: 1).cgColor]
    : [NSColor(calibratedWhite: 0.86, alpha: 1).cgColor, NSColor(calibratedWhite: 0.74, alpha: 1).cgColor]
}

final class BackdropView: NSView {
  override func draw(_: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext,
          let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                    colors: backdropColors() as CFArray,
                                    locations: [0, 1])
    else { return }
    context.drawLinearGradient(gradient,
                               start: CGPoint(x: 0, y: bounds.maxY),
                               end: CGPoint(x: 0, y: bounds.minY),
                               options: [])
  }
}

let backdropLevel = NSWindow.Level(
  rawValue: Int(CGWindowLevelForKey(aboveWindows ? .floatingWindow : .desktopIconWindow)) + 1
)

var windows: [NSWindow] = []

for screen in NSScreen.screens {
  let window = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                        backing: .buffered, defer: false, screen: screen)
  window.level = backdropLevel
  window.isOpaque = true
  window.ignoresMouseEvents = true
  window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
  window.contentView = BackdropView(frame: NSRect(origin: .zero, size: screen.frame.size))
  window.setFrame(screen.frame, display: true)
  window.orderFront(nil)
  windows.append(window)
}

print("backdrop up on \(windows.count) screen(s)")
fflush(stdout)
app.run()
