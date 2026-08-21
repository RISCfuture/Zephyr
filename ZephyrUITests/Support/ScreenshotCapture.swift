import AppKit
import XCTest
import XCUITestKit

/**
 Turning what is on screen into a published image.

 `xcodebuild` forwards no shell environment into the runner, so a test can't be
 told where to write: every capture goes into the result bundle as an
 attachment, and `Scripts/export-screenshots.sh` recovers it from there by name.
 */
@MainActor
extension XCTestCase {
  /// How long to leave between the two captures a stability check compares.
  private static let stabilityInterval: TimeInterval = 0.25

  /// How many comparisons to make before calling the screen unsettled.
  private static let stabilityLimit = 20

  /// How long to give the screen to stop changing, which is every comparison
  /// the limit allows for.
  private static var settleTimeout: TimeInterval {
    stabilityInterval * TimeInterval(stabilityLimit)
  }

  /// How far past its own frame a window's shadow reaches. Generous on purpose:
  /// whatever of it the shadow does not fill is the flat fill the page is
  /// painted in, and the margin is published whole either way — see
  /// ``capture(_:around:changedFrom:)``.
  private static let windowShadowMargin: CGFloat = 64

  /**
   Attaches `window` and the shadow around it, under `slug`.

   Taken off the screen and cropped to the window's frame *grown* by a margin,
   rather than off the window itself. `XCUIElement.screenshot()` crops to the
   frame exactly, and a macOS window's shadow lies outside its frame — so that
   route yields a picture that stops at a hard edge, with the shadow surviving
   only as a dark wedge in each rounded corner. On a page whose background the
   captures are staged to match, a hard edge is the one thing that reads as a
   pasted-on rectangle.

   The margin is kept whole rather than trimmed back to where the shadow fades
   out. Trimming would make the size a function of how far the shadow reads,
   and that differs by appearance — a dark window's shadow disappears into a
   dark backdrop some thirty points sooner than a light one's does, so the same
   window would be published at two sizes. What the margin holds beyond the
   shadow is the flat fill the page is painted in, which costs a few bytes and
   shows as nothing.

   `window` has to be the only one on screen: the margin would otherwise take
   in whatever else lies within it.
   */
  @discardableResult
  func capture(
    _ slug: String,
    around window: XCUIElement,
    changedFrom previous: Data? = nil
  ) -> Data {
    let margin = Self.windowShadowMargin
    return captureScreen(
      slug,
      within: window.frame.insetBy(dx: -margin, dy: -margin),
      framing: .region,
      changedFrom: previous
    )
  }

  /**
   Attaches `region` exactly as it is drawn, under `slug`.

   For a detail of a window rather than a window: a section of the settings
   form is a heading, some rows, and a footer, and a `Form`'s `Section` is not
   one element in the accessibility tree that the four of them could be framed
   on. The caller measures the band it wants off the elements that *are* in the
   tree and hands it over already fixed, so the size published is the size
   asked for — the same in both appearances, since nothing about a form's
   layout follows the appearance it is drawn in.

   No margin is added, and none is wanted: what surrounds a band cut out of a
   window is the rest of that window rather than the backdrop, so there is no
   shadow to leave room for.
   */
  func captureScreenRegion(_ slug: String, within region: CGRect) {
    captureScreen(slug, within: region, framing: .region, changedFrom: nil)
  }

  /**
   Attaches the subject inside `region` in a frame of `publishedSize`, under
   `slug`.

   For the menu-bar panel, which is the one surface with no element to frame:
   SwiftUI puts a `MenuBarExtra`'s window into no accessibility tree at all —
   not the window, not one control inside it — so there is nothing for
   ``capture(_:around:changedFrom:)`` to be given, and the caller has to say
   roughly where to look instead. Whatever inside `region` is not the staged
   backdrop is what the frame is laid over, so the region only has to be
   generous.

   The frame's size is stated by the caller rather than taken from the subject,
   and that is what makes this slug publishable at all. Every consumer writes
   one width and one height per slug and swaps the dark file in behind a
   `<picture>` source, so the two appearances have to come out at one size — and
   a frame cut back to where the subject stops being distinguishable from the
   backdrop does not: a dark panel's shadow disappears into a dark backdrop some
   ten points sooner than a light one's does. That is the same measurement
   ``capture(_:around:changedFrom:)`` keeps its whole margin rather than trim,
   for the same reason. So the search finds the panel wherever macOS drew it,
   and a frame of a fixed size is laid over what it found; what that frame holds
   beyond the shadow is the flat fill the page is painted in, which costs a few
   bytes and shows as nothing.

   `publishedSize` has to hold the subject and its shadow together, which is
   asserted rather than trusted: a frame the panel overflowed would publish it
   with an edge cut off, and nothing else would say so.
   */
  func captureScreenContent(_ slug: String, within region: CGRect, framedTo publishedSize: CGSize) {
    captureScreen(slug, within: region, framing: .content(size: publishedSize), changedFrom: nil)
  }

