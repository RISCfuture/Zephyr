#if DEBUG
  import AppKit

  /**
   Stages the app for the screenshots the marketing site and the App Store
   listing ship: pins the appearance, pins the accounts window's size, and puts
   a plain backdrop behind every window so nothing of the developer's desktop
   reaches a published image.

   Everything here is gated on `UITEST_SCREENSHOTS`, which only the screenshot
   suite sets, so every other UI test launches exactly as it does without this
   file.

   A test configures the staging through two more launch environment values:
   - `UITEST_APPEARANCE` — `light` or `dark`, the appearance the whole process
     is pinned to.
   - `UITEST_WINDOW_SIZES` — content sizes to pin windows to, by title, as
     `"Zephyr=560x160;Sync Issues=560x160"`.
   */
  @MainActor
  enum ScreenshotStaging {

    /// Retained so the observers below outlive ``install()``.
    private static var observers: [any NSObjectProtocol] = []

    /// The full-screen fill drawn behind the app's windows.
    private static var backdrop: NSWindow?

    /// The windows already sized, by title, so each is pinned once.
    private static var sizedWindowTitles: Set<String> = []

    /// Whether the design gallery's window has been given the title bar it takes
    /// key with, which is done once and not on every activation.
    private static var hasGalleryTakenKey = false

    /// Whether the running launch is capturing screenshots.
    static var isEnabled: Bool {
      ProcessInfo.processInfo.environment["UITEST_SCREENSHOTS"] == "1"
    }

    /**
     Whether reaching Dropbox may really leave the app — for the web
     authentication session the link form opens, or for the browser its code
     fallback opens.

     A staged run's captures are of Zephyr alone on a plain backdrop, and the
     authorization page would arrive in front of both — taking key away from
     the sheet being photographed, and putting the developer's browser into
     every image behind it. The form still does everything else it would; only
     the trip out of the app is held back.
     */
    static var opensDropbox: Bool { !isEnabled }

    /**
     The appearance to pin. An unrecognized value is a mistake in the test, not
     a reason to capture a set in whichever appearance the machine happens to
     be in, so it stops the run.
     */
    private static var appearance: Appearance {
      guard let raw = ProcessInfo.processInfo.environment["UITEST_APPEARANCE"] else {
        return .light
      }
      guard let appearance = Appearance(rawValue: raw) else {
        preconditionFailure("Unrecognized UITEST_APPEARANCE “\(raw)”.")
      }
      return appearance
    }

    /**
     The content sizes to pin, by window title, or empty when the test didn't
     ask for any. A malformed value would silently publish a differently-sized
     image, so it stops the run instead.
     */
    private static var windowSizes: [String: CGSize] {
      guard let raw = ProcessInfo.processInfo.environment["UITEST_WINDOW_SIZES"] else { return [:] }
      return Dictionary(uniqueKeysWithValues: raw.split(separator: ";").map(windowSize(from:)))
    }

    /**
     Stages the process for capture. Called from ``ZephyrScenes/init(featureFlags:updates:)``,
     which runs while SwiftUI is bringing the application up, so nothing here
     may touch `NSApplication` itself: reaching for `NSApplication.shared` is
     what *creates* the application object, and an app SwiftUI did not make is
     one it puts no window on screen for. This only subscribes to the launch
     AppKit is about to perform.
     */
    static func install() {
      guard isEnabled else { return }
      stageAsAppKitLaunches()
      pinWindowSizes()
    }

    /**
     Pins the appearance and installs the backdrop as AppKit launches.

     `willFinishLaunching` is the first moment the appearance can be set safely
     and still before anything has been drawn; `didFinishLaunching` is the
     earliest a window can be ordered onto the screen, and it re-pins because
     AppKit sets the appearance itself as it finishes launching. The third
     re-pin, as the first window takes key, is the one that holds if SwiftUI
     evaluates the scene after AppKit has already finished launching — in which
     case neither notification above is ever posted.
     */
    private static func stageAsAppKitLaunches() {
      observe(NSApplication.willFinishLaunchingNotification) { pinAppearance() }
      observe(NSApplication.didFinishLaunchingNotification) {
        pinAppearance()
        installBackdrop()
      }
      observe(NSWindow.didBecomeKeyNotification) {
        pinAppearance()
        installBackdrop()
      }
      observe(NSApplication.didBecomeActiveNotification) {
        raiseWindowsAboveBackdrop()
        letTheDesignGalleryTakeKey()
      }
    }

    /**
     Pins the whole process to one appearance, which SwiftUI's
     `preferredColorScheme(_:)` can't do: the titlebar, the toolbar background,
     and the material behind the menu bar panel follow `NSApp.appearance`, and
     all three are inside a window screenshot.
     */
    private static func pinAppearance() {
      let name = appearance.systemName
      guard NSApplication.shared.appearance?.name != name else { return }
      NSApplication.shared.appearance = NSAppearance(named: name)
    }

    /**
     Fills the screen behind the app with a flat colour.

     A window screenshot is a crop of the composited desktop, so the four
     rounded corners outside the window's own shape carry whatever is behind
     it — and the menu bar panel is its own window, opened wherever macOS has
     room for it. Without this, every published image is a function of the
     developer's wallpaper and of whatever else they had open.

     The fill is the marketing site's own page colour, so a shipped capture's
     corners and its margin land on what the page already draws behind them and
     the window reads as sitting on the page rather than on a grey rectangle.

     Left at the ordinary window level. Below it — the obvious choice for
     something meant to sit behind everything — is below *every* application's
     ordinary windows, not just this app's, so the editor or browser the
     developer left open goes on showing through. Window level outranks which
     app is active; being in the active app's ordinary level is what puts this
     above other apps at all. Where it sits among Zephyr's own windows is
     ``raiseWindowsAboveBackdrop()``'s business.
     */
    private static func installBackdrop() {
      guard backdrop == nil, let screen = NSScreen.main else { return }
      let window = NSWindow(
        contentRect: screen.frame,
        styleMask: .borderless,
        backing: .buffered,
        defer: false
      )
      window.level = .normal
      window.ignoresMouseEvents = true
      window.backgroundColor = appearance.backdropColor
      window.isReleasedWhenClosed = false
      window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
      window.setAccessibilityElement(false)
      window.orderFrontRegardless()
      backdrop = window
      raiseWindowsAboveBackdrop()
    }

    /**
     Puts every window the app has open in front of the backdrop.

     `orderBack(nil)` on the backdrop is the obvious way to say that and does
     not work here: Zephyr is an agent app (`LSUIElement`), and ordering a
     window of one to the back before it has ever been on screen leaves it off
     the screen entirely — a backdrop that quietly does nothing, which is worse
     than none at all, because the captures still come out and only the desktop
     behind them changes. So the backdrop is ordered in front, and the windows
     that have to stay above it are ordered in front of that.

     Run again whenever the app is activated, rather than once as the backdrop
     goes up. A window that takes key orders itself in front and needs none of
     this; the design gallery's does not, because a plain window cannot become
     key, and without this it spends the whole launch behind the backdrop.
     */
    private static func raiseWindowsAboveBackdrop() {
      guard let backdrop else { return }
      for window in NSApplication.shared.windows
      where window !== backdrop && window.isVisible && window.level == .normal {
        window.orderFront(nil)
      }
    }

    /**
     Lets the design gallery's window take key once SwiftUI has sized it.

     The gallery is a plain window, which is the only kind whose frame is its
     content — and a borderless one, which AppKit will not make key. That shows:
     a sheet photographed while no window is key draws its default button grey,
     which is not what anyone opening that sheet sees.

     Adding a title bar is what makes a window key-able, so one is added and
     then hidden. The frame is restored around it because a window gaining a
     title bar keeps its content and grows, and the frame is the size SwiftUI
     measured. Nothing else about the window changes: it stays transparent and
     shadowless, and the surface inside it goes on drawing its own shape.
     */
    private static func letTheDesignGalleryTakeKey() {
      guard AppModel.launchesWithDesignPresented, !hasGalleryTakenKey,
        let window = NSApplication.shared.windows
          .first(where: { $0.title == DesignGallery.windowTitle })
      else { return }
      hasGalleryTakenKey = true
      let measured = window.frame
      window.styleMask.insert([.titled, .fullSizeContentView])
      window.titlebarAppearsTransparent = true
      window.titleVisibility = .hidden
      for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
        window.standardWindowButton(button)?.isHidden = true
      }
      window.contentMinSize = .zero
      window.contentMaxSize = NSSize(
        width: CGFloat.greatestFiniteMagnitude,
        height: CGFloat.greatestFiniteMagnitude
      )
      window.setFrame(measured, display: true)
      window.makeKeyAndOrderFront(nil)
    }

    /**
     Sizes and centres each named window the first time it comes up.

     Pinned here rather than left to each scene's `defaultSize`, which is
     advisory — it is honoured only when no frame was autosaved, so on the
     machine the captures are taken from it loses to whatever size the window
     was last dragged to. Each window's own autosaving is left alone: revoking
     it writes a state AppKit reads back on the *next* launch, which would make
     a capture run break every launch after it.
     */
    private static func pinWindowSizes() {
      guard !windowSizes.isEmpty else { return }
      observe(NSWindow.didBecomeKeyNotification) {
        for window in NSApplication.shared.windows {
          guard let size = windowSizes[window.title],
            sizedWindowTitles.insert(window.title).inserted
          else { continue }
          window.setContentSize(size)
          window.center()
        }
      }
    }

    /// One `Title=WxH` entry of `UITEST_WINDOW_SIZES`.
    private static func windowSize(from entry: some StringProtocol) -> (String, CGSize) {
      let parts = entry.split(separator: "=", maxSplits: 1)
      let dimensions = parts.last?.split(separator: "x").compactMap { Double($0) } ?? []
      guard parts.count == 2, dimensions.count == 2 else {
        preconditionFailure(
          "Malformed UITEST_WINDOW_SIZES entry “\(entry)”; expected “Zephyr=560x160”."
        )
      }
      return (String(parts[0]), CGSize(width: dimensions[0], height: dimensions[1]))
    }

    /**
     Runs `handler` on the main actor for every `name` notification. The
     notification itself is never handed on: it carries an `NSWindow`, which
     can't cross out of the posting context, and everything the handlers want
     is reachable from ``NSApplication`` anyway.
     */
    private static func observe(
      _ name: Notification.Name,
      handler: @escaping @MainActor () -> Void
    ) {
      observers.append(
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
          MainActor.assumeIsolated { handler() }
        }
      )
    }

    /// The appearance a test asks for through `UITEST_APPEARANCE`.
    private enum Appearance: String {
      case light
      case dark

      var systemName: NSAppearance.Name {
        switch self {
          case .light: .aqua
          case .dark: .darkAqua
        }
      }

      /// The fill behind the app's windows: the marketing site's page colour,
      /// so a capture's rounded corners and the margin around it match the page
      /// it is published on. The page colour rather than one of its tinted
      /// bands, because that is the background most of the page is, and a
      /// capture has to be placeable wherever its subject belongs.
      var backdropColor: NSColor {
        switch self {
          case .light: NSColor(srgbRed: 0.969, green: 0.965, blue: 0.953, alpha: 1)  // #f7f6f3
          case .dark: NSColor(srgbRed: 0.031, green: 0.059, blue: 0.106, alpha: 1)  // #080f1b
        }
      }
    }
  }
#endif
