import SwiftUI

/**
 The widget's layouts.

 They live here rather than in the widget extension because macOS refuses to
 host previews for an app extension ("This platform does not support previewing
 widgets"), and these are the views worth iterating on visually. The extension
 keeps the `Widget`, its timeline, and the family switch.
 */

/// The small family: one account, read as a single gauge.
struct SyncStatusSmallView: View {
  private static let markSize: CGFloat = 20

  private let account: SyncStatusSnapshot.AccountStatus

  private let asOf: Date

  @ScaledMetric(relativeTo: .body)
  private var displayNameSize: CGFloat = 11

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ZephyrMark(activity, size: Self.markSize)
      Spacer(minLength: 6)
      // Zephyr's one display-scale figure, and the only one set on a soft
      // rounded surface: rounded coordinates it with the widget's own tile.
      Text(account.files, format: .number)
        .font(.system(.title, design: .rounded))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.6)
      Text("files", bundle: #bundle)
        .font(.caption)
        .foregroundStyle(.secondary)
      Spacer(minLength: 6)
      Text(account.displayName)
        .font(.system(size: displayNameSize))
        .lineLimit(1)
      ActivityView(account: account, activity: activity)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private var activity: SyncActivity {
    SyncActivity(
      latestChange: account.latestChange,
      hasIssues: account.needsAttention,
      pendingUploads: account.pendingUploads,
      asOf: asOf
    )
  }

  init(account: SyncStatusSnapshot.AccountStatus, asOf: Date) {
    self.account = account
    self.asOf = asOf
  }
}

/// The medium family: every account as a row of readouts.
struct SyncStatusMediumView: View {
  private static let markSize: CGFloat = 19

  private static let listedAccountsLimit = 3

  private let accounts: [SyncStatusSnapshot.AccountStatus]

  private let asOf: Date

  var body: some View {
    VStack(alignment: .leading) {
      HStack {
        ZephyrMark(overallActivity, size: Self.markSize)
        Text("Zephyr", bundle: #bundle)
          .font(.headline)
      }
      ForEach(accounts.prefix(Self.listedAccountsLimit)) { account in
        AccountSummaryView(account: account, asOf: asOf)
      }
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var overallActivity: SyncActivity {
    SyncActivity(
      latestChange: accounts.compactMap(\.latestChange).max(),
      hasIssues: accounts.contains(where: \.needsAttention),
      pendingUploads: totalPendingUploads,
      asOf: asOf
    )
  }

  /// Every account's backlog together, or `nil` where no account reported one
  /// — a sum of nothing is not a measurement of zero.
  private var totalPendingUploads: UInt? {
    let reported = accounts.compactMap(\.pendingUploads)
    return reported.isEmpty ? nil : reported.reduce(0, +)
  }

  init(accounts: [SyncStatusSnapshot.AccountStatus], asOf: Date) {
    self.accounts = accounts
    self.asOf = asOf
  }
}

/// One account's identity and activity on the left, its counts as readouts on
/// the right — the same gauge the menu-bar panel flies.
private struct AccountSummaryView: View {
  let account: SyncStatusSnapshot.AccountStatus

  let asOf: Date

  var body: some View {
    HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: 0) {
        Text(account.displayName)
          .lineLimit(1)
        ActivityView(account: account, activity: activity)
      }
      Spacer(minLength: 0)
      ReadoutView(value: account.files, label: "files")
      ReadoutView(value: account.folders, label: "folders")
    }
  }

  private var activity: SyncActivity {
    SyncActivity(
      latestChange: account.latestChange,
      hasIssues: account.needsAttention,
      pendingUploads: account.pendingUploads,
      asOf: asOf
    )
  }
}

/**
 What an account is doing: what stopped it, its sync issues, or when it last
 changed.

 Each symbol carries no meaning the line beside it does not, so it is left out
 of the accessibility tree rather than read aloud ahead of the sentence it
 decorates.
 */
private struct ActivityView: View {
  let account: SyncStatusSnapshot.AccountStatus

  let activity: SyncActivity

