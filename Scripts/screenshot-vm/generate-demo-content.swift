import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/*
 Writes the App Store demo account's fictional files: nine landscape illustrations for Photos and
 a handful of one-page PDFs for Documents and Projects.

   swift Scripts/screenshot-vm/generate-demo-content.swift ~/VMs/zephyr-share/demo-content

 Everything is drawn here, so the listing's first screenshot shows nothing anyone else holds the
 rights to, and every run draws the same pixels: each scene's ridges come from a fixed seed. The
 guest's populate-demo-account.sh copies the result into the demo account.
 */

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let fm = FileManager.default

try? fm.createDirectory(at: out, withIntermediateDirectories: true)

struct RNG {
  var state: UInt64

  mutating func next() -> Double {
    state = state &* 6364136223846793005 &+ 1442695040888963407
    return Double(state >> 11) / Double(1 << 53)
  }
}

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
  CGColor(
    srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
    green: CGFloat((hex >> 8) & 0xFF) / 255,
    blue: CGFloat(hex & 0xFF) / 255,
    alpha: a
  )
}

func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> CGColor {
  func ch(_ v: UInt32, _ s: UInt32) -> Double { Double((v >> s) & 0xFF) / 255 }
  return CGColor(
    srgbRed: ch(a, 16) * (1 - t) + ch(b, 16) * t,
    green: ch(a, 8) * (1 - t) + ch(b, 8) * t,
    blue: ch(a, 0) * (1 - t) + ch(b, 0) * t,
    alpha: 1
  )
}

/// A ridge line by midpoint displacement, as y values across `count` points.
func ridge(count: Int, roughness: Double, amplitude: Double, rng: inout RNG) -> [Double] {
  var pts = [Double](repeating: 0, count: count)
  pts[0] = rng.next() - 0.5
  pts[count - 1] = rng.next() - 0.5
  var step = count - 1
  var amp = amplitude
  while step > 1 {
    let half = step / 2
    var i = half
    while i < count {
      pts[i] = (pts[i - half] + pts[min(i + half, count - 1)]) / 2 + (rng.next() - 0.5) * amp
      i += step
    }
    amp *= roughness
    step = half
  }
  return pts
}

struct Scene {
  var name: String
  var sky: [UInt32]
  var sun: (x: Double, y: Double, r: Double, color: UInt32)?
  var layers: [(base: Double, amp: Double, rough: Double, color: UInt32)]
  var haze: UInt32
  var water: UInt32?
  var stars = false
  var seed: UInt64
}

func render(_ s: Scene, width: Int = 3000, height: Int = 2000) -> CGImage {
  let ctx = CGContext(
    data: nil,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
  )!
  let W = Double(width), H = Double(height)
  var rng = RNG(state: s.seed)
  // Sky, top to bottom.
  let colors = s.sky.map { rgb($0) } as CFArray
  let locs = (0..<s.sky.count).map { CGFloat($0) / CGFloat(s.sky.count - 1) }
  let grad = CGGradient(colorsSpace: nil, colors: colors, locations: locs)!
  ctx.drawLinearGradient(
    grad,
    start: CGPoint(x: 0, y: H),
    end: CGPoint(x: 0, y: H * 0.3),
    options: [.drawsAfterEndLocation]
  )
  if s.stars {
    for _ in 0..<900 {
      let x = rng.next() * W, y = H * 0.35 + rng.next() * H * 0.65, r = rng.next() * 2.4 + 0.4
      ctx.setFillColor(rgb(0xFFFFFF, CGFloat(0.25 + rng.next() * 0.7)))
      ctx.fillEllipse(in: CGRect(x: x, y: y, width: r, height: r))
    }
  }
  if let sun = s.sun {
    let c = CGPoint(x: sun.x * W, y: sun.y * H)
    let glow = CGGradient(
      colorsSpace: nil,
      colors: [rgb(sun.color, 0.55), rgb(sun.color, 0)] as CFArray,
      locations: [0, 1]
    )!
    ctx.drawRadialGradient(
      glow,
      startCenter: c,
      startRadius: 0,
      endCenter: c,
      endRadius: sun.r * W * 6,
      options: []
    )
    ctx.setFillColor(rgb(sun.color))
    ctx.fillEllipse(
      in: CGRect(
        x: c.x - sun.r * W,
        y: c.y - sun.r * W,
        width: sun.r * W * 2,
        height: sun.r * W * 2
      )
    )
  }
  // Ridges, far to near, each a little hazed toward the sky.
  let n = s.layers.count
  for (i, layer) in s.layers.enumerated() {
    let pts = ridge(count: 513, roughness: layer.rough, amplitude: 1, rng: &rng)
    let path = CGMutablePath()
    path.move(to: .zero)
    for (j, p) in pts.enumerated() {
      path.addLine(to: CGPoint(x: Double(j) / 512 * W, y: (layer.base + p * layer.amp) * H))
    }
    path.addLine(to: CGPoint(x: W, y: 0))
    path.closeSubpath()
    ctx.addPath(path)
    ctx.setFillColor(mix(layer.color, s.haze, Double(n - 1 - i) / Double(n) * 0.55))
    ctx.fillPath()
  }
  if let water = s.water {
    let top = H * 0.24
    let wg = CGGradient(
      colorsSpace: nil,
      colors: [rgb(water), mix(water, 0x000000, 0.45)] as CFArray,
      locations: [0, 1]
    )!
    ctx.saveGState()
    ctx.clip(to: CGRect(x: 0, y: 0, width: W, height: top))
    ctx.drawLinearGradient(wg, start: CGPoint(x: 0, y: top), end: .zero, options: [])
    for _ in 0..<260 {
      let y = rng.next() * top, x = rng.next() * W, w = 40 + rng.next() * 260
      ctx.setFillColor(rgb(0xFFFFFF, CGFloat(0.04 + rng.next() * 0.1)))
      ctx.fill(CGRect(x: x, y: y, width: w, height: 3))
    }
    ctx.restoreGState()
  }
  return ctx.makeImage()!
}

