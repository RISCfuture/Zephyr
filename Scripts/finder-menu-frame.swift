import AppKit
import ApplicationServices

/*
 Where to crop an open Finder context menu, so the picture ends with Zephyr's
 actions.

 Two things make this worth a program rather than a line of AppleScript. The
 menu is invisible to System Events — `count of menus` on the Finder process
 answers zero while one is plainly on screen — so it has to be reached through
 the accessibility API directly. And the menu is longer than the picture wants:
 below Zephyr's actions sit the Quick Actions of whatever else is installed on
 the machine, which belong to other people's software and have no place in
 Zephyr's help. Those are populated lazily and are not in the tree at all when
 this runs, so they cannot be counted — but they always fall after the
 separator that closes Zephyr's group, and that separator can be found.

 So: locate the action the FileProviderUI extension declares, take every item
 that follows it until the group ends, and report the menu's own frame cut off
 at the last of them.

 Prints `x y width height` in screen points, ready for `screencapture -R`, or
 nothing at all when there is no menu to measure.
 */

/// The action `FileProviderUI/Info.plist` declares. Finding it is what anchors
/// the crop; a rename there has to be matched here.
let zephyrAction = "Show Previous Versions…"

/// Separators report a much shorter height than a row. Anything at or below
/// this is a rule rather than a command.
let separatorHeight: CGFloat = 16

/// Kept below the last row so the menu's rounded bottom edge is not sliced off.
/// Small on purpose: the next thing down is another app's Quick Action.
let bottomPadding: CGFloat = 8

/// Kept on the other three sides, where there is only the menu's shadow to
/// clear. This program emits the rectangle to photograph rather than a frame to
/// be padded by the caller, because the bottom is the one edge that must not
/// move.
let sidePadding: CGFloat = 22

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
  var value: CFTypeRef?
  return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func title(of element: AXUIElement) -> String {
  attribute(element, kAXTitleAttribute) as? String ?? ""
}

func children(of element: AXUIElement) -> [AXUIElement] {
  attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
}

func frame(of element: AXUIElement) -> CGRect? {
  guard let position = attribute(element, kAXPositionAttribute),
        let size = attribute(element, kAXSizeAttribute),
        CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
  else { return nil }
  var origin = CGPoint.zero
  var extent = CGSize.zero
  AXValueGetValue(position as! AXValue, .cgPoint, &origin)
  AXValueGetValue(size as! AXValue, .cgSize, &extent)
  return CGRect(origin: origin, size: extent)
}

/// The open context menu, which is the one menu that is not the menu bar's and
/// is tall enough to be a list of commands rather than a stub.
func contextMenu(in application: AXUIElement) -> AXUIElement? {
  func search(_ element: AXUIElement, depth: Int) -> AXUIElement? {
    let role = attribute(element, kAXRoleAttribute) as? String ?? ""
    if role == "AXMenuBar" { return nil }
    if role == "AXMenu", let bounds = frame(of: element), bounds.height > 100 { return element }
    guard depth < 6 else { return nil }
    for child in children(of: element) {
      if let found = search(child, depth: depth + 1) { return found }
    }
    return nil
  }
  return search(application, depth: 0)
}

guard let finder = NSWorkspace.shared.runningApplications
  .first(where: { $0.bundleIdentifier == "com.apple.finder" })
else { exit(1) }

guard let menu = contextMenu(in: AXUIElementCreateApplication(finder.processIdentifier)),
      let menuFrame = frame(of: menu)
else { exit(1) }

let items = children(of: menu)

guard let anchor = items.firstIndex(where: { title(of: $0) == zephyrAction }) else {
  FileHandle.standardError.write(
    Data(
      "no \"\(zephyrAction)\" in the menu: is the installed build the one with the extension?\n"
        .utf8))
  exit(1)
}

// Everything from Zephyr's action up to the rule that closes its group.
var lastRowBottom = menuFrame.minY

for item in items[anchor...] {
  guard let bounds = frame(of: item) else { continue }
  if bounds.height <= separatorHeight { break }
  lastRowBottom = max(lastRowBottom, bounds.maxY)
}

let region = CGRect(
  x: menuFrame.minX - sidePadding,
  y: menuFrame.minY - sidePadding,
  width: menuFrame.width + sidePadding * 2,
  height: (lastRowBottom - menuFrame.minY) + sidePadding + bottomPadding
)

print("\(Int(region.minX)) \(Int(region.minY)) \(Int(region.width)) \(Int(region.height))")