  var body: some View {
    if let accountFailure = account.accountFailure {
      Label {
        Text(accountFailure)
      } icon: {
        Image(systemName: "exclamationmark.octagon.fill")
          .accessibilityHidden(true)
      }
      .font(.caption2)
      .foregroundStyle(ZephyrPalette.alert)
      .lineLimit(1)
    } else if account.syncErrorCount > 0 {
      Label {
        Text("\(Int(account.syncErrorCount)) couldn’t sync", bundle: #bundle)
      } icon: {
        Image(systemName: "exclamationmark.triangle.fill")
          .accessibilityHidden(true)
      }
      .font(.caption2)
      .foregroundStyle(ZephyrPalette.caution)
      .lineLimit(1)
    } else if let pendingUploads = account.pendingUploads, pendingUploads > 0 {
      Text("Uploading \(Int(pendingUploads))", bundle: #bundle)
        .font(.caption2)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .lineLimit(1)
    } else if let latestChange = account.latestChange {
      Text("Updated \(latestChange, format: .relative(presentation: .named))", bundle: #bundle)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    } else {
      Text(activity.summary)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
  }
}

/// A single instrument reading, in tabular figures.
private struct ReadoutView: View {
  private static let columnWidth: CGFloat = 52

  let value: UInt

  let label: LocalizedStringKey

  var body: some View {
    VStack(alignment: .trailing, spacing: 0) {
      Text(value, format: .number)
        .font(.callout)
        .monospacedDigit()
      Text(label, bundle: #bundle)
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
    .frame(width: Self.columnWidth, alignment: .trailing)
    .accessibilityElement(children: .combine)
  }
}

/// Shown before any account has published a status.
struct SyncStatusUnlinkedView: View {
  private static let markSize: CGFloat = 27

  @ScaledMetric(relativeTo: .body)
  private var messageSize: CGFloat = 11

  var body: some View {
    VStack {
      ZephyrMark(size: Self.markSize)
      Text("Open Zephyr to link a Dropbox account.", bundle: #bundle)
        .font(.system(size: messageSize))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
  }

  init() {}
}

/// The sizes WidgetKit gives each family on macOS.
private enum WidgetSize {
  static let small = (width: 158.0, height: 158.0)

  static let medium = (width: 338.0, height: 158.0)
}

private extension SyncStatusSnapshot.AccountStatus {
  static let previewSamples = [
    SyncStatusSnapshot.AccountStatus(
      id: "dbid:preview-personal",
      displayName: "Personal Dropbox",
      files: 6754,
      folders: 593,
      syncErrorCount: 0,
      latestChange: Date(timeIntervalSinceNow: -540),
      pendingUploads: 12
    ),
    SyncStatusSnapshot.AccountStatus(
      id: "dbid:preview-work",
      displayName: "Work Dropbox",
      files: 1204,
      folders: 88,
      syncErrorCount: 2,
      latestChange: Date(timeIntervalSinceNow: -3600 * 5),
      syncIssues: [
        SyncStatusSnapshot.SyncIssue(
          id: "/reports/q3.numbers",
          path: "/Reports/Q3.numbers",
          title: "Couldn’t upload “Q3.numbers”.",
          detail: "Your Dropbox is full."
        )
      ]
    ),
    SyncStatusSnapshot.AccountStatus(
      id: "dbid:preview-stopped",
      displayName: "Archive Dropbox",
      files: 312,
      folders: 21,
      syncErrorCount: 0,
      latestChange: Date(timeIntervalSinceNow: -3600 * 26),
      accountFailure: "Syncing stopped."
    )
  ]
}

private extension View {
  /// Frames a preview at a widget family's real geometry, on a widget-like ground.
  func inWidget(_ size: (width: Double, height: Double)) -> some View {
    padding()
      .frame(width: size.width, height: size.height)
      .background(.fill.tertiary)
  }
}

#Preview("Widget renditions") {
  HStack(spacing: 20) {
    SyncStatusSmallView(
      account: SyncStatusSnapshot.AccountStatus.previewSamples[0],
      asOf: Date()
    )
    .inWidget(WidgetSize.small)
    SyncStatusUnlinkedView()
      .inWidget(WidgetSize.small)
    SyncStatusMediumView(
      accounts: SyncStatusSnapshot.AccountStatus.previewSamples,
      asOf: Date()
    )
    .inWidget(WidgetSize.medium)
  }
  .padding()
}