  /**
   Attaches whatever is not the backdrop inside `region`.

   The slug is asserted to be bare `[a-z0-9-]+` — no extension, ever. The
   export recovers each name from the mangled one `xcresulttool` records, which
   re-reads a dot as an extension, so a slug carrying one is silently mis-filed.

   `changedFrom` is what makes a sequence of captures work: a page that has
   been asked to advance settles on its *old* contents until the new ones are
   drawn, so a wait for stillness alone would file the previous page twice and
   lose the last one.
   */
  @discardableResult
  private func captureScreen(
    _ slug: String,
    within region: CGRect,
    framing: ScreenFraming,
    changedFrom previous: Data?
  ) -> Data {
    assertIsSlug(slug)
    for _ in 0..<Self.stabilityLimit {
      guard let content = settledScreen(within: region, framing: framing)
      else { return Data() }
      if content != previous {
        attach(content, as: slug)
        return content
      }
      pause(for: Self.stabilityInterval)
    }
    XCTFail("The screen settled on nothing new — something is still animating.")
    return Data()
  }

  /**
   One settled capture of `region`, reduced to what `framing` publishes.

   `region` is intersected with the area a window can occupy, which keeps the
   menu bar and the Dock out: neither is the backdrop, and either one left in
   the frame anchors the search to the edge it sits on — which is how a search
   for a 320-point panel comes back holding the whole display. Naming a region
   at all is the other half of that. The screen's own far edges carry a pixel or
   two that is not quite the backdrop, and the search cannot tell those from the
   faintest reach of a shadow, so it is never shown the whole screen.
   */
  private func settledScreen(within region: CGRect, framing: ScreenFraming) -> Data? {
    let screenshot = waitForStableScreenImage(within: region)
    guard let full = screenshot.image.cgImage(forProposedRect: nil, context: nil, hints: nil),
      let screen = NSScreen.main
    else {
      XCTFail("The screen capture carried no bitmap.")
      return nil
    }
    let scale = CGFloat(full.width) / screen.frame.width
    let area = screen.placeableArea(inPixelsOf: full).intersection(
      CGRect(
        x: region.minX * scale,
        y: region.minY * scale,
        width: region.width * scale,
        height: region.height * scale
      )
    )
    guard let cropped = full.cropping(to: area) else {
      XCTFail("The captured area lay outside the screen.")
      return nil
    }
    guard let published = publishedImage(of: cropped, framing: framing, scale: scale),
      let png = NSBitmapImageRep(cgImage: published).representation(using: .png, properties: [:])
    else {
      XCTFail("Nothing but the backdrop was in the captured area.")
      return nil
    }
    return png
  }

  /**
   The part of `cropped` a framing publishes.

   ``ScreenFraming/region`` publishes the crop whole, whose size is the region
   the caller named and so is already the same in both appearances.
   ``ScreenFraming/content(size:)`` publishes a frame of a stated size laid over
   the subject inside the crop, which is what gives a searched-for subject a
   size that does not follow its own pixels.
   */
  private func publishedImage(
    of cropped: CGImage,
    framing: ScreenFraming,
    scale: CGFloat
  ) -> CGImage? {
    switch framing {
      case .region:
        cropped
      case .content(let size):
        cropped.cropping(to: contentFrame(ofSize: size, in: cropped, scale: scale))
    }
  }

