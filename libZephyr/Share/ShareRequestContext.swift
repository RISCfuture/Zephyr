import Foundation

/**
 The share sheet's side of the flow: what the system handed the extension, and
 how the request ends.

 ``ExtensionShareRequestContext`` is the live implementation; a share flow under
 test supplies its own attachments and observes how the request was ended.
 */
@MainActor
public protocol ShareRequestContext {
  /// The shared items, flattened across the extension items carrying them.
  var sharedAttachments: [NSItemProvider] { get }

  /// Ends the request successfully, dismissing the sheet.
  func completeShare()

  /// Abandons the request.
  func cancelShare()
}

/// The live share request, over the context the system hands the extension.
@MainActor
public struct ExtensionShareRequestContext: ShareRequestContext {
  private let context: NSExtensionContext

  public var sharedAttachments: [NSItemProvider] {
    context.inputItems
      .compactMap { $0 as? NSExtensionItem }
      .flatMap { $0.attachments ?? [] }
  }

  public init(_ context: NSExtensionContext) {
    self.context = context
  }

  public func completeShare() {
    context.completeRequest(returningItems: [], completionHandler: nil)
  }

  public func cancelShare() {
    context.cancelRequest(withError: CocoaError(.userCancelled))
  }
}
