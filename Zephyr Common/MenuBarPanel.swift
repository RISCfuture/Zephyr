import Observation
import SwiftUI
import libZephyr

/**
 The menu-bar panel: per-account sync readouts and the app's main actions.

 It is a window rather than a menu — `MenuBarExtra` draws it with
 `.menuBarExtraStyle(.window)`, which is what lets a row carry a readout no
 `NSMenuItem` could hold — so it is built the way macOS builds its own rich
 menu-bar panels: rows grouped under headings on the panel's material, rather
 than items ruled off from one another.
 */
struct MenuBarPanel: View {
  @Environment(AppModel.self)
  private var model

  @State private var hover = PanelHover()

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      PanelHeader(
        activity: model.activity(asOf: model.activitySampleDate),
        isPaused: model.isSyncPaused
      )
      PanelDivider()
      if !model.withheldApprovals.isEmpty {
        PanelSection(LocalizedStringResource("Needs Attention", bundle: #bundle)) {
          WithheldApprovalsView(approvals: model.withheldApprovals)
        }
      }
      PanelSection(LocalizedStringResource("Accounts", bundle: #bundle)) {
        if model.accounts.isEmpty {
          NoAccountsNotice()
        } else {
          AccountsView(asOf: model.activitySampleDate)
        }
      }
      PanelDivider()
      PanelActionsView()
    }
    .padding(.vertical, PanelMetrics.panelEdgeInset)
    .frame(width: PanelMetrics.width)
    .environment(hover)
    .onContinuousHover(perform: clearHoverWhenPointerLeaves)
    .onAppear { hover.row = nil }
    .background(DismissOnEscapeView())
    .accessibilityIdentifier("menuBarPanel")
    .task {
      await model.refreshStatuses()
      await model.auditApprovals()
    }
  }

  /// The pointer leaving the panel is the one event every row can trust: a row
  /// hidden as the panel closes may never be told the pointer left it, and
  /// would come back still lit.
  private func clearHoverWhenPointerLeaves(_ phase: HoverPhase) {
    guard case .ended = phase else { return }
    hover.row = nil
  }
}

/**
 Escape closes the panel, the way it closes any of macOS's own.

 It rides a keyboard shortcut rather than `onExitCommand`, which never fires
 here: `cancelOperation:` travels up from whatever holds focus, and a
 `MenuBarExtra` window focuses nothing. A shortcut reaches the panel either
 way — the same route `Settings…` and `Quit Zephyr` take.
 */
private struct DismissOnEscapeView: View {
  @Environment(\.dismiss)
  private var dismiss

  var body: some View {
    Button {
      dismiss()
    } label: {
      EmptyView()
    }
    .keyboardShortcut(.cancelAction)
    .frame(width: 0, height: 0)
    .opacity(0)
    .accessibilityHidden(true)
  }
}

/// Which row the pointer is over, held for the whole panel so no row can keep a
/// highlight the pointer has already left.
@MainActor
@Observable
private final class PanelHover {
  var row: AnyHashable?
}

/**
 The measurements every row shares, so their highlights line up.

 These describe an AppKit menu item rather than Zephyr's own rhythm, which is
 why they live here rather than in ``Metrics``: how far a highlight sits from a
 window's edge is a different question from how far one paragraph sits from the
 next, and a palette holding both would answer neither.
 */
private enum PanelMetrics {
  static let width: CGFloat = 320

  /// How far a row's highlight sits from the panel's edge.
  static let highlightInset: CGFloat = 5

  /// How far a row's contents sit inside its own highlight.
  static let contentInset: CGFloat = 9

  /// Where text starts, for anything that draws no highlight to sit inside.
  static var textInset: CGFloat { highlightInset + contentInset }

  /// How tall a row stands above and below its own text.
  static let rowInset: CGFloat = 6

  /**
   How tall a row of small bordered buttons stands above and below them.

   Shorter than ``rowInset`` so that it isn't: a bordered control carries its
   own bezel, and the two insets together are what make a row of buttons and a
   row of text come out the same height.
   */
  static let controlRowInset: CGFloat = 4

  /// How far the panel's contents sit from its top and bottom edges.
  static let panelEdgeInset: CGFloat = 6

