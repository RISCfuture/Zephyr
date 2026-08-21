import SwiftUI
import libZephyr

/// Everything Zephyr is about to ask for, said before anything asks.
struct WhatZephyrNeedsStep: View {
  var body: some View {
    SetupPageLayout(
      title: LocalizedStringResource("What Zephyr Needs", bundle: #bundle),
      message: LocalizedStringResource(
        "Zephyr is going to ask macOS for three things. Each one is yours to grant, and none of them happens without you.",
        bundle: #bundle
      )
    ) {
      VStack(alignment: .leading, spacing: SetupMetrics.betweenRows) {
        NeedsRow(
          symbol: "finder",
          title: LocalizedStringResource("Finder", bundle: #bundle),
          detail: LocalizedStringResource(
            "macOS keeps file providers switched off until you enable them. Until you do, your Dropbox can’t appear in Finder.",
            bundle: #bundle
          )
        )
        NeedsRow(
          symbol: "bell",
          title: LocalizedStringResource("Notifications", bundle: #bundle),
          detail: LocalizedStringResource(
            "So Zephyr can tell you when your files change, and when something couldn’t sync.",
            bundle: #bundle
          )
        )
        NeedsRow(
          symbol: "person.circle.fill",
          title: LocalizedStringResource("Opening at login", bundle: #bundle),
          detail: LocalizedStringResource(
            "Finder hears about changes made elsewhere within seconds — but only while Zephyr is running.",
            bundle: #bundle
          )
        )
      }
      VStack(alignment: .leading) {
        Text(
          "Zephyr talks to Dropbox and to nothing else. Your authorization stays in your keychain.",
          bundle: #bundle
        )
        Text("You can change any of this later in Zephyr’s settings.", bundle: #bundle)
      }
      .font(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
  }
}

/// One thing Zephyr will ask for, and what it buys.
private struct NeedsRow: View {
  let symbol: String
  let title: LocalizedStringResource
  let detail: LocalizedStringResource

  var body: some View {
    Label {
      VStack(alignment: .leading, spacing: Metrics.tight) {
        Text(title)
        Text(detail)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    } icon: {
      Image(systemName: symbol)
        .foregroundStyle(ZephyrPalette.active)
    }
  }
}

#if DEBUG
  #Preview("What Zephyr needs") {
    WhatZephyrNeedsStep()
      .inSetupWindow()
  }
#endif
