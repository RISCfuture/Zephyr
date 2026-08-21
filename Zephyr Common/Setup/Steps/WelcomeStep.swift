import SwiftUI

/// The first page: what Zephyr is, and that this won't take long.
struct WelcomeStep: View {
  var body: some View {
    SetupBookendPage(
      title: LocalizedStringResource("Welcome to Zephyr", bundle: #bundle),
      message: LocalizedStringResource(
        "Zephyr puts your Dropbox in Finder and downloads files only when you open them. It only takes a few short steps to set up.",
        bundle: #bundle
      )
    )
  }
}

#if DEBUG
  #Preview("Welcome") {
    WelcomeStep()
      .inSetupWindow()
  }
#endif
