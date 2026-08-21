import SwiftUI
import libZephyr

/// The settings window: login-item registration, notification preferences,
/// transfer limits, the command-line tool installer, update checking, and the
/// project's own links.
struct SettingsView: View {
  /// The size the window opens at: wide enough for the form, and tall enough
  /// for the first few sections — the rest of the form scrolls into view.
  static let defaultSize = CGSize(width: 460, height: 600)

  /// The shortest the window may be dragged, which still shows a section
  /// and a half.
  private static let minHeight: CGFloat = 360

  var body: some View {
    Form {
      GeneralSection()
      NotificationsSection()
      BandwidthSection()
      MeteredNetworkSection()
      IgnoredItemsSection()
      TroubleshootingSection()
      CommandLineToolSection()
      UpdatesSection()
      AboutSection()
    }
    .formStyle(.grouped)
    .frame(width: Self.defaultSize.width)
    .frame(minHeight: Self.minHeight, maxHeight: .infinity)
  }
}

/// The launch-at-login toggle, kept honest against `SMAppService`'s status.
private struct GeneralSection: View {
  @State private var launchAtLogin = LaunchAtLogin.isEnabled
  @State private var errorMessage: String?

  var body: some View {
    Section {
      Toggle(isOn: $launchAtLogin) {
        Text("Launch at login", bundle: #bundle)
        Text(
          "Keeping Zephyr running lets Finder learn about remote Dropbox changes within seconds.",
          bundle: #bundle
        )
      }
      .accessibilityIdentifier("launchAtLoginToggle")
      .onChange(of: launchAtLogin) { _, enabled in
        apply(enabled)
      }
      if let errorMessage {
        Text(errorMessage)
          .foregroundStyle(.red)
      }
    } header: {
      SectionHeader(
        LocalizedStringResource("General", bundle: #bundle),
        help: .settingsGeneral,
        accessibilityIdentifier: "settings.general.help"
      )
    }
  }

  private func apply(_ enabled: Bool) {
    guard enabled != LaunchAtLogin.isEnabled else { return }
    do {
      try LaunchAtLogin.setEnabled(enabled)
      errorMessage = nil
    } catch {
      launchAtLogin = LaunchAtLogin.isEnabled
      errorMessage = AppModel.alertText(for: error)
    }
  }
}

/// The notification level picker and snooze status.
private struct NotificationsSection: View {
  @Environment(AppModel.self)
  private var model

  private var level: Binding<NotificationLevel> {
    Binding(
      get: { model.notificationSettings.level },
      set: { level in
        var settings = model.notificationSettings
        settings.level = level
        model.setNotificationSettings(settings)
      }
    )
  }

  var body: some View {
    Section {
      Picker(LocalizedStringResource("Notify about", bundle: #bundle), selection: level) {
        ForEach(NotificationLevel.allCases) { level in
          Text(level.label).tag(level)
        }
      }
      .accessibilityIdentifier("notificationLevelPicker")
      if let snoozedUntil = model.notificationSettings.snoozedUntil {
        LabeledContent(LocalizedStringResource("Snoozed until", bundle: #bundle)) {
          HStack {
            Text(snoozedUntil, format: .dateTime.hour().minute())
              .monospacedDigit()
            Button(LocalizedStringResource("Resume", bundle: #bundle)) {
              var settings = model.notificationSettings
              settings.cancelSnooze()
              model.setNotificationSettings(settings)
            }
          }
        }
        Text(
          "Everything a snooze silences, sync errors included, notifies once it ends.",
          bundle: #bundle
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    } header: {
      SectionHeader(
        LocalizedStringResource("Notifications", bundle: #bundle),
        help: .settingsNotifications,
        accessibilityIdentifier: "settings.notifications.help"
      )
    }
  }
}

/// The Mac's transfer limits, which every account's syncing shares.
private struct BandwidthSection: View {
  @Environment(AppModel.self)
  private var model

  var body: some View {
    Section {
      LimitSlider(
        LocalizedStringResource("Upload limit", bundle: #bundle),
        position: limit(\.uploadLimitBps),
        identifier: "uploadLimitField"
      )
      LimitSlider(
        LocalizedStringResource("Download limit", bundle: #bundle),
        position: limit(\.downloadLimitBps),
        identifier: "downloadLimitField"
      )
    } header: {
      SectionHeader(
        LocalizedStringResource("Bandwidth", bundle: #bundle),
        help: .settingsBandwidth,
        accessibilityIdentifier: "settings.bandwidth.help"
      )
    } footer: {
      Text(
        "New limits take effect immediately, and every linked account shares them.",
        bundle: #bundle
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  private func limit(_ rate: WritableKeyPath<BandwidthSettings, UInt64>) -> Binding<Double> {
    model.transferLimit(rate)
  }
}

/**
 What Zephyr does on a network that costs the user something.

 A collapsible `Section` rather than a `DisclosureGroup`, so it sits in the
 Form's own rhythm rather than nesting a second set of insets inside a row.
 */
private struct MeteredNetworkSection: View {
  @Environment(AppModel.self)
  private var model

  @State private var isExpanded = false

  var body: some View {
    Section(isExpanded: $isExpanded) {
      LimitSlider(
        LocalizedStringResource("Transfer limit", bundle: #bundle),
        position: model.transferLimit(\.meteredLimitBps),
        identifier: "meteredLimitField"
      )
      Toggle(isOn: keepsIndexing) {
        Text("Keep indexing", bundle: #bundle)
        Text(
          """
          Zephyr normally waits for a network that costs nothing before it indexes your Dropbox or \
          checks for changes. Files you open still download either way. Low Data Mode always holds \
          indexing back.
          """,
          bundle: #bundle
        )
      }
      .accessibilityIdentifier("expensiveNetworkToggle")
    } header: {
      SectionHeader(
        LocalizedStringResource("Metered Networks", bundle: #bundle),
        help: .settingsBandwidth,
        accessibilityIdentifier: "settings.meteredNetworks.help"
      )
    }
  }

  private var keepsIndexing: Binding<Bool> {
    Binding(
      get: { model.bandwidth.syncsOnExpensiveNetworks },
      set: { keeps in
        var settings = model.bandwidth
        settings.syncsOnExpensiveNetworks = keeps
        model.setBandwidth(settings)
      }
    )
  }
}

extension AppModel {
  /// One limit as a slider position, so a rate in bytes per second and a
  /// slider's stop on a scale of nine share one binding.
  fileprivate func transferLimit(
    _ rate: WritableKeyPath<BandwidthSettings, UInt64>
  ) -> Binding<Double> {
    Binding(
      get: { TransferLimit.position(ofRateBps: self.bandwidth[keyPath: rate]) },
      set: { position in
        var settings = self.bandwidth
        settings[keyPath: rate] = TransferLimit.rateBps(atPosition: position)
        self.setBandwidth(settings)
      }
    )
  }
}

/**
 The transfer rates a limit slider stops at, from a floor of 250 KB/s up to
 Unlimited at the top of its travel.

 The engine stores an unlimited rate as `0`, which reads as "no transfers at
 all" — so the slider names that stop rather than showing the number.
 */
private enum TransferLimit {
  /// Every stop, in bytes per second; the last is unlimited.
  static let ratesBps: [UInt64] = [
    250_000, 500_000, 1_000_000, 2_000_000, 5_000_000,
    10_000_000, 20_000_000, 50_000_000, 100_000_000, unlimitedBps
  ]

  /// The rate the engine reads as "no limit".
  static let unlimitedBps: UInt64 = 0

  /// The highest slider position, and the one meaning unlimited.
  static var lastPosition: Double { Double(ratesBps.count - 1) }

  /// The stop nearest a stored rate, defaulting to unlimited.
  static func position(ofRateBps rateBps: UInt64) -> Double {
    guard rateBps != unlimitedBps else { return lastPosition }
    let nearest = ratesBps.indices.dropLast().min {
      ratesBps[$0].absoluteDistance(to: rateBps) < ratesBps[$1].absoluteDistance(to: rateBps)
    }
    return Double(nearest ?? Int(lastPosition))
  }

  static func rateBps(atPosition position: Double) -> UInt64 {
    ratesBps[index(of: position)]
  }

  /**
   The rate at a stop, named for display.

   `ByteCountFormatStyle` picks the unit — kB/s at the low stops, MB/s higher
   up — and localizes it. Foundation has no transfer-rate unit, so the "per
   second" is ours to add.
   */
  static func label(atPosition position: Double) -> String {
    let rateBps = Self.rateBps(atPosition: position)
    guard rateBps != unlimitedBps else { return String(localized: "Unlimited", bundle: #bundle) }
    let amount = Int64(rateBps).formatted(.byteCount(style: .file))
    return String(
      localized: "\(amount)/s",
      bundle: #bundle,
      comment: "A transfer rate, such as “1.5 MB/s”"
    )
  }

  private static func index(of position: Double) -> Int {
    min(max(Int(position.rounded()), 0), ratesBps.count - 1)
  }
}

private extension UInt64 {
  func absoluteDistance(to other: UInt64) -> UInt64 {
    self > other ? self - other : other - self
  }
}

/// One transfer limit: a slider whose top stop is Unlimited, with the rate it
/// is set to named beside it.
private struct LimitSlider: View {
  private static let readoutWidth: CGFloat = 82

  private let title: LocalizedStringResource
  @Binding private var position: Double
  private let identifier: String

  var body: some View {
    LabeledContent(title) {
      HStack {
        Slider(value: $position, in: 0...TransferLimit.lastPosition, step: 1)
          .accessibilityIdentifier(identifier)
          .accessibilityValue(TransferLimit.label(atPosition: position))
        Text(TransferLimit.label(atPosition: position))
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .frame(width: Self.readoutWidth, alignment: .trailing)
      }
    }
  }

  init(_ title: LocalizedStringResource, position: Binding<Double>, identifier: String) {
    self.title = title
    _position = position
    self.identifier = identifier
  }
}

/**
 The items the user has taken out of syncing, and the way to put one back.

 Nothing else in the app says an item is ignored: the marker lives in Finder's
 context menu and as a badge, so an item ignored months ago is otherwise
 invisible until someone wonders why it never changes.
 */
private struct IgnoredItemsSection: View {
  @Environment(AppModel.self)
  private var model

  @State private var itemsByAccount: [AccountIdentifier: [IndexEntryRecord]] = [:]

  var body: some View {
    Section {
      if itemsByAccount.values.allSatisfy(\.isEmpty) {
        Text("Nothing is excluded from syncing.", bundle: #bundle)
          .foregroundStyle(.secondary)
      } else {
        ForEach(model.accounts, id: \.accountID) { account in
          IgnoredAccountItemsView(
            account: account,
            items: itemsByAccount[account.accountID] ?? [],
            namesAccount: model.accounts.count > 1,
            resume: { item in await resume(item, in: account.accountID) }
          )
        }
      }
    } header: {
      SectionHeader(
        LocalizedStringResource("Not Syncing", bundle: #bundle),
        help: .ignoredItems,
        accessibilityIdentifier: "settings.notSyncing.help"
      )
    } footer: {
      Text(
        "These items stay on this Mac only. Resuming one puts it back in your Dropbox.",
        bundle: #bundle
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .task { await reload() }
  }

  private func reload() async {
    itemsByAccount = await model.ignoredItemsOfEveryAccount()
  }

  private func resume(_ item: IndexEntryRecord, in account: AccountIdentifier) async {
    await model.resumeSync(of: item, in: account)
    await reload()
  }
}

/// One account's ignored items, named only when more than one account is linked.
private struct IgnoredAccountItemsView: View {
  let account: AccountConfiguration
  let items: [IndexEntryRecord]
  let namesAccount: Bool
  let resume: (IndexEntryRecord) async -> Void

  var body: some View {
    if !items.isEmpty {
      if namesAccount {
        Text(account.displayName)
      }
      ForEach(items, id: \.dbxID) { item in
        LabeledContent {
          Button(LocalizedStringResource("Resume", bundle: #bundle)) {
            Task { await resume(item) }
          }
          .accessibilityIdentifier("resumeIgnoredButton")
        } label: {
          PathBreadcrumb(item.pathCased)
            .help(item.pathCased.displayPath)
        }
      }
    }
  }
}

/// Collecting what a bug report needs, and saying plainly what goes in it.
private struct TroubleshootingSection: View {
  @Environment(AppModel.self)
  private var model

  @State private var isCollecting = false

  var body: some View {
    Section {
      LabeledContent {
        HStack {
          if isCollecting {
            ProgressView()
              .controlSize(.small)
          }
          Button(LocalizedStringResource("Collect…", bundle: #bundle)) { collect() }
            .disabled(isCollecting)
            .accessibilityIdentifier("collectDiagnosticsButton")
        }
      } label: {
        Text("Diagnostics", bundle: #bundle)
        Text(
          "Saves a report of Zephyr’s accounts, sync failures, and recent activity, then shows it in Finder. It names files from your Dropbox, so read it before you send it.",
          bundle: #bundle
        )
      }
      Text(
        "Zephyr keeps your file names out of the system log, so a log captured alongside this report won’t name them. The report itself does.",
        bundle: #bundle
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .textSelection(.enabled)
    } header: {
      SectionHeader(
        LocalizedStringResource("Troubleshooting", bundle: #bundle),
        help: .diagnostics,
        accessibilityIdentifier: "settings.troubleshooting.help"
      )
    }
  }

  private func collect() {
    isCollecting = true
    Task {
      if let report = await model.collectDiagnostics() {
        NSWorkspace.shared.activateFileViewerSelecting([report])
      }
      isCollecting = false
    }
  }
}

/// The running version, and — in the downloadable build — the check cadence
/// and the manual check. The App Store build is kept current by the store, so
/// it shows the version alone and says where update controls went.
private struct UpdatesSection: View {
  @Environment(AppModel.self)
  private var model

  var body: some View {
    Section {
      LabeledContent(LocalizedStringResource("Version", bundle: #bundle)) {
        Text(model.featureFlags.version)
          .monospacedDigit()
          .textSelection(.enabled)
      }
      if let updates = model.updates {
        UpdateControlsView(updates: updates)
      } else {
        Text("The App Store keeps Zephyr up to date.", bundle: #bundle)
          .foregroundStyle(.secondary)
      }
    } header: {
      SectionHeader(
        LocalizedStringResource("Updates", bundle: #bundle),
        help: .settingsUpdates,
        accessibilityIdentifier: "settings.updates.help"
      )
    }
  }
}

/// The cadence picker and the manual check, backed by whichever
/// ``UpdateChecking`` this edition injected — which presents its own update UI.
private struct UpdateControlsView: View {
  let updates: any UpdateChecking

  var body: some View {
    Picker(LocalizedStringResource("Check automatically", bundle: #bundle), selection: cadence) {
      ForEach(UpdateCheckCadence.allCases) { choice in
        Text(choice.label).tag(choice)
      }
    }
    .accessibilityIdentifier("updateCadencePicker")
    LabeledContent(LocalizedStringResource("Last checked", bundle: #bundle)) {
      HStack {
        LastCheckedText(lastCheckDate: updates.lastCheckDate)
        Button(LocalizedStringResource("Check Now", bundle: #bundle)) {
          Task { await updates.checkForUpdatesAndShowUI() }
        }
        .disabled(!updates.canCheckForUpdates)
        .accessibilityIdentifier("checkForUpdatesButton")
      }
    }
  }

  @MainActor private var cadence: Binding<UpdateCheckCadence> {
    Binding {
      updates.cadence
    } set: {
      updates.cadence = $0
    }
  }
}

/// When the last update check ran, or that none has.
private struct LastCheckedText: View {
  let lastCheckDate: Date?

  var body: some View {
    Group {
      if let lastCheckDate {
        Text(lastCheckDate, format: .relative(presentation: .named))
      } else {
        Text("Never", bundle: #bundle)
      }
    }
    .foregroundStyle(.secondary)
  }
}

/// The `zephyr` command-line tool: install status and the symlink installer.
private struct CommandLineToolSection: View {
  @State private var isInstalled = CommandLineToolInstaller.isInstalled
  @State private var failureMessage: String?

  @Environment(AppModel.self)
  private var model

  var body: some View {
    Section {
      if model.featureFlags.isAppStoreBuild {
        Text(
          "Installing the command-line tool is available in the downloadable version.",
          bundle: #bundle
        )
        .foregroundStyle(.secondary)
        // The pane would otherwise be the one place in this edition that only
        // names something it can't do. Shortcuts is the scripting both
        // editions ship, and this is where somebody looking for one arrives.
        Text(
          "Zephyr’s actions are available in the Shortcuts app in both versions.",
          bundle: #bundle
        )
        .foregroundStyle(.secondary)
        HelpTopicButton(
          anchor: .automateWithShortcuts,
          accessibilityIdentifier: "settings.commandLineTool.shortcutsHelp"
        )
      } else if CommandLineToolInstaller.bundledToolURL == nil {
        Text("This build of Zephyr doesn’t include the zephyr command-line tool.", bundle: #bundle)
          .foregroundStyle(.secondary)
      } else if CommandLineToolInstaller.canInstall {
        LabeledContent(LocalizedStringResource("Status", bundle: #bundle)) {
          HStack {
            Text(installedStatus)
              .foregroundStyle(.secondary)
            Button(installAction) { install() }
              .help(Text("Link the bundled zephyr tool into /usr/local/bin", bundle: #bundle))
              .accessibilityIdentifier("installCLIButton")
          }
        }
        if let failureMessage {
          Text(failureMessage)
            .foregroundStyle(.red)
          Text(
            "To install by hand, run: \(CommandLineToolInstaller.manualInstallCommand)",
            bundle: #bundle
          )
          .font(.caption)
          .monospaced()
          .textSelection(.enabled)
          HelpTopicButton(
            anchor: .commandLineToolInstall,
            accessibilityIdentifier: "settings.commandLineTool.failureHelp"
          )
        }
      } else if isInstalled {
        // The installer package lays this link down as root, which is the only way it gets made in
        // a build the sandbox holds back. Offering the command that makes it would be offering to
        // redo something already done.
        LabeledContent(LocalizedStringResource("Status", bundle: #bundle)) {
          Text(installedStatus)
            .foregroundStyle(.secondary)
        }
      } else {
        ManualInstallInstructionsView()
      }
    } header: {
      SectionHeader(
        LocalizedStringResource("Command-Line Tool", bundle: #bundle),
        help: .commandLineTool,
        accessibilityIdentifier: "settings.commandLineTool.help"
      )
    }
  }

  /// Whether the symlink is already in place, in the words the row shows.
  private var installedStatus: LocalizedStringResource {
    isInstalled
      ? LocalizedStringResource("Installed in /usr/local/bin", bundle: #bundle)
      : LocalizedStringResource("Not installed", bundle: #bundle)
  }

  /// What the button offers: a first install, or replacing the link that is there.
  private var installAction: LocalizedStringResource {
    isInstalled
      ? LocalizedStringResource("Reinstall", bundle: #bundle)
      : LocalizedStringResource("Install…", bundle: #bundle)
  }

  private func install() {
    failureMessage = nil
    Task {
      do {
        try await CommandLineToolInstaller.install()
        isInstalled = CommandLineToolInstaller.isInstalled
      } catch {
        failureMessage = AppModel.alertText(for: error)
      }
    }
  }
}

/**
 The command that installs the tool, for a build that can neither install it
 itself nor find it already installed.

 macOS withholds the authorization behind ``CommandLineToolInstaller/install()``
 from a sandboxed build Apple hasn't entitled for privileged file operations,
 and withholds it without asking: the request never prompts, and the link fails
 afterwards as a bare permission error. Spending a button on that would spend
 the user's attention on a failure, so the command stands in its place — the
 same link, laid down by a shell that is allowed to.
 */
private struct ManualInstallInstructionsView: View {
  var body: some View {
    VStack(alignment: .leading) {
      Text("Zephyr can’t install this itself. Run this in Terminal:", bundle: #bundle)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      CopyableCommandView(
        command: CommandLineToolInstaller.manualInstallCommand,
        commandIdentifier: "manualInstallCommand",
        copyIdentifier: "copyInstallCommandButton"
      )
      HelpTopicButton(
        anchor: .commandLineToolInstall,
        accessibilityIdentifier: "settings.commandLineTool.manualHelp"
      )
    }
  }
}

/**
 Where to read the privacy policy, report a problem, and read the source.

 The privacy policy is not decoration: Zephyr moves the user's files to and
 from Dropbox, and this is the only place the running app says what it sends
 and what it keeps.
 */
private struct AboutSection: View {
  var body: some View {
    Section {
      Link(
        LocalizedStringResource("Privacy Policy", bundle: #bundle),
        destination: FeatureFlags.privacyURL
      )
      .accessibilityIdentifier("privacyPolicyLink")
      Link(
        LocalizedStringResource("Report an Issue", bundle: #bundle),
        destination: FeatureFlags.issuesURL
      )
      .accessibilityIdentifier("reportIssueLink")
      Link(
        LocalizedStringResource("Zephyr on the Web", bundle: #bundle),
        destination: FeatureFlags.websiteURL
      )
      .accessibilityIdentifier("websiteLink")
      Text(
        "Zephyr is not affiliated with, endorsed by, or sponsored by Dropbox, Inc.",
        bundle: #bundle
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    } header: {
      Text("About", bundle: #bundle)
    }
  }
}

#if DEBUG
  #Preview("App Store edition") {
    SettingsView()
      .environment(
        PreviewHelper.model(accounts: PreviewHelper.sampleAccounts, isAppStoreBuild: true)
      )
  }

  #Preview("Command-line tool, install withheld") {
    ManualInstallInstructionsView()
      .padding()
      .frame(width: 420)
  }

  #Preview("Downloadable edition") {
    SettingsView()
      .environment(
        PreviewHelper.model(
          accounts: PreviewHelper.sampleAccounts,
          updates: PreviewUpdates()
        )
      )
  }
#endif
