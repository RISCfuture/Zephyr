import Combine
import Foundation
import SwiftUI
import libZephyr

/// The main window: the linked Dropbox accounts, with linking and unlinking controls.
struct ContentView: View {
  @Environment(AppModel.self)
  private var model

  var body: some View {
    @Bindable var model = model
    Group {
      if model.accounts.isEmpty {
        EmptyAccountsView()
      } else {
        AccountList(accounts: model.accounts) { account in
          Task { await model.unlink(account) }
        }
      }
    }
    .frame(minWidth: 460, minHeight: 300)
    .safeAreaInset(edge: .bottom) {
      WithheldApprovalsFooter(approvals: model.withheldApprovals)
    }
    // This window is the one that reports an account as failing, so it re-reads
    // statuses as well as approvals, on becoming active as well as on
    // appearing: a failure that has resolved clears without waiting for the
    // menu bar panel to be opened.
    .task { await refresh() }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    { _ in
      Task { await refresh() }
    }
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button(
          LocalizedStringResource("Link Dropbox Account…", bundle: #bundle),
          systemImage: "plus"
        ) {
          model.linkIntent = .newAccount
        }
        .help(Text("Link a Dropbox account", bundle: #bundle))
        .accessibilityIdentifier("linkAccountButton")
      }
    }
    .sheet(isPresented: isLinkSheetPresented) {
      LinkAccountSheet()
    }
    .alert(Text("Error", bundle: #bundle), isPresented: isAlertPresented) {
      Button(LocalizedStringResource("OK", bundle: #bundle)) { model.alertMessage = nil }
        .accessibilityIdentifier("dismissErrorButton")
    } message: {
      Text(model.alertMessage ?? "")
    }
  }

  private var isLinkSheetPresented: Binding<Bool> {
    Binding(
      get: { model.linkIntent != nil },
      set: { if !$0 { model.linkIntent = nil } }
    )
  }

  private var isAlertPresented: Binding<Bool> {
    Binding(
      get: { model.alertMessage != nil },
      set: { if !$0 { model.alertMessage = nil } }
    )
  }

  /// What this window has to be right about: which approvals are outstanding,
  /// and what each account's index currently says.
  private func refresh() async {
    await model.auditApprovals()
    await model.refreshStatuses()
  }
}

/// The explanation shown before any account is linked.
private struct EmptyAccountsView: View {
  private static let markSize: CGFloat = 56

  var body: some View {
    ContentUnavailableView {
      VStack {
        ZephyrMark(size: Self.markSize)
        Text("No Linked Accounts", bundle: #bundle)
      }
    } description: {
      Text(
        "Link a Dropbox account to browse its files in Finder. Accounts linked only with the zephyr command-line tool keep their credentials to themselves and don’t appear here — link them in the app too.",
        bundle: #bundle
      )
    } actions: {
      HelpTopicButton(
        anchor: .whereFilesLive,
        accessibilityIdentifier: "accounts.emptyState.help"
      )
    }
  }
}

/// The approvals macOS is withholding, each alongside the settings pane that
/// grants it. Nothing shows while Zephyr has everything it needs.
private struct WithheldApprovalsFooter: View {
  let approvals: [SystemApproval]

  var body: some View {
    if !approvals.isEmpty {
      VStack {
        ForEach(approvals) { WithheldApprovalRow(approval: $0) }
      }
      .padding(.horizontal)
      .padding(.vertical, 8)
      .background(.bar)
    }
  }
}

/// One withheld approval: what it costs, and the button that grants it.
private struct WithheldApprovalRow: View {
  let approval: SystemApproval

  @Environment(\.openURL)
  private var openURL

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Label {
        Text(approval.summary)
          .fixedSize(horizontal: false, vertical: true)
      } icon: {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(ZephyrPalette.caution)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Button(LocalizedStringResource("Open System Settings", bundle: #bundle)) {
        openURL(approval.settingsURL)
      }
      .controlSize(.small)
      .help(Text(approval.settingsHint))
      .accessibilityIdentifier("approvalSettingsButton-\(approval.id)")
      HelpTopicLink(
        anchor: approval.helpAnchor,
        accessibilityIdentifier: "accounts.approval.help-\(approval.id)"
      )
      .controlSize(.small)
    }
  }
}

/// The list of linked accounts: one row per account, selectable, with the
/// context menu and Delete-key behavior a Mac list is expected to have.
private struct AccountList: View {
  let accounts: [AccountConfiguration]
  let unlink: (AccountIdentifier) -> Void

  @Environment(AppModel.self)
  private var model

  @State private var selection: Set<AccountIdentifier> = []
  @State private var accountPendingUnlink: AccountConfiguration?
  @State private var accountPendingRebuild: AccountConfiguration?

  var body: some View {
    List(selection: $selection) {
      ForEach(accounts, id: \.accountID) { account in
        AccountRow(
          account: account,
          status: model.accountStatuses[account.accountID],
          activity: model.activity(for: account.accountID)
        )
        .tag(account.accountID)
      }
      ForEach(model.unreadableAccounts, id: \.self) { account in
        UnreadableAccountRow(account: account)
      }
    }
    .contextMenu(forSelectionType: AccountIdentifier.self) { identifiers in
      AccountContextMenu(
        accounts: accounts,
        identifiers: identifiers,
        reveal: reveal,
        accountPendingRebuild: $accountPendingRebuild,
        accountPendingUnlink: $accountPendingUnlink
      )
    } primaryAction: { identifiers in
      reveal(identifiers)
    }
    .onDeleteCommand { requestUnlink(of: selection) }
    .confirmationDialog(
      Text("Unlink “\(accountPendingUnlink?.displayName ?? "")”?", bundle: #bundle),
      isPresented: isConfirmingUnlink,
      presenting: accountPendingUnlink
    ) { account in
      Button(LocalizedStringResource("Unlink", bundle: #bundle), role: .destructive) {
        unlink(account.accountID)
      }
      .accessibilityIdentifier("confirmUnlinkButton")
    } message: { _ in
      Text(
        "This removes the account’s files from Finder and disconnects Zephyr from Dropbox. Nothing in your Dropbox is deleted.",
        bundle: #bundle
      )
    }
    .confirmationDialog(
      Text(
        "Rebuild the index for “\(accountPendingRebuild?.displayName ?? "")”?",
        bundle: #bundle
      ),
      isPresented: isConfirmingRebuild,
      presenting: accountPendingRebuild
    ) { account in
      Button(LocalizedStringResource("Rebuild", bundle: #bundle), role: .destructive) {
        Task { await model.rebuildIndex(for: account.accountID) }
      }
      .accessibilityIdentifier("confirmRebuildButton")
    } message: { _ in
      Text(
        "Zephyr lists your whole Dropbox again and re-downloads the files Finder is holding. Your Dropbox is untouched, and so are Finder tags and items you’ve taken out of syncing — but Zephyr’s record of recent changes is lost, because Dropbox never sends it twice.",
        bundle: #bundle
      )
    }
  }

  private var isConfirmingUnlink: Binding<Bool> {
    Binding(
      get: { accountPendingUnlink != nil },
      set: { if !$0 { accountPendingUnlink = nil } }
    )
  }

  private var isConfirmingRebuild: Binding<Bool> {
    Binding(
      get: { accountPendingRebuild != nil },
      set: { if !$0 { accountPendingRebuild = nil } }
    )
  }

  private func reveal(_ identifiers: Set<AccountIdentifier>) {
    for identifier in identifiers {
      Task { await model.revealInFinder(identifier) }
    }
  }

  private func requestUnlink(of identifiers: Set<AccountIdentifier>) {
    accountPendingUnlink = accounts.first { identifiers.contains($0.accountID) }
  }
}

/// What the list offers for the account under the pointer: where to open it,
/// what to copy from it, and the two destructive actions, each of which only
/// arms the confirmation the list presents.
private struct AccountContextMenu: View {
  let accounts: [AccountConfiguration]
  let identifiers: Set<AccountIdentifier>
  let reveal: (Set<AccountIdentifier>) -> Void

  @Binding var accountPendingRebuild: AccountConfiguration?
  @Binding var accountPendingUnlink: AccountConfiguration?

  var body: some View {
    if let account = selectedAccount {
      Button(LocalizedStringResource("Open in Finder", bundle: #bundle)) { reveal(identifiers) }
      Button(LocalizedStringResource("Copy Email Address", bundle: #bundle)) {
        copy(account.email)
      }
      Divider()
      Button(LocalizedStringResource("Rebuild Index…", bundle: #bundle)) {
        accountPendingRebuild = account
      }
      .accessibilityIdentifier("rebuildIndexButton-\(account.accountID.rawValue)")
      Divider()
      Button(LocalizedStringResource("Unlink…", bundle: #bundle), role: .destructive) {
        accountPendingUnlink = account
      }
      .accessibilityIdentifier("unlinkButton-\(account.accountID.rawValue)")
    }
  }

  private var selectedAccount: AccountConfiguration? {
    accounts.first { identifiers.contains($0.accountID) }
  }

  private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
}

/// One linked account: its mark and identity, and its counts as readouts.
private struct AccountRow: View {
  private static let markSize: CGFloat = 19

  let account: AccountConfiguration
  let status: AppModel.AccountStatus?
  let activity: SyncActivity

  var body: some View {
    HStack {
      ZephyrMark(activity, size: Self.markSize)
        .help(activity.summary)
      VStack(alignment: .leading, spacing: Metrics.tight) {
        Text(account.displayName)
          .accessibilityIdentifier("accountName-\(account.accountID.rawValue)")
        Text(account.email)
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
        if let failure = status?.accountFailure {
          AccountFailureNotice(failure: failure, account: account.accountID)
        }
        if let count = status?.syncErrorCount, count > 0 {
          SyncIssuesLink(count: count)
        }
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
    .padding(.vertical, 5)
  }
}

/// A linked account nothing can be said about, because its configuration
/// wouldn't load. Every other account still lists normally beside it.
private struct UnreadableAccountRow: View {
  let account: AccountIdentifier

  @Environment(AppModel.self)
  private var model

  var body: some View {
    HStack {
      Label {
        VStack(alignment: .leading) {
          Text("Account settings unreadable", bundle: #bundle)
          Text(
            "Zephyr can’t read this account’s settings. Link it again to repair them.",
            bundle: #bundle
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      } icon: {
        Image(systemName: "exclamationmark.octagon.fill")
          .foregroundStyle(.red)
      }
      Spacer(minLength: 0)
      Button(LocalizedStringResource("Link Again…", bundle: #bundle)) {
        model.linkIntent = .repairing(account)
      }
      .controlSize(.small)
      .accessibilityIdentifier("relinkButton-\(account.rawValue)")
    }
    .padding(.vertical, 5)
  }
}

/// What stopped a whole account, kept apart from the items that couldn't
/// sync — a revoked token is not one file among many.
private struct AccountFailureNotice: View {
  let failure: AppModel.AccountFailure
  let account: AccountIdentifier

  @Environment(AppModel.self)
  private var model

  @ScaledMetric(relativeTo: .body)
  private var textSize: CGFloat = 11

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Label {
        Text(failure.title)
          .fixedSize(horizontal: false, vertical: true)
      } icon: {
        Image(systemName: "exclamationmark.octagon.fill")
      }
      .font(.system(size: textSize))
      .foregroundStyle(.red)
      if failure.isResolvedByRelinking {
        Button(LocalizedStringResource("Link Again…", bundle: #bundle)) {
          model.linkIntent = .repairing(account)
        }
        .controlSize(.small)
        .accessibilityIdentifier("relinkButton-\(account.rawValue)")
      }
      HelpTopicButton(
        anchor: .reauthorize,
        accessibilityIdentifier: "accounts.accountFailure.help-\(account.rawValue)"
      )
    }
    .help(failure.detail ?? failure.title)
  }
}

/// How many items couldn't sync, and the way to the list of them.
private struct SyncIssuesLink: View {
  let count: UInt

  @Environment(\.openWindow)
  private var openWindow

  @ScaledMetric(relativeTo: .body)
  private var textSize: CGFloat = 11

  var body: some View {
    Button {
      openWindow(id: WindowID.syncIssues)
      NSApplication.shared.activate()
    } label: {
      Label {
        Text("\(Int(count)) couldn’t sync", bundle: #bundle)
          .monospacedDigit()
      } icon: {
        Image(systemName: "exclamationmark.triangle.fill")
      }
      .font(.system(size: textSize))
      .foregroundStyle(ZephyrPalette.caution)
    }
    .buttonStyle(.link)
    .accessibilityIdentifier("syncIssuesLink")
  }
}

/// A single instrument reading, in tabular figures.
private struct ReadoutView: View {
  private static let columnWidth: CGFloat = 58

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

/// The sheet that walks the user through Dropbox's browser authorization flow.
struct LinkAccountSheet: View {
  private static let markSize: CGFloat = 20

  @Environment(AppModel.self)
  private var model
  @Environment(\.dismiss)
  private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: Metrics.betweenGroups) {
      HStack {
        ZephyrMark(size: Self.markSize)
        Text("Link a Dropbox Account", bundle: #bundle)
          .font(.headline)
      }
      LinkAccountForm(
        help: HelpTopicLink(anchor: .linkAccount, accessibilityIdentifier: "linkAccount.help"),
        cancel: cancel
      ) { dismiss() }
    }
    .padding()
    .frame(width: 440)
  }

  private func cancel() {
    model.cancelLink()
    dismiss()
  }
}

/**
 The window listing everything that couldn't sync, account by account, with
 what each failure said and a way to put it away.

 The menu-bar panel and the accounts window both open it: a count is not a
 report, and a user who is told two files couldn't sync has no way to learn
 which two anywhere else.
 */
struct SyncIssuesView: View {
  @Environment(AppModel.self)
  private var model

  var body: some View {
    Group {
      if model.accountsWithIssues.isEmpty {
        ContentUnavailableView(
          LocalizedStringResource("Nothing Failed to Sync", bundle: #bundle),
          systemImage: "checkmark.circle",
          description: Text(
            "Every item Zephyr knows about is in step with Dropbox.",
            bundle: #bundle
          )
        )
      } else {
        List {
          ForEach(model.accountsWithIssues, id: \.account.accountID) { account, status in
            Section(account.displayName) {
              if let failure = status.accountFailure {
                AccountFailureRow(failure: failure)
              }
              ForEach(status.syncErrors, id: \.pathNormalized) { issue in
                SyncIssueRow(issue: issue, account: account.accountID)
              }
            }
          }
        }
      }
    }
    .frame(minWidth: 480, minHeight: 300)
    .safeAreaInset(edge: .bottom, alignment: .trailing, spacing: 0) {
      HelpTopicLink(anchor: .syncIssues, accessibilityIdentifier: "syncIssues.help")
        .padding([.trailing, .bottom])
    }
    .accessibilityIdentifier("syncIssuesList")
    .task { await model.refreshStatuses() }
  }
}

/// One item that couldn't sync: what it was, what went wrong, and the two
/// things the user can do about it.
private struct SyncIssueRow: View {
  let issue: SyncErrorRecord
  let account: AccountIdentifier

  @Environment(AppModel.self)
  private var model

  var body: some View {
    HStack(alignment: .top) {
      VStack(alignment: .leading) {
        PathBreadcrumb(issue.path)
          .textSelection(.enabled)
          .help(issue.path.displayPath)
        Text(issue.detail ?? issue.title)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
      HStack {
        Button(LocalizedStringResource("Show", bundle: #bundle)) {
          Task { await model.revealItem(atPath: issue.pathNormalized, in: account) }
        }
        .controlSize(.small)
        Button(LocalizedStringResource("Dismiss", bundle: #bundle)) {
          Task { await model.dismissSyncIssue(issue, for: account) }
        }
        .controlSize(.small)
        .accessibilityIdentifier("dismissIssueButton")
      }
    }
    .padding(.vertical, 4)
  }
}

/// The account-wide failure at the head of an account's section, above the
/// items — nothing below it can sync while it stands.
private struct AccountFailureRow: View {
  let failure: AppModel.AccountFailure

  var body: some View {
    Label {
      VStack(alignment: .leading) {
        Text(failure.title)
        if let detail = failure.detail {
          Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    } icon: {
      Image(systemName: "exclamationmark.octagon.fill")
        .foregroundStyle(.red)
    }
    .padding(.vertical, 4)
  }
}

/*
 A preview of the whole window in its linked state, or of the sync-issues
 window with anything to report, would need a `List`, and SwiftUI's macOS list
 previews crash the preview host outright (a fatal error inside its own
 `TableViewListCore_Mac2`, reproducible with a bare `List { Text("a") }`). The
 rows, the footer, and the empty states are previewed on their own instead,
 which is the part worth iterating on anyway.
 */

#if DEBUG
  #Preview("Empty") {
    ContentView()
      .environment(PreviewHelper.model())
  }

  #Preview("Account rows") {
    VStack(alignment: .leading) {
      AccountRow(
        account: PreviewHelper.sampleAccounts[0],
        status: AppModel.AccountStatus(
          files: 6754,
          folders: 593,
          latestChange: Date(timeIntervalSinceNow: -70)
        ),
        activity: SyncActivity(latestChange: Date(timeIntervalSinceNow: -70), hasIssues: false)
      )
      AccountRow(
        account: PreviewHelper.sampleAccounts[1],
        status: AppModel.AccountStatus(
          files: 1204,
          folders: 88,
          syncErrors: PreviewHelper.sampleIssues,
          latestChange: Date(timeIntervalSinceNow: -3600 * 5)
        ),
        activity: SyncActivity(
          latestChange: Date(timeIntervalSinceNow: -3600 * 5),
          hasIssues: true
        )
      )
      AccountRow(
        account: PreviewHelper.sampleAccounts[0],
        status: AppModel.AccountStatus(
          files: 6754,
          folders: 593,
          latestChange: Date(timeIntervalSinceNow: -3600 * 26),
          accountFailure: AppModel.AccountFailure(AuthenticationFailure.tokenRevoked)
        ),
        activity: SyncActivity(latestChange: nil, hasIssues: true)
      )
      UnreadableAccountRow(account: PreviewHelper.sampleAccounts[1].accountID)
    }
    .environment(PreviewHelper.model(accounts: PreviewHelper.sampleAccounts))
    .padding()
    .frame(width: 460)
  }

  #Preview("No sync issues") {
    SyncIssuesView()
      .environment(PreviewHelper.model())
  }

  #Preview("Sync issue row") {
    VStack(alignment: .leading) {
      AccountFailureRow(
        failure: AppModel.AccountFailure(AuthenticationFailure.tokenRevoked)!
      )
      ForEach(PreviewHelper.sampleIssues, id: \.pathNormalized) { issue in
        SyncIssueRow(issue: issue, account: PreviewHelper.sampleAccounts[1].accountID)
      }
    }
    .environment(PreviewHelper.model(accounts: PreviewHelper.sampleAccounts))
    .padding()
    .frame(width: 480)
  }

  #Preview("Withheld approvals") {
    WithheldApprovalsFooter(approvals: [.finderExtension, .notifications, .loginItem])
      .frame(width: 520)
  }

  #Preview("Link sheet") {
    LinkAccountSheet()
      .environment(PreviewHelper.model())
  }
#endif