  /// The nudge that keeps the panel's head off its top edge.
  static let headerTopInset: CGFloat = 2

  /// The air a section leaves above and below its rows.
  static let sectionInset: CGFloat = 4

  /// The air a rule leaves on either side of itself.
  static let dividerGap: CGFloat = 6

  static let cornerRadius: CGFloat = 5
}

/**
 The panel's head: Zephyr's mark, its name, and the air it is reading.

 The mark stands for the summary printed beside it, so it is left out of the
 accessibility tree rather than stopping VoiceOver on an image that says
 nothing the line next to it doesn't.
 */
private struct PanelHeader: View {
  private static let markSize: CGFloat = 20

  let activity: SyncActivity
  let isPaused: Bool

  var body: some View {
    HStack {
      ZephyrMark(activity, size: Self.markSize)
        .accessibilityHidden(true)
      Text("Zephyr", bundle: #bundle)
        .font(.headline)
      Spacer()
      PanelStatusSummaryView(activity: activity, isPaused: isPaused)
    }
    .padding(.horizontal, PanelMetrics.textInset)
    .padding(.top, PanelMetrics.headerTopInset)
  }
}

/// The reading beside the panel's name: whether syncing is held, what it is
/// sending, or how it stands. It is set smaller than the name it trails, and
/// in the caution color while anything needs the user.
private struct PanelStatusSummaryView: View {
  let activity: SyncActivity
  let isPaused: Bool

  @ScaledMetric(relativeTo: .body)
  private var textSize: CGFloat = 11

  var body: some View {
    Group {
      if isPaused {
        Text("Paused", bundle: #bundle)
      } else if let pendingUploads = activity.pendingUploads, pendingUploads > 0 {
        Text("Uploading \(pendingUploads, format: .number)", bundle: #bundle)
          .monospacedDigit()
      } else {
        Text(activity.summary)
      }
    }
    .font(.system(size: textSize))
    .foregroundStyle(activity.hasIssues ? ZephyrPalette.caution : .secondary)
  }
}

/// The rule between the panel's head, its accounts, and its actions. Inset to
/// the text it separates, the way a panel's rules are.
private struct PanelDivider: View {
  var body: some View {
    Divider()
      .padding(.horizontal, PanelMetrics.textInset)
      .padding(.vertical, PanelMetrics.dividerGap)
  }
}

/// A run of rows under a heading — how a panel groups what it holds.
private struct PanelSection<Content: View>: View {
  private let header: LocalizedStringResource
  private let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: Metrics.tight) {
      Text(header)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, PanelMetrics.textInset)
      content
    }
    .padding(.vertical, PanelMetrics.sectionInset)
  }

  init(_ header: LocalizedStringResource, @ViewBuilder content: () -> Content) {
    self.header = header
    self.content = content()
  }
}

/// What macOS is withholding, as rows that open the pane granting it.
private struct WithheldApprovalsView: View {
  let approvals: [SystemApproval]

  @Environment(\.openURL)
  private var openURL
  @Environment(\.dismiss)
  private var dismiss

  var body: some View {
    ForEach(approvals) { approval in
      PanelNotice(
        Text(approval.actionTitle),
        systemImage: "exclamationmark.triangle.fill",
        tint: ZephyrPalette.caution,
        identifier: "menuApprovalButton-\(approval.id)"
      ) {
        openURL(approval.settingsURL)
        dismiss()
      }
      .help(Text(approval.summary))
      HelpTopicButton(
        anchor: approval.helpAnchor,
        accessibilityIdentifier: "menuApprovalHelp-\(approval.id)"
      )
      .padding(.horizontal, PanelMetrics.textInset)
    }
  }
}

/// Every linked account's readout, newest activity reported as it ages.
private struct AccountsView: View {
  @Environment(AppModel.self)
  private var model
  @Environment(\.openWindow)
  private var openWindow
  @Environment(\.dismiss)
  private var dismiss

  let asOf: Date

