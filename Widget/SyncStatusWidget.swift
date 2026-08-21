import SwiftUI
import WidgetKit
import libZephyr

/// The desktop widget summarizing each account's sync state, fed by the
/// snapshot the app publishes to the shared container.
struct SyncStatusWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(
      kind: SyncStatusSnapshot.widgetKind,
      provider: SyncStatusTimelineProvider()
    ) { entry in
      SyncStatusEntryView(entry: entry)
        .containerBackground(.fill.tertiary, for: .widget)
    }
    .configurationDisplayName("Sync Status")
    .description("Your Dropbox accounts’ file counts and sync issues.")
    .supportedFamilies([.systemSmall, .systemMedium])
  }
}

/*
 The layouts, the timeline provider, and their previews live in libZephyr's
 design layer: Xcode refuses to preview anything in a widget extension on macOS,
 and nothing in an app extension can be reached by a test bundle.
 */
