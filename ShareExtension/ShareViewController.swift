import AppKit
import SwiftUI
import libZephyr

/// The share extension's principal controller: a thin AppKit host for the
/// SwiftUI upload flow.
class ShareViewController: NSViewController {
  override func loadView() {
    // The extension's first code to run: the share sheet builds this
    // controller and asks for its view in one breath.
    CrashReporting.start(as: .shareExtension)
    guard let extensionContext else {
      preconditionFailure("A share extension always runs with a context")
    }
    let model = ShareUploadModel(
      context: ExtensionShareRequestContext(extensionContext),
      service: LiveShareUploadService(
        manager: AccountManager(tokenStore: GroupKeychainTokenStore())
      )
    )
    // The host reads the sheet's size once, when it presents the extension,
    // and holds it there -- so the sheet declares one size and every state
    // lays itself out inside it.
    let size = NSSize(
      width: ShareUploadView.sheetSize.width,
      height: ShareUploadView.sheetSize.height
    )
    let hostingView = NSHostingView(rootView: ShareUploadView(model: model))
    hostingView.frame = NSRect(origin: .zero, size: size)
    view = hostingView
    preferredContentSize = size
  }
}
