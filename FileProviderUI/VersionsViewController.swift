import AppKit
import FileProvider
import FileProviderUI
import SwiftUI
import libZephyr

/**
 The File Provider UI extension's principal controller: a thin AppKit host for
 the SwiftUI version-history sheet.

 Unlike the share extension, which is handed its subject before it builds a
 view, this one is built first and told what the action was invoked on
 afterwards — so the model is created empty here and given the file in
 ``prepare(forAction:itemIdentifiers:)``.
 */
final class VersionsViewController: FPUIActionExtensionViewController {
  private var model: FileVersionsModel!

  override func loadView() {
    // The extension's first code to run: Finder builds this controller and
    // asks for its view in one breath.
    CrashReporting.start(as: .fileProviderUI)
    let context = extensionContext
    let model = FileVersionsModel(
      service: SharedAccountService.shared,
      completion: FileVersionsCompletion(
        complete: { context.completeRequest() },
        cancel: {
          context.cancelRequest(
            withError: NSError(
              domain: FPUIErrorDomain,
              code: Int(FPUIExtensionErrorCode.userCancelled.rawValue)
            )
          )
        }
      )
    )
    self.model = model

    // Finder reads the sheet's size once, when it presents the extension, and
    // holds it there -- so the sheet declares one size and every state lays
    // itself out inside it.
    let size = NSSize(
      width: FileVersionsView.sheetSize.width,
      height: FileVersionsView.sheetSize.height
    )
    let hostingView = NSHostingView(rootView: FileVersionsView(model: model))
    hostingView.frame = NSRect(origin: .zero, size: size)
    view = hostingView
    preferredContentSize = size
  }

  override func prepare(
    forAction _: String,
    itemIdentifiers: [NSFileProviderItemIdentifier]
  ) {
    let domainIdentifier = extensionContext.domainIdentifier?.rawValue
    Task { await model.begin(inDomain: domainIdentifier, itemIdentifiers: itemIdentifiers) }
  }

  /**
   Presents an authentication failure the system ran into while enumerating.

   Nothing about version history, and not optional: the moment this extension
   exists, macOS routes the provider's `notAuthenticated` here instead of
   handling it itself, so leaving it unimplemented would replace what Finder
   used to show with an empty sheet.
   */
  override func prepare(forError error: any Error) {
    model.show(error)
  }
}
