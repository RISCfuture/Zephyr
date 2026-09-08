import AppKit
import FileProvider
public import SwiftUI
import libZephyr

/**
 Every scene Zephyr presents, and the menus that reach them.

 Both editions render this; they differ only in the ``FeatureFlags`` and the
 optional ``UpdateChecking`` their entry point hands it.
 */
public struct ZephyrScenes: Scene {
  @State private var model: AppModel

  /// Whether the accounts window presents itself at launch: only when setup
  /// isn't taking that job, and only until an account has been linked — a
  /// login-item launch must not pop a window.
  private let presentsAccountsAtLaunch =
    !AppModel.launchesWithAnotherWindowPresented
    && (AppModel.launchesWithSampleAccounts
      || (AppModel.launchesWithSetupSuppressed
        && !UserDefaults.standard.bool(forKey: AppModel.hasLinkedAccountsDefaultsKey)))

  public var body: some Scene {
    MenuBarExtra {
      MenuBarPanel()
        .environment(model)
        .holdsStillForCapture()
    } label: {
      MenuBarMark(model: model)
        .holdsStillForCapture()
    }
    .menuBarExtraStyle(.window)

    Window(Text("Zephyr", bundle: #bundle), id: WindowID.accounts) {
      ContentView()
        .environment(model)
        .holdsStillForCapture()
    }
    .defaultSize(width: 520, height: 360)
    .windowResizability(.contentMinSize)
    .windowToolbarStyle(.unified)
    .defaultLaunchBehavior(presentsAccountsAtLaunch ? .presented : .suppressed)
    .commands { ZephyrCommands(model: model) }

    Window(Text("Sync Issues", bundle: #bundle), id: WindowID.syncIssues) {
      SyncIssuesView()
        .environment(model)
    }
    .defaultSize(width: 560, height: 380)
    .defaultLaunchBehavior(AppModel.launchesWithSyncIssuesPresented ? .presented : .suppressed)

    Window(Text("Welcome to Zephyr", bundle: #bundle), id: WindowID.setup) {
      SetupView()
        .environment(model)
    }
    .windowResizability(.contentSize)
    .defaultLaunchBehavior(model.isSetupPending ? .presented : .suppressed)
    .restorationBehavior(.disabled)

    Settings {
      SettingsView()
        .environment(model)
    }
    .defaultSize(SettingsView.defaultSize)

    #if DEBUG
      // One design-layer surface on its own, for the screenshot suite. Sized to
      // its content, because what is being photographed is a sheet a host holds
      // to a fixed size or a widget tile macOS lays out — never a window
      // somebody dragged.
      Window(Text(verbatim: DesignGallery.windowTitle), id: WindowID.designGallery) {
        if let subject = AppModel.presentedDesignSubject {
          DesignGallery.view(for: subject)
            .holdsStillForCapture()
        }
      }
      // No window at all, which is the only style whose frame is its content:
      // a title bar reserves its height whether or not it is drawn, and 28
      // points of empty window above a sheet is not what the sheet's host
      // shows. What a window would have drawn — the rounded corners, the
      // shadow — the surfaces draw for themselves.
      .windowStyle(.plain)
      .windowResizability(.contentSize)
      .restorationBehavior(.disabled)
      .defaultLaunchBehavior(AppModel.launchesWithDesignPresented ? .presented : .suppressed)
    #endif
  }

  /**
   Creates the scenes and the model behind them.

   - Parameter featureFlags: What this edition is allowed to do.
   - Parameter updates: The update checker, or `nil` in the App Store build.
   */
  public init(featureFlags: FeatureFlags, updates: (any UpdateChecking)? = nil) {
    // Both editions start reporting here rather than in their own entry point.
    // What a report carries has nothing to do with which edition sent it, and
    // this is the one bootstrap they share, so neither can be left out of it.
    CrashReporting.start(as: .app)
    #if DEBUG
      // Before the model, and before any window: the appearance has to be
      // pinned while AppKit is still launching.
      ScreenshotStaging.install()
    #endif
    let model = AppModel(featureFlags: featureFlags, updates: updates)
    _model = State(initialValue: model)
    // The accounts window may never appear, so loading cannot hang off a
    // view; domains and watchers must reconcile on every launch.
    Task { @MainActor in
      await Self.resetDomainsAndQuitIfRequested()
      await model.load()
    }
  }

  /**
   Maintenance hook: `--reset-domains` deregisters every File Provider domain
   and quits, so the next launch re-registers them from scratch.

   The help book's "Start the Finder location over" task sends users here from
   a Terminal that shows them nothing unless this says something, and the
   removal it performs cannot be undone from the app. So each domain's outcome
   is narrated, and a removal that fails exits non-zero: a reset that did not
   happen must not read as one that did, or the next thing the user reports is
   that the reset made no difference.
   */
  private static func resetDomainsAndQuitIfRequested() async {
    guard ProcessInfo.processInfo.arguments.contains("--reset-domains") else { return }
    exit(await removedEveryDomain() ? EXIT_SUCCESS : EXIT_FAILURE)
  }

  /// Deregisters every File Provider domain, reporting each outcome to the
  /// terminal, and answers whether all of them went.
  private static func removedEveryDomain() async -> Bool {
    let domains: [NSFileProviderDomain]
    do {
      domains = try await NSFileProviderManager.domains()
    } catch {
      complain("couldn’t read the registered domains: \(error.localizedDescription)")
      return false
    }
    guard !domains.isEmpty else {
      print("No File Provider domains are registered; there is nothing to reset.")
      return true
    }

    var failures = 0
    for domain in domains {
      do {
        try await NSFileProviderManager.remove(domain)
        print("Removed “\(domain.displayName)”.")
      } catch {
        complain("couldn’t remove “\(domain.displayName)”: \(error.localizedDescription)")
        failures += 1
      }
    }
    guard failures == 0 else { return false }
    print("Open Zephyr again to register your accounts from scratch.")
    return true
  }

  /// Writes one failure to standard error, in `zephyr`'s voice — this runs
  /// from a Terminal, where a GUI alert has nowhere to appear.
  private static func complain(_ message: String) {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
  }
}

/// Window scene identifiers, for `openWindow(id:)`.
enum WindowID {
  static let accounts = "accounts", setup = "setup", syncIssues = "syncIssues"

  #if DEBUG
    /// The screenshot suite's design gallery, which nothing opens by hand.
    static let designGallery = "designGallery"
  #endif
}

/**
 The status item: Zephyr's mark, reading the briskest air across every account.
 It draws through an `NSImage` because SwiftUI shapes don't render as a
 `MenuBarExtra` label — and a template image is what earns the menu bar's own
 light, dark, and inactive treatments.

 The label leads with Zephyr's name so the item stays findable among the menu
 extras, and carries the reading behind it. The reading belongs in the value,
 but a `MenuBarExtra` vends no `AXValue` for it to land in — an
 `.accessibilityValue` here reaches nothing — so the label is the only voice
 the item has.
 */
private struct MenuBarMark: View {
  private static let size: CGFloat = 18

  let model: AppModel

  @Environment(\.colorScheme)
  private var colorScheme

  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  @Environment(\.zephyrMarksTurn)
  private var marksTurn

  var body: some View {
    let activity = model.activity(asOf: model.activitySampleDate)
    let label = Text("Zephyr, \(activity.summary)", bundle: #bundle)
    if activity.state == .syncing, !reduceMotion, marksTurn {
      TurningMenuBarMark(activity: activity, size: Self.size, label: label)
    } else {
      Image(
        nsImage: ZephyrMark.image(
          activity,
          style: .menuBar,
          size: Self.size,
          colorScheme: colorScheme
        )
      )
      .accessibilityLabel(label)
    }
  }
}

/**
 The status item while a sync is running: the mark's turn played out of frames
 drawn once, because the label is an image and there is nothing in an image for
 a view to turn.

 A status item's label renders only what it can hand over as an image, so the
 turn has to arrive as a change of state — a `TimelineView` here draws nothing
 at all, and takes the item off the menu bar with it.

 The frames and the clock that walks them live only as long as this view does,
 which is only as long as the sync: nothing is drawn ahead of a sync, nothing
 is held after one, and nothing ticks at rest.
 */
private struct TurningMenuBarMark: View {
  let activity: SyncActivity
  let size: CGFloat
  let label: Text

  @Environment(\.colorScheme)
  private var colorScheme

  @State private var filmstrip: ZephyrMarkFilmstrip?
  @State private var frameDate = Date()

  var body: some View {
    Image(nsImage: frame(at: frameDate))
      .accessibilityLabel(label)
      .onChange(of: colorScheme, initial: true) {
        filmstrip = ZephyrMarkFilmstrip(
          activity,
          style: .menuBar,
          size: size,
          colorScheme: colorScheme
        )
      }
      .task { await walkTheTurn() }
  }

  /// The frame the turn has reached, or the mark drawn straight for the one
  /// update that precedes the strip, so the status item never blinks empty.
  private func frame(at date: Date) -> NSImage {
    filmstrip?.frame(at: date)
      ?? ZephyrMark.image(activity, style: .menuBar, size: size, colorScheme: colorScheme)
  }

  /// Moves the label on to the frame the clock has reached, until the sync
  /// ends and takes this view — and so this task — with it.
  private func walkTheTurn() async {
    while !Task.isCancelled {
      frameDate = Date()
      try? await Task.sleep(for: .seconds(ZephyrMarkFilmstrip.frameInterval))
    }
  }
}

@MainActor
private extension View {
  /**
   Holds Zephyr's marks still for a staged capture.

   A screenshot is taken as two frames that have to match to the byte, and a
   badge mid-turn never gives the same frame twice. This can only ever quiet a
   mark, never start one, and only a staged run asks it to.
   */
  func holdsStillForCapture() -> some View {
    #if DEBUG
      return environment(\.zephyrMarksTurn, ScreenshotStaging.animatesFreely)
    #else
      return self
    #endif
  }
}

/// Zephyr's menus: every action the windows offer is reachable from here too.
private struct ZephyrCommands: Commands {
  let model: AppModel

  @Environment(\.openWindow)
  private var openWindow
  var body: some Commands {
    // Zephyr has no documents to make.
    CommandGroup(replacing: .newItem) {}

    if let updates = model.updates {
      CommandGroup(after: .appInfo) {
        UpdateMenuButton(updates: updates)
      }
    }

    CommandMenu(Text("Account", bundle: #bundle)) {
      Button(LocalizedStringResource("Link Dropbox Account…", bundle: #bundle)) { linkAccount() }
        .keyboardShortcut("l")
      Button(LocalizedStringResource("Accounts", bundle: #bundle)) { openAccountsWindow() }
        .keyboardShortcut("0")
      Button(LocalizedStringResource("Sync Issues", bundle: #bundle)) {
        openWindow(id: WindowID.syncIssues)
      }
      Divider()
      ForEach(model.accounts, id: \.accountID) { account in
        Button {
          Task { await model.revealInFinder(account.accountID) }
        } label: {
          Text("Open “\(account.displayName)” in Finder", bundle: #bundle)
        }
      }
      .disabled(model.accounts.isEmpty)
    }

    // `after:` rather than `replacing:`. AppKit points SwiftUI's own "Zephyr Help"
    // item at the bundled help book once CFBundleHelpBookFolder and
    // CFBundleHelpBookName are set, and replacing the group takes that item with
    // it. These are the three things the book deliberately isn't: setup, the live
    // site, and somewhere to report a problem.
    CommandGroup(after: .help) {
      Divider()
      Button(LocalizedStringResource("Zephyr Setup…", bundle: #bundle)) {
        openWindow(id: WindowID.setup)
      }
      Link(
        LocalizedStringResource("Zephyr on the Web", bundle: #bundle),
        destination: FeatureFlags.websiteURL
      )
      Link(
        LocalizedStringResource("Report an Issue", bundle: #bundle),
        destination: FeatureFlags.issuesURL
      )
    }
  }

  private func linkAccount() {
    openAccountsWindow()
    model.linkIntent = .newAccount
  }

  private func openAccountsWindow() {
    openWindow(id: WindowID.accounts)
    NSApplication.shared.activate()
  }
}

/// The “Check for Updates…” item, shown only in the downloadable build. The
/// checker presents its own result window, so the button just starts the check.
private struct UpdateMenuButton: View {
  let updates: any UpdateChecking

  var body: some View {
    Button(LocalizedStringResource("Check for Updates…", bundle: #bundle)) {
      Task { await updates.checkForUpdatesAndShowUI() }
    }
    .disabled(!updates.canCheckForUpdates)
  }
}

/// The System Settings panes Zephyr sends people to.
enum SystemSettings {
  /// Login Items & Extensions, at the top of the pane, where Zephyr's login
  /// item is listed.
  static let loginItemsAndExtensions =
    URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!

  /// The File Providers sheet within that pane, holding the one-time
  /// enablement macOS requires before a linked account can appear in Finder.
  /// Opening the pane alone lands above it, leaving the list to be found by
  /// scrolling; naming the extension point opens the sheet itself.
  static let fileProviders = URL(
    string: "x-apple.systempreferences:com.apple.ExtensionsPreferences"
      + "?extensionPointIdentifier=com.apple.fileprovider-nonui"
  )!

  /// Notifications, where an app that was denied them is allowed again.
  static let notifications =
    URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
}
