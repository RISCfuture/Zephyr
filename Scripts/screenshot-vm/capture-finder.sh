#!/bin/bash
#
# Run inside the screenshot VM. Opens a folder in a Finder window of a fixed size and photographs
# that window, shadow and all, over transparency.
#
#   capture-finder.sh <folder> <icon|list|column|flow> <name> [icon-size] [height] [width] [select]
#
# Writes <name>.png to the VM's `out` share. [select] names an item in <folder> to select first,
# which in column view opens it in the next column while the window stays on <folder>. A window photographed by its window ID comes out
# with its corners and shadow over transparency, which is what lets the store export lay it on any
# canvas without a seam. The App Store's first screenshot is
#
#   capture-finder.sh ~/Library/CloudStorage/Zephyr-*/Photos icon finder-window 112 500 1120
#
# after which the host converts out/finder-window.png into docs/assets/system/finder-window.webp.

set -euo pipefail

readonly OUT_DIR="/Volumes/My Shared Files/out"
readonly LEFT=200
readonly TOP=120

folder="$1"
view="$2"
name="$3"
icon_size="${4:-64}"
height="${5:-600}"
width="${6:-960}"
selection="${7:-}"

osascript <<APPLESCRIPT
tell application "Finder"
  activate
  close every Finder window
  open (POSIX file "${folder}" as alias)
  set current view of front Finder window to ${view} view
  if "${view}" is "icon" then
    set icon size of icon view options of front Finder window to ${icon_size}
    set arrangement of icon view options of front Finder window to arranged by name
  end if
  set sidebar width of front Finder window to 200
  set bounds of front Finder window to {${LEFT}, ${TOP}, $((LEFT + width)), $((TOP + height))}
  if "${selection}" is not "" then select item "${selection}" of target of front Finder window
end tell
APPLESCRIPT

# Long enough for thumbnails of cloud-only images to arrive from Dropbox.
sleep 6

window_id="$(osascript -l JavaScript -e '
  ObjC.import("CoreGraphics");
  const windows = ObjC.deepUnwrap(ObjC.castRefToObject(
    $.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, 0)));
  const finder = windows.find(w => w.kCGWindowOwnerName === "Finder" && w.kCGWindowLayer === 0);
  finder ? String(finder.kCGWindowNumber) : "";')"
[ -n "${window_id}" ] || { echo "error: no Finder window to photograph" >&2; exit 1; }
screencapture -x -l"${window_id}" "${OUT_DIR}/${name}.png"
echo "${OUT_DIR}/${name}.png"