  /**
   Where a frame of `size` points sits over the subject inside `image`.

   Centred on whatever in `image` is not the backdrop, then moved — never
   resized — until it lies inside the image, so the frame keeps the size it was
   given wherever macOS happened to draw the subject.

   Both of the ways this can go wrong are asserted, because both would publish a
   plausible-looking image of the wrong thing: a frame the subject overflows
   ships a panel with an edge cut off, and a frame the searched region cannot
   hold gets silently intersected down to a smaller one.
   */
  private func contentFrame(ofSize size: CGSize, in image: CGImage, scale: CGFloat) -> CGRect {
    let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    let subject = contentBounds(of: image)
    let frame = CGRect(
      origin: .zero,
      size: CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    )
    .centered(on: subject)
    .heldInside(bounds)
    XCTAssertTrue(
      frame.contains(subject),
      "A \(size.width)×\(size.height)-point frame does not hold this subject, which measures "
        + "\(subject.width / scale)×\(subject.height / scale) points with its shadow. The frame is "
        + "stated rather than measured so that both appearances publish at one size, so growing it "
        + "is a change to make deliberately — in both the capture and every page that embeds it."
    )
    XCTAssertTrue(
      bounds.contains(frame),
      "The searched region is smaller than the frame published from it, so the capture would come "
        + "out cropped. The region only has to be generous; widen it rather than the frame."
    )
    return frame
  }

  /**
   The bounds of everything in `image` that is not the flat fill its top-left
   pixel is, which for a staged capture is the backdrop.

   A window's shadow fades into that fill, so the bounds stop where the shadow
   stops being distinguishable — which is the edge a reader would draw too.
   */
  private func contentBounds(of image: CGImage) -> CGRect {
    guard let pixels = Pixels(image) else {
      XCTFail("The capture could not be read as pixels.")
      return CGRect(x: 0, y: 0, width: image.width, height: image.height)
    }
    let backdrop = pixels.colorAt(x: 0, y: 0)
    let columns = 0..<image.width
    let rows = 0..<image.height
    let isContentColumn = { (x: Int) in rows.contains { !pixels.matches(backdrop, x: x, y: $0) } }
    let isContentRow = { (y: Int) in columns.contains { !pixels.matches(backdrop, x: $0, y: y) } }
    guard let left = columns.first(where: isContentColumn),
      let right = columns.reversed().first(where: isContentColumn),
      let top = rows.first(where: isContentRow),
      let bottom = rows.reversed().first(where: isContentRow)
    else {
      XCTFail("The whole capture was the backdrop colour.")
      return CGRect(x: 0, y: 0, width: image.width, height: image.height)
    }
    return CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
  }

  /**
   Files `png` in the result bundle under `slug`.

   `.keepAlways` is load-bearing: attachments default to `.deleteOnSuccess`,
   and these tests pass by design, so the images would be absent from the
   bundle the export reads.
   */
  private func attach(_ png: Data, as slug: String) {
    let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
    attachment.name = slug
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  /**
   The whole screen, once two captures of `region` running are byte-identical.

   Two captures of an untouched area are identical to the byte, so a difference
   means something in it is still moving — an overlay scrollbar fading out, a
   sheet finishing its slide, a layout pass yet to land. The comparison is
   written as an expectation and handed to `XCTWaiter`, which paces the sampling
   and holds the deadline, so waiting costs the runner nothing but the time it
   takes.

   `region` rather than the whole screen, though the whole screen is what is
   captured and cropped afterwards. A menu bar holds other people's software,
   and a countdown or a clock reading seconds redraws every second — which is
   about as often as the waiter re-evaluates, so every pair of samples straddles
   a tick and the screen is never still by this measure. The run then fails
   naming an animation nobody can find, on a Mac where nothing about Zephyr is
   moving at all. What has to hold still is what is being photographed.
   */
  private func waitForStableScreenImage(within region: CGRect) -> XCUIScreenshot {
    let sampler = ScreenSampler(region: region)
    let settled = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in sampler.isSettled() },
      object: nil
    )
    if XCTWaiter().wait(for: [settled], timeout: Self.settleTimeout) != .completed {
      XCTFail("The screen never settled — something is still animating.")
    }
    return sampler.latest
  }

  /**
   Lets `interval` pass.

   `XCTWaiter` runs the run loop while it waits on an expectation nothing
   fulfils, so the runner goes on servicing the app it is watching — where a
   sleep would stop the thread dead for the same quarter second.
   */
  private func pause(for interval: TimeInterval) {
    let nothing = XCTestExpectation(description: "A beat between screen comparisons")
    nothing.isInverted = true
    _ = XCTWaiter().wait(for: [nothing], timeout: interval)
  }

  private func assertIsSlug(_ slug: String) {
    XCTAssertNotNil(
      slug.range(of: "^[a-z0-9-]+$", options: .regularExpression),
      "Screenshot slug “\(slug)” has to be lowercase letters, digits, and hyphens."
    )
  }

  /**
   Moves the pointer onto the backdrop beside `element`, where nothing reacts
   to it. XCUITest leaves the pointer wherever the last click landed, so
   without this a shot ships a row or a button wearing a hover treatment the
   reader can't account for.

   Beside rather than inside: every surface Zephyr is captured on is either an
   account row, a form row, or a panel action, and all three light up under the
   pointer. A normalized offset outside the unit square resolves to a point
   outside the element, and the staged backdrop covers the screen, so this
   lands on a flat fill however the window happens to be placed.
   */
  func parkPointer(beside element: XCUIElement) {
    element.coordinate(withNormalizedOffset: CGVector(dx: -0.6, dy: 0.5)).hover()
  }
}

