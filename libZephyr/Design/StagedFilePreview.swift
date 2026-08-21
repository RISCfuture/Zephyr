import AppKit
@preconcurrency import QuickLookThumbnailing

/**
 A picture of what a staged file holds, for the share sheet's list of what is
 being sent.

 Two sources, cheapest first. The sharing app was already asked for the file and
 often has a preview of it in hand, so it answers without touching the disk.
 Quick Look renders the staged copy itself, which costs a trip to the thumbnail
 agent and only earns that for the files no app offered a preview of.

 Neither source is asked for a file-type icon. That is what the caller already
 has on screen, and a second one would swap a generic icon for a generic icon.
 Nothing is kept between calls either -- Quick Look has its own cache, and a
 sheet that is open for two seconds has nothing to remember.
 */
enum StagedFilePreview {
  /**
   The picture of `file`, or `nil` where neither source could draw one and the
   caller's own icon should stand.

   - Parameters:
     - file: The staged copy, which Quick Look renders when it is asked.
     - provider: The shared item `file` was copied from, where there is one.
     - sizePoints: The side of the square box the picture is drawn in.
     - scale: The scale of the display drawing it.
   */
  static func image(
    of file: URL,
    sharedBy provider: NSItemProvider?,
    fitting sizePoints: CGFloat,
    scale: CGFloat
  ) async -> NSImage? {
    if let provider,
      let offered = await offeredImage(from: provider, fitting: sizePoints, scale: scale)
    {
      return offered
    }
    guard !Task.isCancelled else { return nil }
    return await renderedImage(of: file, fitting: sizePoints, scale: scale)
  }

  /**
   Whatever preview the sharing app has, read out of whichever of the three
   shapes it hands back.

   The size asked for is in pixels, which is the one thing this differs from
   Quick Look on.
   */
  private static func offeredImage(
    from provider: NSItemProvider,
    fitting sizePoints: CGFloat,
    scale: CGFloat
  ) async -> NSImage? {
    let pixels = NSSize(width: sizePoints * scale, height: sizePoints * scale)
    let offered = try? await provider.loadPreviewImage(
      options: [NSItemProviderPreferredImageSizeKey: NSValue(size: pixels)]
    )
    return switch offered {
      case let image as NSImage: image
      case let data as Data: NSImage(data: data)
      case let url as URL: NSImage(contentsOf: url)
      default: nil
    }
  }

  /**
   Quick Look's render of the staged copy, decorated the way the Finder
   decorates a file's icon so it sits in the same column as the type icon it
   replaces.

   Cancelling the task the render started from does not reach the thumbnail
   agent on its own, so the request is withdrawn by hand.
   */
  private static func renderedImage(
    of file: URL,
    fitting sizePoints: CGFloat,
    scale: CGFloat
  ) async -> NSImage? {
    let request = QLThumbnailGenerator.Request(
      fileAt: file,
      size: CGSize(width: sizePoints, height: sizePoints),
      scale: scale,
      representationTypes: [.thumbnail, .lowQualityThumbnail]
    )
    request.iconMode = true
    return await withTaskCancellationHandler {
      try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
    } onCancel: {
      QLThumbnailGenerator.shared.cancel(request)
    }
  }
}
