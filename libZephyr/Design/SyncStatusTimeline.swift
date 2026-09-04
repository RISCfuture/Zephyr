public import SwiftUI
public import WidgetKit

/**
 Serves the snapshot the app publishes to the shared container.

 The app reloads timelines on every refresh, so the schedule below is only a
 staleness backstop for a stretch where the app never runs.
 */
public struct SyncStatusTimelineProvider: TimelineProvider {
  /// How long an entry stands before WidgetKit asks again.
  static let refreshIntervalSec: TimeInterval = 15 * 60

  private let environment: ZephyrEnvironment

  /// Creates a provider reading from an environment's shared container.
  public init(environment: ZephyrEnvironment = .standard) {
    self.environment = environment
  }

  public func placeholder(in _: Context) -> SyncStatusEntry {
    .sample
  }

  public func getSnapshot(in context: Context, completion: @escaping (SyncStatusEntry) -> Void) {
    completion(context.isPreview ? .sample : currentEntry())
  }

  public func getTimeline(in _: Context, completion: @escaping (Timeline<SyncStatusEntry>) -> Void)
  {
    completion(
      Timeline(
        entries: [currentEntry()],
        policy: .after(Date().addingTimeInterval(Self.refreshIntervalSec))
      )
    )
  }

  /// The entry standing for the container's current contents.
  func currentEntry(asOf date: Date = Date()) -> SyncStatusEntry {
    SyncStatusEntry(date: date, snapshot: SyncStatusSnapshot.load(from: environment))
  }
}

/// One rendition of the widget: when it was made, and what it says.
public struct SyncStatusEntry: TimelineEntry, Sendable {
  /// The accounts the gallery preview stands in with.
  static let sampleAccounts = [
    SyncStatusSnapshot.AccountStatus(
      id: "dbid:sample",
      displayName: "Personal Dropbox",
      files: 6754,
      folders: 593,
      syncErrorCount: 0,
      latestChange: Date().addingTimeInterval(-540)
    )
  ]

  /// The gallery-preview entry.
  static let sample = Self(
    date: Date(),
    snapshot: SyncStatusSnapshot(accounts: sampleAccounts)
  )

  /// When the rendition was made.
  public let date: Date
  /// The published sync summary, or `nil` before the app first publishes one.
  public let snapshot: SyncStatusSnapshot?

  /// Creates the rendition `date` calls for out of `snapshot`.
  public init(date: Date, snapshot: SyncStatusSnapshot?) {
    self.date = date
    self.snapshot = snapshot
  }
}

/// Whichever rendition the entry and the widget's family call for.
public struct SyncStatusEntryView: View {
  @Environment(\.widgetFamily)
  private var family

  let entry: SyncStatusEntry

  public var body: some View {
    SyncStatusWidgetBodyView(entry: entry, family: family)
  }

  /// Draws `entry` as whichever family WidgetKit is asking for.
  public init(entry: SyncStatusEntry) {
    self.entry = entry
  }
}

/**
 One family's rendition of an entry, named rather than read from the
 environment.

 `\.widgetFamily` is get-only, so nothing outside WidgetKit can ask for a
 family — and the screenshot gallery hosts these layouts in an ordinary window,
 where WidgetKit sets nothing at all. ``SyncStatusEntryView`` is this view
 reading the family it was given.
 */
public struct SyncStatusWidgetBodyView: View {
  private let entry: SyncStatusEntry

  private let family: WidgetFamily

  public var body: some View {
    if let snapshot = entry.snapshot, !snapshot.accounts.isEmpty {
      switch family {
        case .systemMedium: SyncStatusMediumView(accounts: snapshot.accounts, asOf: entry.date)
        default: SyncStatusSmallView(account: snapshot.accounts[0], asOf: entry.date)
      }
    } else {
      SyncStatusUnlinkedView()
    }
  }

  /// Draws `entry` as `family` renders it.
  public init(entry: SyncStatusEntry, family: WidgetFamily) {
    self.entry = entry
    self.family = family
  }
}