/**
 How a capture decides which part of the region it was given to publish.

 The two are not interchangeable, and the difference is a size rather than a
 taste: an image's dimensions are its frame's, and every consumer writes one
 width and one height per slug for both appearances. So a frame may follow the
 accessibility tree, which draws the same rectangle in either appearance, but
 never the rendered pixels, which do not.
 */
private enum ScreenFraming {
  /// The region itself, at whatever size the caller fixed it to.
  case region

  /// A frame of this size in points, laid over whatever inside the region is
  /// not the staged backdrop.
  case content(size: CGSize)
}

/**
 Successive captures of the screen, and whether the last two match inside one
 region of it.

 A reference type because the predicate an expectation evaluates carries no
 state of its own: each evaluation has to be able to see what the one before it
 captured.
 */
@MainActor
private final class ScreenSampler {
  private let region: CGRect
  private var current: Data?
  private var sampled: XCUIScreenshot?

  /// The most recent capture, which is the settled screen once ``isSettled()``
  /// has answered true. Nothing sampled yet means a capture taken now.
  var latest: XCUIScreenshot { sampled ?? XCUIScreen.main.screenshot() }

  /// Samples the screen, comparing only what lies inside `region` in points.
  init(region: CGRect) {
    self.region = region
  }

  /// The bytes of `region` in `screenshot`, or of the whole capture where the
  /// region cannot be read out of it — which leaves the comparison exactly as
  /// strict as it was before there was a region to narrow it to.
  private static func bytes(of screenshot: XCUIScreenshot, within region: CGRect) -> Data {
    guard let full = screenshot.image.cgImage(forProposedRect: nil, context: nil, hints: nil),
      let screen = NSScreen.main
    else { return screenshot.pngRepresentation }
    let scale = CGFloat(full.width) / screen.frame.width
    let area = CGRect(x: 0, y: 0, width: CGFloat(full.width), height: CGFloat(full.height))
      .intersection(
        CGRect(
          x: region.minX * scale,
          y: region.minY * scale,
          width: region.width * scale,
          height: region.height * scale
        )
      )
    guard !area.isEmpty, let cropped = full.cropping(to: area),
      let png = NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:])
    else { return screenshot.pngRepresentation }
    return png
  }

  /**
   Captures the screen and reports whether `region` is byte-identical to the
   capture before it.

   The first call has nothing to compare against and answers false, which is
   what spaces the two captures a comparison is made of: they are taken one
   evaluation apart rather than back to back, so an animation that has yet to
   start when the first is taken has moved by the second.
   */
  func isSettled() -> Bool {
    let sample = XCUIScreen.main.screenshot()
    sampled = sample
    let inside = Self.bytes(of: sample, within: region)
    defer { current = inside }
    guard let current else { return false }
    return inside == current
  }
}

/**
 What a Mac has to be set to before its captures can be published.

 None of these can be forced per-process — the accessibility settings live in a
 domain the argument domain doesn't reach, and the display's scale is the
 display's — so they are asserted instead. A machine that fails one turns a
 silent ten-file diff into a skip that names what to change.
 */
enum ScreenshotPreconditions {

  /// Whether this Mac draws the app the way the published images are drawn.
  static var machineCanCapture: Bool { firstUnmetRequirement == nil }