  var body: some View {
    ForEach(model.accounts, id: \.accountID) { account in
      PanelActionView(identifier: "revealButton-\(account.accountID.rawValue)") {
        Task { await model.revealInFinder(account.accountID) }
        dismiss()
      } label: {
        AccountReadoutView(
          account: account,
          status: model.accountStatuses[account.accountID],
          activity: model.activity(for: account.accountID, asOf: asOf)
        )
      }
      .help(Text("Open “\(account.displayName)” in Finder", bundle: #bundle))
      AccountAttentionView(status: model.accountStatuses[account.accountID])
    }
    ForEach(model.unreadableAccounts, id: \.self) { account in
      PanelNotice(
        Text("Account settings unreadable", bundle: #bundle),
        systemImage: "exclamationmark.octagon.fill",
        tint: .red,
        identifier: "unreadableAccountNotice-\(account.rawValue)"
      ) {
        presentWindow(WindowID.accounts, opening: openWindow, dismissing: dismiss)
      }
      .help(
        Text(
          "Zephyr can’t read this account’s settings. Link it again to repair them.",
          bundle: #bundle
        )
      )
    }
  }
}

/// What an account needs the user for, under its readout: the failure that
/// stopped it, then the items that couldn't sync — each its own row, because
/// a revoked token is not one of the files that failed.
private struct AccountAttentionView: View {
  let status: AppModel.AccountStatus?

  @Environment(\.openWindow)
  private var openWindow
  @Environment(\.dismiss)
  private var dismiss

  var body: some View {
    if let failure = status?.accountFailure {
      PanelNotice(
        Text(failure.title),
        systemImage: "exclamationmark.octagon.fill",
        tint: .red,
        identifier: "accountFailureNotice"
      ) {
        presentWindow(WindowID.accounts, opening: openWindow, dismissing: dismiss)
      }
      .help(failure.detail ?? failure.title)
    }
    if let count = status?.syncErrorCount, count > 0 {
      PanelNotice(
        Text("\(Int(count)) couldn’t sync", bundle: #bundle).monospacedDigit(),
        systemImage: "exclamationmark.triangle.fill",
        tint: ZephyrPalette.caution,
        identifier: "syncIssuesButton"
      ) {
        presentWindow(WindowID.syncIssues, opening: openWindow, dismissing: dismiss)
      }
      .help(Text("See what couldn’t sync", bundle: #bundle))
    }
  }
}

/// One account as a gauge: who it is and what it's doing on the left, its
/// counts as instrument readouts on the right.
private struct AccountReadoutView: View {
  let account: AccountConfiguration
  let status: AppModel.AccountStatus?
  let activity: SyncActivity

  var body: some View {
    HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: Metrics.tight) {
        Text(account.displayName)
          .lineLimit(1)
        AccountStatusLineView(status: status, activity: activity)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      if let status {
        ReadoutView(value: status.files, label: LocalizedStringResource("files", bundle: #bundle))
        ReadoutView(
          value: status.folders,
          label: LocalizedStringResource("folders", bundle: #bundle)
        )
      }
    }
  }
}

/// The line under an account's name: what it is sending now, or when it last
/// changed. What went wrong gets its own row rather than this one.
private struct AccountStatusLineView: View {
  let status: AppModel.AccountStatus?
  let activity: SyncActivity

  var body: some View {
    // A deliberate wait outranks the backlog it is holding: none of that
    // backlog is moving, and this is the one line that can say why.
    if let refusal = status?.networkCostRefusal {
      Text(refusal.summary)
    } else if let pendingUploads = activity.pendingUploads, pendingUploads > 0 {
      Text("Uploading \(pendingUploads, format: .number)", bundle: #bundle)
        .monospacedDigit()
    } else if let latestChange = status?.latestChange {
      Text("Updated \(latestChange, format: .relative(presentation: .named))", bundle: #bundle)
    } else if status == nil {
      Text("Waiting for first sync", bundle: #bundle)
    } else {
      Text(activity.summary)
    }
  }
}

/// A single instrument reading: the figure over what it counts, set in
/// tabular figures so a count that ticks up doesn't shift the row.
private struct ReadoutView: View {
  private static let columnWidth: CGFloat = 54

  let value: UInt
  let label: LocalizedStringResource

  var body: some View {
    VStack(alignment: .trailing, spacing: 0) {
      Text(value, format: .number)
        .font(.callout)
        .monospacedDigit()
      Text(label)
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
    .frame(width: Self.columnWidth, alignment: .trailing)
    .accessibilityElement(children: .combine)
  }
}

/// The panel before any account is linked.
private struct NoAccountsNotice: View {
  @Environment(\.openWindow)
  private var openWindow
  @Environment(\.dismiss)
  private var dismiss

  var body: some View {
    VStack(alignment: .leading) {
      Text("No Dropbox account linked yet.", bundle: #bundle)
        .foregroundStyle(.secondary)
      Button(LocalizedStringResource("Link a Dropbox Account…", bundle: #bundle)) {
        presentWindow(WindowID.accounts, opening: openWindow, dismissing: dismiss)
      }
      .accessibilityIdentifier("menuLinkAccountButton")
      HelpTopicButton(anchor: .linkAccount, accessibilityIdentifier: "menuLinkAccountHelp")
    }
    .padding(.horizontal, PanelMetrics.textInset)
    .padding(.vertical, PanelMetrics.sectionInset)
  }
}

/// The panel's actions, at its foot.
private struct PanelActionsView: View {
  @Environment(\.openWindow)
  private var openWindow
  @Environment(\.openSettings)
  private var openSettings
  @Environment(\.dismiss)
  private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      PanelActionView(
        LocalizedStringResource("Manage Accounts…", bundle: #bundle),
        identifier: "menuAccountsButton"
      ) {
        presentWindow(WindowID.accounts, opening: openWindow, dismissing: dismiss)
      }
      .help(Text("Link a Dropbox account, or unlink one Zephyr is syncing.", bundle: #bundle))
      // SettingsLink is inert inside a MenuBarExtra window; the environment
      // action opens the scene reliably once the app is frontmost.
      //
      // This shortcut and Quit's reach no menu that could draw them: an agent
      // app has no app menu, so the panel is the only place ⌘, and ⌘Q can live.
      PanelActionView(
        LocalizedStringResource("Settings…", bundle: #bundle),
        identifier: "menuSettingsButton"
      ) {
        NSApplication.shared.activate()
        openSettings()
        dismiss()
      }
      .keyboardShortcut(",")
      .help(
        Text(
          "Change how Zephyr notifies you, what it transfers, and what it leaves alone.",
          bundle: #bundle
        )
      )
      PauseSyncingView()
      SnoozeRow()
      PanelActionView(
        LocalizedStringResource("Quit Zephyr", bundle: #bundle),
        identifier: "menuQuitButton"
      ) {
        NSApplication.shared.terminate(nil)
      }
      .keyboardShortcut("q")
      .help(
        Text(
          "Stop Zephyr. Finder stops hearing about remote changes until you open it again.",
          bundle: #bundle
        )
      )
    }
  }
}

/**
 Opens one of Zephyr's windows from the panel, and closes the panel behind it.

 This is the rule the panel's rows follow: a row that opens a window or leaves
 Zephyr closes the panel, and a row that changes something in place — pausing
 syncing, snoozing notifications — leaves it open.

 Zephyr runs as an agent, so it has to bring itself forward before the window
 it opens can take focus.
 */
@MainActor
private func presentWindow(
  _ id: String,
  opening openWindow: OpenWindowAction,
  dismissing dismiss: DismissAction
) {
  openWindow(id: id)
  NSApplication.shared.activate()
  dismiss()
}

/// Stops and starts syncing for every account. Finder keeps serving what it
/// already holds while syncing is paused; nothing new is fetched or sent.
private struct PauseSyncingView: View {
  @Environment(AppModel.self)
  private var model

  var body: some View {
    PanelActionView(
      model.isSyncPaused
        ? LocalizedStringResource("Resume Syncing", bundle: #bundle)
        : LocalizedStringResource("Pause Syncing", bundle: #bundle),
      identifier: "pauseSyncingButton"
    ) {
      Task { await model.setSyncPaused(!model.isSyncPaused) }
    }
    .help(Text(help))
  }

  private var help: LocalizedStringResource {
    model.isSyncPaused
      ? LocalizedStringResource("Start transferring again.", bundle: #bundle)
      : LocalizedStringResource(
        "Hold every transfer until you resume. Files already on this Mac stay put.",
        bundle: #bundle
      )
  }
}

/**
 The snooze control, which opens its durations in place rather than in a menu.

 It covers sync issues and account failures as well as file changes, which is
 why it says so: a window of quiet the user asks for should be quiet. Nothing
 is lost to it — a snoozed digest is deferred, not consumed, so what it
 silenced notifies once the window closes.
 */
private struct SnoozeRow: View {
  @Environment(AppModel.self)
  private var model

  @State private var isExpanded = false

  private var snoozedUntil: Date? { model.notificationSettings.snoozedUntil }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let snoozedUntil {
        SnoozeInProgressView(deadline: snoozedUntil, resume: resume)
      } else {
        PanelActionView(identifier: "snoozeButton") {
          withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
        } label: {
          SnoozeRowLabel(isExpanded: isExpanded)
        }
        if isExpanded {
          SnoozeDurationsView(snooze: snooze)
        }
      }
    }
    .help(
      Text(
        "Hold every notification, including sync errors, until the snooze ends.",
        bundle: #bundle
      )
    )
  }

  private func snooze(_ duration: Duration) {
    var settings = model.notificationSettings
    settings.snooze(for: duration)
    model.setNotificationSettings(settings)
    isExpanded = false
  }

  private func resume() {
    var settings = model.notificationSettings
    settings.cancelSnooze()
    model.setNotificationSettings(settings)
  }
}

/// The snooze row's face: what it does, and which way its durations sit.
private struct SnoozeRowLabel: View {
  let isExpanded: Bool

  var body: some View {
    HStack {
      Text("Snooze Notifications", bundle: #bundle)
      Spacer()
      Image(systemName: "chevron.down")
        .font(.caption2)
        .foregroundStyle(.secondary)
        .rotationEffect(.degrees(isExpanded ? 180 : 0))
        .accessibilityHidden(true)
    }
  }
}

/// The windows of quiet the snooze row offers, laid out beneath it.
private struct SnoozeDurationsView: View {
  let snooze: (Duration) -> Void

  var body: some View {
    HStack {
      ForEach(SnoozeDuration.timed) { choice in
        if let interval = choice.interval {
          Button(choice.label) { snooze(interval) }
            .accessibilityIdentifier("snoozeButton-\(choice.name)")
        }
      }
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
    .padding(.horizontal, PanelMetrics.textInset)
    .padding(.vertical, PanelMetrics.controlRowInset)
  }
}

/// What the snooze row says while a snooze is running, and the way out of it.
private struct SnoozeInProgressView: View {
  let deadline: Date
  let resume: () -> Void

  var body: some View {
    HStack {
      Text("Snoozed until \(deadline, format: .dateTime.hour().minute())", bundle: #bundle)
        .monospacedDigit()
      Spacer()
      Button(LocalizedStringResource("Resume", bundle: #bundle), action: resume)
        .controlSize(.small)
        .accessibilityIdentifier("resumeNotificationsButton")
    }
    .padding(.horizontal, PanelMetrics.textInset)
    .padding(.vertical, PanelMetrics.controlRowInset)
  }
}

/**
 One of the panel's rows: whatever it shows, and what clicking it does.

 The row carries what it is for in ``SwiftUI/View/help(_:)`` rather than in an
 accessibility label. A `MenuBarExtra`'s window vends its buttons to the
 accessibility API without their labels — a label written on the button, one
 merged from its children, and the label of a plain unstyled `Button` all
 arrive with no title, description, or value — and help text is the one thing
 that does survive into the tree.
 */
private struct PanelActionView<Label: View>: View {
  private let identifier: String
  private let action: () -> Void
  private let label: Label

  var body: some View {
    Button(action: action) { label }
      .buttonStyle(PanelRowButtonStyle(id: identifier))
      .accessibilityIdentifier(identifier)
  }

  init(
    identifier: String,
    action: @escaping () -> Void,
    @ViewBuilder label: () -> Label
  ) {
    self.identifier = identifier
    self.action = action
    self.label = label()
  }

  init(
    _ title: LocalizedStringResource,
    identifier: String,
    action: @escaping () -> Void
  ) where Label == Text {
    self.init(identifier: identifier, action: action) { Text(title) }
  }
}

/**
 A panel row that reports something wrong and opens the window that deals with
 it.

 The symbol carries no meaning the title does not, so it is left out of the
 accessibility tree rather than read aloud ahead of the sentence it decorates.
 */
private struct PanelNotice: View {
  private let title: Text
  private let systemImage: String
  private let tint: Color
  private let identifier: String
  private let action: () -> Void

  var body: some View {
    PanelActionView(identifier: identifier, action: action) {
      Label {
        title
      } icon: {
        Image(systemName: systemImage)
          .accessibilityHidden(true)
      }
      .foregroundStyle(tint)
    }
  }

  init(
    _ title: Text,
    systemImage: String,
    tint: Color,
    identifier: String,
    action: @escaping () -> Void
  ) {
    self.title = title
    self.systemImage = systemImage
    self.tint = tint
    self.identifier = identifier
    self.action = action
  }
}

/// A panel row that lights under the pointer and darkens under a press, inset
/// from the panel's edge the way a panel's rows are.
private struct PanelRowSurface<Content: View>: View {
  @Environment(PanelHover.self)
  private var hover

  let id: AnyHashable
  let isPressed: Bool
  @ViewBuilder let content: Content

  var body: some View {
    content
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, PanelMetrics.contentInset)
      .padding(.vertical, PanelMetrics.rowInset)
      .background(highlight, in: .rect(cornerRadius: PanelMetrics.cornerRadius))
      .contentShape(.rect(cornerRadius: PanelMetrics.cornerRadius))
      .padding(.horizontal, PanelMetrics.highlightInset)
      .onHover(perform: reportHover)
  }

  private var highlight: AnyShapeStyle {
    if isPressed { return AnyShapeStyle(.tertiary) }
    if hover.row == id { return AnyShapeStyle(.quaternary) }
    return AnyShapeStyle(.clear)
  }

  private func reportHover(_ isHovering: Bool) {
    if isHovering {
      hover.row = id
    } else if hover.row == id {
      hover.row = nil
    }
  }
}

private struct PanelRowButtonStyle: ButtonStyle {
  let id: AnyHashable

  func makeBody(configuration: Configuration) -> some View {
    PanelRowSurface(id: id, isPressed: configuration.isPressed) { configuration.label }
  }
}

#if DEBUG
  #Preview("Linked accounts") {
    MenuBarPanel()
      .environment(PreviewHelper.model(accounts: PreviewHelper.sampleAccounts))
  }

  #Preview("No accounts") {
    MenuBarPanel()
      .environment(PreviewHelper.model())
  }

  #Preview("Withheld approvals") {
    MenuBarPanel()
      .environment(
        PreviewHelper.model(
          accounts: PreviewHelper.sampleAccounts,
          withheldApprovals: [.finderExtension, .loginItem]
        )
      )
  }

  #Preview("Header readings") {
    VStack(alignment: .leading) {
      PanelHeader(
        activity: SyncActivity(latestChange: Date(timeIntervalSinceNow: -3600), hasIssues: false),
        isPaused: false
      )
      PanelHeader(
        activity: SyncActivity(latestChange: nil, hasIssues: false, pendingUploads: 128),
        isPaused: false
      )
      PanelHeader(
        activity: SyncActivity(latestChange: nil, hasIssues: true),
        isPaused: false
      )
      PanelHeader(activity: .idle, isPaused: true)
    }
    .padding(.vertical, PanelMetrics.panelEdgeInset)
    .frame(width: PanelMetrics.width)
  }

  #Preview("Snooze row") {
    VStack(alignment: .leading, spacing: 0) {
      SnoozeRowLabel(isExpanded: false)
        .padding(.horizontal, PanelMetrics.textInset)
      SnoozeRowLabel(isExpanded: true)
        .padding(.horizontal, PanelMetrics.textInset)
      SnoozeDurationsView { _ in }
      SnoozeInProgressView(deadline: Date(timeIntervalSinceNow: 3600)) {}
    }
    .padding(.vertical, PanelMetrics.panelEdgeInset)
    .frame(width: PanelMetrics.width)
    .environment(PanelHover())
  }
#endif
