import AppIntents
import SwiftUI
import WidgetKit
import libZephyr

/// The Control Center toggle that stops and starts syncing, alongside the menu
/// bar item's own Pause Syncing row.
struct PauseSyncingControl: ControlWidget {
  var body: some ControlWidgetConfiguration {
    StaticControlConfiguration(
      kind: SetSyncPausedIntent.controlKind,
      provider: SyncPausedValueProvider()
    ) { isPaused in
      ControlWidgetToggle(isOn: isPaused, action: SetSyncPausedIntent()) {
        Label {
          Text(isPaused ? "Syncing Paused" : "Syncing", bundle: #bundle)
        } icon: {
          // Zephyr's mark badged with the sync arrows, from this extension's own asset
          // catalog: a control's icon is resolved by the system rather than drawn in
          // process, so it has to be a symbol the extension's bundle carries.
          if isPaused {
            Image(systemName: "pause.circle")
          } else {
            Image("zephyr.logomark.sync")
          }
        }
      }
    }
    .displayName(LocalizedStringResource("Pause Syncing", bundle: #bundle))
    .description(
      LocalizedStringResource(
        "Stop and start syncing every Dropbox account Zephyr keeps in Finder.",
        bundle: #bundle
      )
    )
  }
}

/**
 Whether syncing is paused, read from the File Provider domains themselves.

 The widget extension asks the system directly rather than reading the app's
 published snapshot: `NSFileProviderManager` answers an executable inside the
 app bundle that shares the provider's document group, and the snapshot is only
 written while the app is running — a control has to be right when it isn't.
 */
private struct SyncPausedValueProvider: ControlValueProvider {
  /// Syncing running, which is what the gallery should show a reader deciding
  /// whether to add the control.
  let previewValue = false

  func currentValue() async throws -> Bool {
    await DomainConnection.areAllDisconnected()
  }
}