func writeJPEG(_ image: CGImage, _ url: URL) {
  let dest = CGImageDestinationCreateWithURL(
    url as CFURL,
    UTType.jpeg.identifier as CFString,
    1,
    nil
  )!
  CGImageDestinationAddImage(
    dest,
    image,
    [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary
  )
  CGImageDestinationFinalize(dest)
}

let scenes: [Scene] = [
  Scene(
    name: "Ridgeline at Dusk",
    sky: [0x2B3A67, 0x8E5A8C, 0xF0A37A, 0xFBD9A0],
    sun: (0.68, 0.42, 0.035, 0xFFE3B0),
    layers: [
      (0.52, 0.10, 0.55, 0x6B5B86), (0.44, 0.12, 0.55, 0x4A3F6B), (0.34, 0.14, 0.5, 0x2E2848),
      (0.22, 0.12, 0.5, 0x1A1630)
    ],
    haze: 0xF0A37A,
    water: nil,
    seed: 11
  ),
  Scene(
    name: "Morning on the Lake",
    sky: [0x7FB2E5, 0xB9D6F0, 0xF4E6CF],
    sun: (0.3, 0.36, 0.03, 0xFFF4D6),
    layers: [
      (0.40, 0.08, 0.5, 0x7F9AB3), (0.34, 0.09, 0.55, 0x4E6E73), (0.28, 0.06, 0.5, 0x2F4A44)
    ],
    haze: 0xC9DDEB,
    water: 0x5E89A8,
    seed: 23
  ),
  Scene(
    name: "Desert Road",
    sky: [0x3E7CC7, 0x8DBDE8, 0xF3D9B1],
    sun: nil,
    layers: [
      (0.38, 0.05, 0.4, 0xD9A066), (0.30, 0.07, 0.45, 0xC07A45), (0.18, 0.05, 0.4, 0x9C5A33)
    ],
    haze: 0xF3D9B1,
    water: nil,
    seed: 37
  ),
  Scene(
    name: "Night Sky over Camp",
    sky: [0x070B1E, 0x12204A, 0x2C3F74],
    sun: (0.78, 0.8, 0.015, 0xF2F0E6),
    layers: [
      (0.36, 0.10, 0.55, 0x1C2648), (0.26, 0.12, 0.5, 0x10172F), (0.16, 0.08, 0.5, 0x070B18)
    ],
    haze: 0x2C3F74,
    water: nil,
    stars: true,
    seed: 41
  ),
  Scene(
    name: "Coastline",
    sky: [0x5AA3D8, 0xA6D3EE, 0xE8F3F7],
    sun: (0.82, 0.62, 0.025, 0xFFFFF0),
    layers: [(0.36, 0.12, 0.6, 0x5F7D63), (0.30, 0.14, 0.6, 0x3E5A44)],
    haze: 0xBFDDEA,
    water: 0x2F7FA8,
    seed: 53
  ),
  Scene(
    name: "Autumn Hills",
    sky: [0x8FB6D9, 0xE7D2B2, 0xF4C48C],
    sun: (0.2, 0.46, 0.03, 0xFFE8BF),
    layers: [
      (0.46, 0.08, 0.5, 0xB78A5A), (0.38, 0.10, 0.5, 0xA6542D), (0.28, 0.10, 0.5, 0x7A3A1F),
      (0.16, 0.08, 0.5, 0x4C2414)
    ],
    haze: 0xF4C48C,
    water: nil,
    seed: 67
  ),
  Scene(
    name: "Glacier Valley",
    sky: [0x4C7FB8, 0x9EC3E2, 0xE6F0F7],
    sun: nil,
    layers: [
      (0.58, 0.16, 0.6, 0xDCE7F0), (0.46, 0.14, 0.55, 0x8DA6BD), (0.32, 0.12, 0.5, 0x546E84),
      (0.2, 0.08, 0.5, 0x2E4252)
    ],
    haze: 0xE6F0F7,
    water: nil,
    seed: 79
  ),
  Scene(
    name: "Harbor Sunset",
    sky: [0x3A2E5C, 0xC0566A, 0xF7A15C, 0xFFD58A],
    sun: (0.5, 0.3, 0.045, 0xFFE0A0),
    layers: [(0.3, 0.03, 0.4, 0x3B2A45)],
    haze: 0xF7A15C,
    water: 0x6A3C55,
    seed: 83
  ),
  Scene(
    name: "Pine Forest Trail",
    sky: [0x9CC4D8, 0xD6E6E1, 0xEEF2E6],
    sun: nil,
    layers: [
      (0.5, 0.10, 0.75, 0x6F8F7C), (0.4, 0.12, 0.8, 0x456B55), (0.28, 0.12, 0.85, 0x2B4A38),
      (0.14, 0.08, 0.85, 0x16291E)
    ],
    haze: 0xD6E6E1,
    water: nil,
    seed: 97
  )
]

let photos = out.appendingPathComponent("Photos")

try? fm.createDirectory(at: photos, withIntermediateDirectories: true)
for s in scenes { writeJPEG(render(s), photos.appendingPathComponent("\(s.name).jpg")) }

// MARK: - Documents

struct Doc {
  var path: String
  var title: String
  var subtitle: String
  var accent: UInt32
  var paragraphs: [String]
  var bars: [Double]?
}

func drawText(
  _ text: String,
  size: CGFloat,
  weight: NSFont.Weight,
  color: CGColor,
  in rect: CGRect,
  ctx: CGContext
) -> CGFloat {
  let font = NSFont.systemFont(ofSize: size, weight: weight)
  let style = NSMutableParagraphStyle()
  style.lineSpacing = size * 0.35
  let attr = NSAttributedString(
    string: text,
    attributes: [.font: font, .foregroundColor: NSColor(cgColor: color)!, .paragraphStyle: style]
  )
  let setter = CTFramesetterCreateWithAttributedString(attr)
  let fit = CTFramesetterSuggestFrameSizeWithConstraints(
    setter,
    CFRange(),
    nil,
    CGSize(width: rect.width, height: .greatestFiniteMagnitude),
    nil
  )
  let frameRect = CGRect(
    x: rect.minX,
    y: rect.maxY - fit.height,
    width: rect.width,
    height: fit.height
  )
  CTFrameDraw(
    CTFramesetterCreateFrame(setter, CFRange(), CGPath(rect: frameRect, transform: nil), nil),
    ctx
  )
  return fit.height
}

func writePDF(_ d: Doc) {
  let url = out.appendingPathComponent(d.path)
  try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  var box = CGRect(x: 0, y: 0, width: 612, height: 792)
  let ctx = CGContext(url as CFURL, mediaBox: &box, [kCGPDFContextTitle: d.title] as CFDictionary)!
  ctx.beginPDFPage(nil)
  ctx.setFillColor(rgb(0xFFFFFF)); ctx.fill(box)
  ctx.setFillColor(rgb(d.accent)); ctx.fill(CGRect(x: 0, y: 742, width: 612, height: 50))
  var y: CGFloat = 712
  y -=
    drawText(
      d.title,
      size: 26,
      weight: .bold,
      color: rgb(0x1B2430),
      in: CGRect(x: 56, y: 0, width: 500, height: y),
      ctx: ctx
    ) + 6
  y -=
    drawText(
      d.subtitle,
      size: 12,
      weight: .medium,
      color: rgb(0x6B7685),
      in: CGRect(x: 56, y: 0, width: 500, height: y),
      ctx: ctx
    ) + 22
  if let bars = d.bars {
    let maxV = bars.max()!
    for (i, v) in bars.enumerated() {
      let h = CGFloat(v / maxV) * 150
      ctx.setFillColor(i == bars.count - 1 ? rgb(d.accent) : rgb(d.accent, 0.45))
      ctx.fill(CGRect(x: 56 + CGFloat(i) * 62, y: y - 160, width: 44, height: h))
    }
    ctx.setFillColor(rgb(0xD5DAE0)); ctx.fill(CGRect(x: 56, y: y - 161, width: 500, height: 1))
    y -= 186
  }
  for p in d.paragraphs {
    y -=
      drawText(
        p,
        size: 11,
        weight: .regular,
        color: rgb(0x2E3846),
        in: CGRect(x: 56, y: 0, width: 500, height: y),
        ctx: ctx
      ) + 14
  }
  ctx.endPDFPage()
  ctx.closePDF()
}

let docs: [Doc] = [
  Doc(
    path: "Documents/Trip Itinerary.pdf",
    title: "Pacific Northwest, June",
    subtitle: "Ten days · Seattle to Portland",
    accent: 0x2F7FA8,
    paragraphs: [
      "Day 1 — Arrive Seattle, check in near Pike Place. Dinner reservation at 7:30.",
      "Days 2–3 — Ferry to Bainbridge, then the drive out to the Olympic Peninsula. Hurricane Ridge if the weather holds.",
      "Days 4–6 — Cabin at Lake Quinault. Rain forest loop, Ruby Beach at low tide on the morning of day 5.",
      "Days 7–10 — Down the coast to Cannon Beach, then Portland for the last two nights. Return flight Sunday 4:15 pm."
    ]
  ),
  Doc(
    path: "Documents/Household Budget.pdf",
    title: "Household Budget",
    subtitle: "Monthly totals, January to June",
    accent: 0x3E8E6B,
    paragraphs: [
      "Spending came in under plan for five of six months. March ran over because of the furnace repair, which the reserve covered.",
      "Groceries are steady at about 14 percent of take-home. Utilities dropped after the insulation work in February.",
      "Next quarter: move the travel savings to its own account and review the insurance renewals before August."
    ],
    bars: [4120, 3980, 5210, 4060, 3890, 3720]
  ),
  Doc(
    path: "Documents/Lease Renewal.pdf",
    title: "Lease Renewal",
    subtitle: "Unit 4B · term beginning September 1",
    accent: 0x6B5B95,
    paragraphs: [
      "This renewal extends the existing agreement for twelve months on the same terms, with the changes noted below.",
      "Rent adjusts as listed in Schedule A. Parking space 12 remains assigned to the unit. The pet addendum carries over unchanged.",
      "Please sign and return both copies by August 1. Keys and access fobs do not need to be reissued."
    ]
  ),
  Doc(
    path: "Projects/Cabin Renovation/Floor Plan.pdf",
    title: "Cabin — Floor Plan",
    subtitle: "Revision C · kitchen wall moved 18 in.",
    accent: 0xA6542D,
    paragraphs: [
      "Main floor opens the kitchen to the living room. The pantry moves to the north wall, under the stair.",
      "Loft keeps the existing joists; the new skylight sits between rafters 6 and 7.",
      "Electrical: four new circuits for the kitchen, one dedicated to the range."
    ]
  ),
  Doc(
    path: "Projects/Cabin Renovation/Contractor Estimate.pdf",
    title: "Contractor Estimate",
    subtitle: "Phase one · kitchen and loft",
    accent: 0x8A6A3B,
    paragraphs: [
      "Demolition and haul-away, framing for the moved wall, and the skylight rough-in.",
      "Cabinets and counters are owner-supplied. Estimate excludes permits, billed at cost.",
      "Schedule: six weeks from start, weather permitting for the roof work."
    ],
    bars: [12, 18, 9, 22, 7]
  ),
  Doc(
    path: "Projects/Garden/Planting Plan.pdf",
    title: "Spring Planting Plan",
    subtitle: "Raised beds 1–4",
    accent: 0x4F8A3C,
    paragraphs: [
      "Bed 1: tomatoes and basil along the trellis. Bed 2: lettuce in succession every two weeks.",
      "Bed 3: peppers and eggplant once nights stay above 55°F. Bed 4: herbs, plus marigolds along the edge.",
      "Drip line moves to the timer on the east spigot this year."
    ]
  )
]

docs.forEach(writePDF)
print("generated in \(out.path)")