  /// The first requirement this Mac fails, for the skip message to name.
  static var unmetRequirement: String { firstUnmetRequirement ?? "every requirement is met" }

  private static var firstUnmetRequirement: String? {
    requirements.first { !$0.isMet }?.name
  }

  private static var requirements: [(name: String, isMet: Bool)] {
    let workspace = NSWorkspace.shared
    return [
      ("a 2× Retina display as the main display", NSScreen.main?.backingScaleFactor == 2),
      (
        "the multicolour accent colour",
        UserDefaults.standard.object(forKey: "AppleAccentColor") == nil
      ),
      ("Reduce Transparency off", !workspace.accessibilityDisplayShouldReduceTransparency),
      ("Increase Contrast off", !workspace.accessibilityDisplayShouldIncreaseContrast),
      (
        "Differentiate Without Colour off",
        !workspace.accessibilityDisplayShouldDifferentiateWithoutColor
      ),
      ("Reduce Motion off", !workspace.accessibilityDisplayShouldReduceMotion)
    ]
  }
}

/**
 Random access to a capture's pixels, for the one measurement the accessibility
 tree cannot answer.

 `NSBitmapImageRep.colorAt(x:y:)` would do the same thing far more slowly — it
 builds an `NSColor` per pixel, and a trim reads a whole screen's worth — so the
 bitmap is drawn once into a buffer of known layout and read as bytes.
 */
private struct Pixels {
  /// How far apart two samples of one flat fill may be and still count as the
  /// same colour. A capture is converted out of the display's colour space
  /// before it is published, but it is read here as the display drew it, and a
  /// flat fill drawn on a wide-gamut display carries a little dither.
  private static let tolerance = 2

  private static let bytesPerPixel = 4

  private let bytes: [UInt8]
  private let bytesPerRow: Int

  init?(_ image: CGImage) {
    let bytesPerRow = image.width * Self.bytesPerPixel
    var bytes = [UInt8](repeating: 0, count: bytesPerRow * image.height)
    guard
      let context = CGContext(
        data: &bytes,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    self.bytes = bytes
    self.bytesPerRow = bytesPerRow
  }

  func colorAt(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
    let offset = y * bytesPerRow + x * Self.bytesPerPixel
    return (bytes[offset], bytes[offset + 1], bytes[offset + 2])
  }

  func matches(_ color: (r: UInt8, g: UInt8, b: UInt8), x: Int, y: Int) -> Bool {
    let sample = colorAt(x: x, y: y)
    return abs(Int(sample.r) - Int(color.r)) <= Self.tolerance
      && abs(Int(sample.g) - Int(color.g)) <= Self.tolerance
      && abs(Int(sample.b) - Int(color.b)) <= Self.tolerance
  }
}

extension CGRect {
  /// This rectangle over the middle of `subject`, at the size it already has.
  /// Rounded to whole pixels, since a bitmap has no others and a fractional
  /// rectangle is integralized on the way into a crop — which would take the
  /// size with it.
  fileprivate func centered(on subject: CGRect) -> CGRect {
    CGRect(
      x: (subject.midX - width / 2).rounded(),
      y: (subject.midY - height / 2).rounded(),
      width: width,
      height: height
    )
  }

  /// This rectangle moved, never resized, until it lies inside `bounds` — so a
  /// frame of a stated size stays that size however near an edge its subject
  /// sits. A `bounds` too small to hold it is left overflowing, for the caller
  /// to fail on rather than quietly publish.
  fileprivate func heldInside(_ bounds: CGRect) -> CGRect {
    CGRect(
      x: min(max(minX, bounds.minX), bounds.maxX - width),
      y: min(max(minY, bounds.minY), bounds.maxY - height),
      width: width,
      height: height
    )
  }
}

extension NSScreen {
  /**
   ``visibleFrame`` as a rectangle in `image`'s pixels, with the top-left origin
   a bitmap is indexed from rather than the bottom-left one AppKit reports.
   */
  fileprivate func placeableArea(inPixelsOf image: CGImage) -> CGRect {
    let scale = CGFloat(image.width) / frame.width
    return CGRect(
      x: (visibleFrame.minX - frame.minX) * scale,
      y: (frame.maxY - visibleFrame.maxY) * scale,
      width: visibleFrame.width * scale,
      height: visibleFrame.height * scale
    )
  }
}
