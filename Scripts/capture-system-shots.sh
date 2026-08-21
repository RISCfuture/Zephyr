#!/bin/bash
#
# Photographs the surfaces macOS draws around Zephyr, which the screenshot suite cannot.
#
#   Scripts/capture-system-shots.sh [--appearance light|dark|both] [--file <path>] [subject]…
#
# `fastlane screenshots` photographs surfaces Zephyr draws every pixel of, against a staged
# backdrop, in a process pinned to one appearance, from canned accounts that reach neither the
# keychain nor the network. That is what makes those images a build product: run it twice and get
# the same bytes.
#
# None of it is available here. The subject of every capture below is a surface *macOS* draws with
# Zephyr inside it — Finder's context menu, the version-history sheet on a Finder window, the widget
# in Notification Center, the control in Control Center, the File Providers sheet in System
# Settings — and each one needs a real account, a registered domain, and the app installed in
# /Applications, because Finder resolves a domain's actions from the bundle holding the provider
# serving that domain. Nothing can put a flat fill behind Finder, and `NSApp.appearance` pins
# Zephyr's process rather than anyone else's, so both appearances mean switching the whole Mac.
#
# So this is run by hand, deliberately, and never by CI or by the screenshot lane. What it writes
# goes to directories the lane's export script does not own:
#
#   * docs/assets/system/<slug>.webp   — for the marketing site
#   * Help/…/en.lproj/system/<slug>.webp — the same images again, for the Apple Help book
#
# (The export script empties docs/assets/screenshots and …/en.lproj/images on every run, which is
# why these cannot live beside the generated ones.)
#
# What it will not do: create, move, or delete anything in your Dropbox. The Finder subjects act on
# a file you name with --file, so choosing what appears in a published image stays yours. Read the
# result before committing it — whatever was in the Finder window is in the picture.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly SITE_DIR="${REPO_ROOT}/docs/assets/system"
readonly HELP_DIR="${REPO_ROOT}/Help/Zephyr.help/Contents/Resources/en.lproj/system"
readonly SRGB_PROFILE="/System/Library/ColorSync/Profiles/sRGB Profile.icc"

# The installed app, not a build. A DerivedData copy vends no Finder actions at all: Finder reads
# them from the bundle containing the File Provider serving the domain, which is whatever is in
# /Applications.
readonly INSTALLED_APP="/Applications/Zephyr.app"

# The System Settings pane holding the one-time File Provider enablement, named so the pane opens on
# the sheet rather than above it. Kept in step with SystemSettings.fileProviders in ZephyrScenes.
readonly FILE_PROVIDERS_URL="x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.fileprovider-nonui"

# Every subject this can photograph, and what each is for.
readonly SUBJECTS=(
  finder-menu                   # Zephyr's actions in a file's context menu
  finder-versions               # the version-history sheet, on the Finder window that opened it
  desktop-widget                # the sync-status widget where people actually put it
  control-center-pause          # Zephyr's pause control in Control Center
  system-settings-file-providers # the switch macOS makes people turn on before Finder shows a domain
)

# How long to let a surface finish appearing before it is photographed. Generous: a menu, a sheet,
# and a settings pane all animate in, and a capture of one mid-slide is a wasted run.
readonly SETTLE_SECONDS=2

# How far below the Finder window to photograph when the subject is a menu hanging off it. A
# context menu is as long as whatever has put items in it — Zephyr's two actions, Quick Actions,
# and every other app's contributions — so this reaches well past any of them and lets
# `screencapture` clamp the region to the screen.

# How long to let the version-history sheet arrive. Longer than anything else here: choosing the
# action launches the UI extension, which then asks Dropbox what revisions it holds before it has
# anything to draw.
readonly SHEET_SECONDS=8

# How long the version-history subject waits for you to choose its menu item. See the comment above
# capture_finder_versions for why that step is yours.
readonly CHOICE_SECONDS=20

# The sound played when that step comes round. Any of the system sounds would do; this one is short
# and carries over whatever else is playing.
readonly ATTENTION_SOUND="/System/Library/Sounds/Ping.aiff"
# Long enough to be seen on a run you walked away from, short enough that an unclicked one
# is gone before the next run.
readonly FINISH_ALERT_SECONDS=300
# Also how a leftover one is found and taken down at the start of the next run.
readonly FINISH_ALERT_TITLE="Zephyr system shots: finished"
# A Control Center tile, and how much of the glass around the grid to keep with it.
readonly CONTROL_TILE_SIZE=64
readonly CONTROL_TILE_PADDING=14
# How many times to ask Control Center for a frame before giving up on it.
readonly CONTROL_CENTER_ATTEMPTS=8
readonly BACKDROP_SOURCE="${REPO_ROOT}/Scripts/capture-backdrop.swift"
readonly MENU_FRAME_SOURCE="${REPO_ROOT}/Scripts/finder-menu-frame.swift"
MENU_FRAME_BINARY=""
# Left, top, right, bottom — comfortably larger than any context menu it has to sit behind.
readonly FINDER_WINDOW_BOUNDS="180, 120, 1420, 900"
BACKDROP_BINARY=""
BACKDROP_PID=""
# Which appearance the pass in progress is capturing, so each subject can raise a matching backdrop.
APPEARANCE_NOW="light"

APPEARANCE_MODE="light"
TARGET_FILE=""

# The desktop widget to photograph, by the name its window carries — a widget's
# `configurationDisplayName`. Zephyr vends one widget, and this is its.
WIDGET_NAME="Sync Status"

# The background `osascript` holding a menu open, waiting to be reaped once it closes.
MENU_SCRIPT_PID=""

# Where a snapshot is held between being taken and being converted.
WORK=""
ORIGINAL_DARK_MODE=""

# What has reached the published directories so far, named in the alert that ends the run.
CAPTURED_SLUGS=()

usage() {
  cat >&2 <<USAGE
usage: $(basename "$0") [--appearance light|dark|both] [--file <path>] [subject]...

subjects: ${SUBJECTS[*]}
          (default: all of them)

  --appearance  Which appearance to capture in. "both" switches the whole Mac and
                switches it back; there is no per-process appearance for Finder.
  --file        The file the Finder subjects right-click. Must be inside a Zephyr
                domain's folder under ~/Library/CloudStorage. Required by
                finder-menu and finder-versions; nothing is created or deleted.
  --widget-name The desktop widget to photograph, by name (default: Sync Status).
                It has to be on the desktop already; this adds nothing.
USAGE
  exit 2
}

# ---------------------------------------------------------------------------- preconditions

require_tools() {
  local tool
  for tool in magick cwebp cliclick; do
    command -v "${tool}" >/dev/null ||
      { echo "error: ${tool} is not installed (brew install ${tool})" >&2; exit 1; }
  done
  [ -f "${SRGB_PROFILE}" ] || { echo "error: no sRGB profile at ${SRGB_PROFILE}" >&2; exit 1; }
}

# Refuses a run that would photograph the wrong Zephyr, or none. Accessibility permission is not
# checked here because there is no way to ask: the first osascript that needs it either works or
# raises, and the message it raises names the setting.
require_installed_app() {
  [ -d "${INSTALLED_APP}" ] || {
    echo "error: no app at ${INSTALLED_APP}" >&2
    echo "       Finder reads a domain's actions from the bundle serving that domain, so a" >&2
    echo "       DerivedData build vends none. Copy the build to /Applications first." >&2
    exit 1
  }
}

# The file the Finder subjects act on, checked to be somewhere a Zephyr domain actually serves.
require_target_file() {
  [ -n "${TARGET_FILE}" ] || {
    echo "error: this subject needs --file <path> — a file inside a Zephyr domain's folder." >&2
    exit 1
  }
  [ -f "${TARGET_FILE}" ] || { echo "error: no file at ${TARGET_FILE}" >&2; exit 1; }
  case "${TARGET_FILE}" in
    "${HOME}"/Library/CloudStorage/*) ;;
    *)
      echo "error: ${TARGET_FILE} is not under ~/Library/CloudStorage, so no Zephyr domain" >&2
      echo "       serves it and its context menu carries none of Zephyr's actions." >&2
      exit 1
      ;;
  esac
}

# ---------------------------------------------------------------------------- appearance

osa() { osascript "$@"; }

current_dark_mode() {
  osa -e 'tell application "System Events" to tell appearance preferences to get dark mode'
}

set_dark_mode() {
  osa -e "tell application \"System Events\" to tell appearance preferences to set dark mode to $1" \
    >/dev/null
}

# Puts the Mac back the way it was found, whether the run finished or failed. Switching the whole
# machine is the only way to photograph Finder in both appearances, and leaving someone's Mac in the
# other one is not an acceptable side effect of taking pictures.
restore_appearance() {
  [ -n "${ORIGINAL_DARK_MODE}" ] || return 0
  set_dark_mode "${ORIGINAL_DARK_MODE}" || true
}

# ---------------------------------------------------------------------------- capture

# The frame of one window, as "x y width height" in screen points.
#
# One line, because `osascript -e` takes one statement per argument: a `tell … to tell …` with the
# instruction on the line below it is a syntax error rather than a two-line script.
window_frame() {
  local process="$1" window="$2"
  osa -e "tell application \"System Events\" to tell process \"${process}\" to get {value of attribute \"AXPosition\", value of attribute \"AXSize\"} of ${window}" |
    tr -d ','
}

# Opens one of ControlCenter's menu bar items and answers the frame of the panel it drops down.
#
# Clicking and measuring in one script on purpose: these panels close whenever focus shifts, and a
# second `osascript` is a second process for focus to shift to.
#
# What is measured is the controls, not the window around them. ControlCenter's `window 1` is far
# larger than the panel drawn inside it — most of it is empty, and a picture of the window is a
# picture of the desktop, the files on it, and whatever was left open behind. That window holds a
# single group whose children are the individual controls, and the union of their frames is the
# panel. A child as large as the window is more of the same emptiness and is left out of the union.
# Their labels are still no use — every one is an unlabelled "toggle button", so there is no asking
# which row is Zephyr's — but their frames are exact.
#
# The union comes back tight. `snap_region` grows whatever it is given by a margin, which is what
# keeps the panel's shadow in the picture.
# Reads the tile grid's frame, giving Control Center time to be ready.
#
# Switching the system appearance takes Control Center apart and puts it back, and it comes back in
# stages: the menu bar item returns first, and a click on it opens nothing for a second or two after
# that. Waiting on the item is therefore not enough — the thing to wait for is a frame, so this asks
# for one until it gets one. Without it a `both` run photographs the light panel and then reports
# that Control Center never opened.
control_center_frame_when_ready() {
  local description="$1" frame attempt=0
  while [ "${attempt}" -lt "${CONTROL_CENTER_ATTEMPTS}" ]; do
    frame="$(control_center_tiles_frame "${description}" 2>/dev/null || true)"
    if [ -n "${frame}" ]; then
      echo "${frame}"
      return 0
    fi
    dismiss_menu
    attempt=$((attempt + 1))
    sleep 1
  done
  return 1
}

# The grid of round control tiles, which is the whole of what a Zephyr reader needs from Control
# Center — Zephyr's control sits in it, and everything above it belongs to somebody else.
#
# Framing the panel entire was the obvious thing and the wrong one. It carries the network you are
# joined to by name, who the Personal Hotspot belongs to, what is playing; a picture of it is a
# picture of the reader's machine as much as of Zephyr's control, and none of that can be published.
# The tiles are the part that generalises.
#
# They are found by size rather than by label, because Control Center vends none: every tile is an
# unnamed button or checkbox, and the grid is the only run of elements at exactly the tile size.
control_center_tiles_frame() {
  local description="$1"
  osa -e "tell application \"System Events\" to tell process \"ControlCenter\"
            click (first menu bar item of menu bar 1 whose description is \"${description}\")
            delay ${SETTLE_SECONDS}
            set measuredOne to false
            set {minX, minY, maxX, maxY} to {0, 0, 0, 0}
            repeat with oneControl in (UI elements of UI element 1 of window 1)
              set {controlWidth, controlHeight} to value of attribute \"AXSize\" of oneControl
              if controlWidth is ${CONTROL_TILE_SIZE} and controlHeight is ${CONTROL_TILE_SIZE} then
                set {controlX, controlY} to value of attribute \"AXPosition\" of oneControl
                if measuredOne then
                  if controlX < minX then set minX to controlX
                  if controlY < minY then set minY to controlY
                  if controlX + controlWidth > maxX then set maxX to controlX + controlWidth
                  if controlY + controlHeight > maxY then set maxY to controlY + controlHeight
                else
                  set {minX, minY} to {controlX, controlY}
                  set {maxX, maxY} to {controlX + controlWidth, controlY + controlHeight}
                  set measuredOne to true
                end if
              end if
            end repeat
            if not measuredOne then return {}
            -- Padded up and down only, and photographed as it stands.
            --
            -- The grid is exactly as wide as the panel's glass: the tiles are laid edge to edge
            -- across it, and window 1 is a full-height transparent host rather than the panel, so
            -- there is nothing to clamp against. A margin to the left or right is therefore not a
            -- margin at all — it is the backdrop beyond the glass, and it reads as a seam down the
            -- side of the picture. Above and below there is real panel to include.
            set p to ${CONTROL_TILE_PADDING}
            get {minX, minY - p, maxX - minX, (maxY - minY) + 2 * p}
          end tell" | tr -d ','
}

control_center_panel_frame() {
  local description="$1"
  osa -e "tell application \"System Events\" to tell process \"ControlCenter\"
            click (first menu bar item of menu bar 1 whose description is \"${description}\")
            delay ${SETTLE_SECONDS}
            set {windowWidth, windowHeight} to value of attribute \"AXSize\" of window 1
            set measuredOne to false
            set {minX, minY, maxX, maxY} to {0, 0, 0, 0}
            repeat with oneControl in (UI elements of UI element 1 of window 1)
              set {controlWidth, controlHeight} to value of attribute \"AXSize\" of oneControl
              if {controlWidth, controlHeight} is not {windowWidth, windowHeight} then
                set {controlX, controlY} to value of attribute \"AXPosition\" of oneControl
                if measuredOne then
                  if controlX < minX then set minX to controlX
                  if controlY < minY then set minY to controlY
                  if controlX + controlWidth > maxX then set maxX to controlX + controlWidth
                  if controlY + controlHeight > maxY then set maxY to controlY + controlHeight
                else
                  set {minX, minY} to {controlX, controlY}
                  set {maxX, maxY} to {controlX + controlWidth, controlY + controlHeight}
                  set measuredOne to true
                end if
              end if
            end repeat
            if not measuredOne then return {}
            get {minX, minY, maxX - minX, maxY - minY}
          end tell" | tr -d ','
}

# Refuses to photograph nothing. A frame that could not be read is four missing words, and passing
# those on is an unbound-variable death several lines later that names none of this.
require_frame() {
  local what="$1"
  shift
  [ "$#" -eq 4 ] || {
    echo "  error: could not read ${what}'s frame — it never opened, or it closed again." >&2
    return 1
  }
}

# Photographs a region into the work directory.
#
# Taking the picture and converting it are two steps on purpose. Everything here is photographed
# while something is being held open — a menu, a sheet, a panel that closes the moment focus
# shifts — and the conversion afterwards is several seconds of `sips` and `magick`. Keeping those
# out of the way lets the caller dismiss what it opened the instant the shutter has closed, which
# is the difference between a Finder that answers and a Finder wedged in a menu tracking loop.
#
# The region is grown by a margin so a menu's or a sheet's shadow is inside the picture rather than
# cut off at a hard edge. `screencapture` clamps it to the screen, so it only has to be generous.
snap_region() {
  local x="$1" y="$2" width="$3" height="$4"
  local margin="${5:-24}"
  screencapture -x -R"$((x - margin)),$((y - margin)),$((width + margin * 2)),$((height + margin * 2))" \
    "${WORK}/raw.png"
}

# The name a capture is filed under: the light one is the slug itself, and the dark one is that slug
# with a suffix — the pairing the site's <picture> sources and the help book's are written against.
slug_for_appearance() {
  if [ "$(current_dark_mode)" = "true" ]; then echo "$1-dark"; else echo "$1"; fi
}

# Converts the last snapshot out of the display's profile, strips the metadata that would otherwise
# make every run a diff, and writes it to both published directories under `slug`. The same
# treatment Scripts/export-screenshots.sh gives the generated set, so the two look like one set on
# a page.
publish_snap() {
  local slug
  slug="$(slug_for_appearance "$1")"
  sips --matchTo "${SRGB_PROFILE}" "${WORK}/raw.png" --out "${WORK}/srgb.png" >/dev/null
  magick "${WORK}/srgb.png" -strip "${WORK}/flat.png"
  cwebp -quiet -q 90 -m 6 -sharp_yuv -exact "${WORK}/flat.png" -o "${SITE_DIR}/${slug}.webp"
  cp "${SITE_DIR}/${slug}.webp" "${HELP_DIR}/${slug}.webp"
  CAPTURED_SLUGS+=("${slug}")
  echo "  ${SITE_DIR}/${slug}.webp"
  echo "  ${HELP_DIR}/${slug}.webp"
}

# ---------------------------------------------------------------------------- Finder

# Dismisses anything an earlier run left open on the Finder window.
#
# An open context menu blocks Finder's own event loop, so `tell application "Finder"` waits for a
# menu nobody is going to close — and talking to Finder is the first thing every subject below
# does. System Events still answers, which is how the window can be found at all; a click on its
# title bar then closes whatever is up without disturbing the selection, and Escape closes a sheet.
clear_finder_menus() {
  local frame x y width height
  frame="$(window_frame Finder "window 1" 2>/dev/null || true)"
  [ -n "${frame}" ] || return 0
  read -r x y width height <<<"${frame}"
  cliclick "c:$((x + width / 2)),$((y + 12))" >/dev/null
  sleep 1
  cliclick kp:esc >/dev/null
  sleep 1
}

# Opens the target file's folder in Finder, as a list, with the file selected.
#
# List view on purpose: an icon view vends unnamed AXGroups, so nothing can be found in it. Finder's
# own scripting selects the file, which is what AXShowMenu then needs — performing it on a row
# opens nothing at all.
# Shows the file the menu will be opened on, in a window of a known size.
#
# The size is the point. A context menu is translucent, so whatever lies behind it is faintly in the
# picture — and what lies behind it is only the Finder window if the Finder window is big enough to
# be there. Left at whatever size it happened to have, it can end part-way under the menu, and then
# the desktop behind Finder shows through the rest.
reveal_target_file() {
  osa -e "tell application \"Finder\"
            activate
            reveal (POSIX file \"${TARGET_FILE}\" as alias)
            set current view of front Finder window to list view
            set bounds of front Finder window to {${FINDER_WINDOW_BOUNDS}}
          end tell" >/dev/null
  sleep "${SETTLE_SECONDS}"
}

# Opens the selected file's context menu, without waiting for it.
#
# An open menu runs a tracking loop that answers no accessibility queries, so the script that opened
# it does not return until the menu closes — and neither would this function, which is why it is
# left in the background and reaped by ``dismiss_menu``. It is also why nothing here asks where the
# menu is: the caller reads the Finder window's frame first, while there is still something willing
# to answer, and photographs the menu inside a generous margin around it.
show_context_menu() {
  osa -e 'tell application "System Events" to tell process "Finder" to perform action "AXShowMenu" of (value of attribute "AXFocusedUIElement")' \
    >/dev/null 2>&1 &
  MENU_SCRIPT_PID=$!
  sleep "${SETTLE_SECONDS}"
}

# Closes whatever is open and lets the script that opened it finish.
#
# Escape through `cliclick` rather than System Events, which is the thing that cannot be reached
# while a menu is up.
dismiss_menu() {
  cliclick kp:esc >/dev/null
  sleep 1
  [ -z "${MENU_SCRIPT_PID}" ] || {
    wait "${MENU_SCRIPT_PID}" 2>/dev/null || true
    MENU_SCRIPT_PID=""
  }
}

# Closes the version-history sheet, which cannot be escaped like a menu: it is a ViewBridge remote
# view, so the sheet's own Cancel button is in no accessibility tree and there is nothing to click
# by name. Escape reaches it as a key event even so, and the background script that opened the menu
# it came from is reaped the same way.
dismiss_sheet() {
  dismiss_menu
  cliclick kp:esc >/dev/null
  sleep 1
}

# Where to crop the context menu that is currently open. See the source: it reaches the menu through
# the accessibility API, which is the only thing that can see one, and stops the crop where Zephyr's
# actions end so that other apps' Quick Actions stay out of the picture.
menu_frame() {
  [ -x "${MENU_FRAME_BINARY}" ] || swiftc -O -o "${MENU_FRAME_BINARY}" "${MENU_FRAME_SOURCE}" || return 1
  "${MENU_FRAME_BINARY}"
}

capture_finder_menu() {
  require_target_file
  clear_finder_menus
  hide_other_apps
  reveal_target_file
  show_context_menu
  local frame
  frame="$(menu_frame || true)"
  # shellcheck disable=SC2086  # the frame is four words and is meant to split into four arguments.
  require_frame "the context menu" ${frame} || { dismiss_menu; return 0; }
  # No margin: `menu_frame` has already put one on the three sides that can take one, and the
  # bottom edge is a cut rather than a border — a margin there reaches the next app's Quick Action.
  # shellcheck disable=SC2086  # as above.
  snap_region ${frame} 0
  dismiss_menu
  publish_snap finder-menu
}

# Asks for the operator's attention without putting anything on screen.
#
# The one cue this run has to give arrives at the worst possible moment: the context menu is open,
# the shutter is seconds away, and anything drawn to ask for the click — an alert, a notification, a
# terminal brought forward — is in the photograph. A sound reaches whatever the operator is doing
# and leaves the screen exactly as the capture needs it.
sound_cue() {
  afplay "${ATTENTION_SOUND}" >/dev/null 2>&1 || true
}

# Photographs the version-history sheet where it really appears.
#
# The sheet is invisible to accessibility — it is a ViewBridge remote view, so Finder reports an
# empty AXSheet and the extension's own process reports no windows at all — so the Finder window
# holding it is the frame. That frame is read before the menu opens rather than after: an open menu
# answers no accessibility query, so a script that asks once one is up waits for a menu nobody is
# going to close.
#
# Choosing the menu item is yours, and it is the one step here that is. Everything a script can do
# to a menu was tried:
#
#   * `AXShowMenu` opens it, but the call does not return until the menu closes, and it is System
#     Events making that call — so System Events, which is the only thing that can send a real key
#     code or click a menu item by name, is blocked for as long as the menu is up.
#   * `cliclick` is not blocked, and its named keys reach the menu: Escape closes it and the arrows
#     move the highlight. Its typing does not, because it types unicode rather than key codes and a
#     menu's type-select reads key codes.
#   * Counting arrow presses down to the item would work on one Mac and be a loaded gun on any
#     other: what a Finder context menu holds depends on what else is installed, and three rows
#     above Show Previous Versions on this Mac is Move to Trash.
#   * A synthetic right-click does not open a Finder context menu at all, and Finder reports no
#     position for an item inside a File Provider domain, so there is nowhere to aim one anyway.
#
# So the menu is opened, you click the item, and the sheet is photographed, dismissed, and
# published without you.
capture_finder_versions() {
  require_target_file
  clear_finder_menus
  hide_other_apps
  reveal_target_file
  local frame
  frame="$(window_frame Finder "window 1" || true)"
  # shellcheck disable=SC2086  # the frame is four words and is meant to split into four arguments.
  require_frame "the Finder window" ${frame} || return 0
  show_context_menu
  sound_cue
  echo "  Click 'Show Previous Versions...' in the menu now — the one step nothing can do for you."
  echo "  Waiting ${CHOICE_SECONDS}s, then ${SHEET_SECONDS}s more for the sheet."
  echo "  No such item means the action is missing from this file's menu: a folder, an item you"
  echo "  have stopped syncing, or a file whose metadata predates the action being added."
  sleep "${CHOICE_SECONDS}"
  sleep "${SHEET_SECONDS}"
  # shellcheck disable=SC2086  # as above.
  snap_region ${frame}
  dismiss_sheet
  publish_snap finder-versions
}

# ---------------------------------------------------------------------------- macOS surfaces

# Hides every app but the Finder, so what is photographed sits on the desktop, or on the Finder
# window, rather than on whatever the operator had open. They stay hidden afterwards: un-hiding is a
# guess at what was open, and a wrong guess is worse than a Dock full of hidden apps.
# Hides every app except the one named, or every app at all when nothing is named.
#
# Which one is kept matters more than it looks. The Finder subjects need Finder's window on screen —
# it is what the menu is opened over. The others need it gone: Control Center's panel is translucent
# and wide enough to straddle the Finder window's right edge, so it refracts the window down one side
# and the backdrop down the other, and a hard vertical seam runs through the picture between them.
hide_apps_except() {
  local kept="${1:-}"
  local condition="visible is true"
  [ -z "${kept}" ] || condition="${condition} and name is not \"${kept}\""
  osa -e "tell application \"System Events\" to set visible of (every process whose ${condition}) to false" \
    >/dev/null
  sleep "${SETTLE_SECONDS}"
}

hide_other_apps() { hide_apps_except Finder; }

# The widget on the desktop, drawn by WidgetKit rather than by anything of Zephyr's.
#
# A desktop widget is a window of the NotificationCenter process, named for the widget it holds, so
# this is the one macOS surface here that can be addressed rather than guessed at. Notification
# Center's own panel cannot: a scripted click on the clock opens nothing a script can then find.
#
# This is also the check on the tile the screenshot lane draws. `WidgetTile` in the design gallery
# stands in for WidgetKit's geometry from the platform's published family sizes; what it should look
# like is whatever comes out of here.
#
# Every other app is hidden first, because a widget sits on the desktop and everything else sits on
# top of it. They stay hidden when this finishes — un-hiding them would be a second guess at what
# was open.
capture_desktop_widget() {
  hide_other_apps
  local frame
  frame="$(window_frame NotificationCenter "(first window whose name is \"${WIDGET_NAME}\")" || true)"
  # shellcheck disable=SC2086  # the frame is four words and is meant to split into four arguments.
  require_frame "the ${WIDGET_NAME} widget" ${frame} || {
    echo "  Add Zephyr's widget to the desktop first, or name another with --widget-name." >&2
    return 0
  }
  # shellcheck disable=SC2086  # as above.
  snap_region ${frame}
  publish_snap desktop-widget
}

# Control Center, with Zephyr's pause control among the rest.
#
# Opened and photographed in one go because it closes the moment focus shifts. Its children vend no
# labels either — every one is a "toggle button" — so this photographs the panel and leaves finding
# Zephyr's row to the reader, which is what a help page wants anyway.
capture_control_center_pause() {
  # Everything hidden, Finder included: the panel is translucent and wider than the gap between the
  # Finder window's edge and the screen's, so a window left open behind it shows up as a seam rather
  # than as a background.
  hide_apps_except
  local frame
  frame="$(control_center_frame_when_ready "Control Center" || true)"
  # shellcheck disable=SC2086  # the frame is four words and is meant to split into four arguments.
  require_frame "Control Center" ${frame} || return 0
  # No margin: the grid's own padding is above and below, which are the only sides that have panel
  # to spare.
  # shellcheck disable=SC2086  # as above.
  snap_region ${frame} 0
  dismiss_menu
  publish_snap control-center-pause
}

# The File Providers sheet, which is where macOS makes people turn a domain on before Finder will
# show it. Opened by the same URL the app's own setup sends people to.
capture_system_settings_file_providers() {
  open "${FILE_PROVIDERS_URL}"
  sleep 4
  # The sheet rather than the window behind it. That window is a settings app in the middle of
  # somebody's own machine: their name and picture at the top of the sidebar, how long their
  # AppleCare has left, and a login-items list naming every vendor whose software starts at login.
  # None of that is about turning a File Provider on, and none of it can be published.
  local frame
  frame="$(window_frame "System Settings" "sheet 1 of window 1" || true)"
  # shellcheck disable=SC2086  # the frame is four words and is meant to split into four arguments.
  require_frame "the File Providers sheet" ${frame} || return 0
  # No margin. The default one is a courtesy to the subject's shadow, and here it is a window's
  # width of somebody's account name showing down the side of the picture.
  # shellcheck disable=SC2086  # as above.
  snap_region ${frame} 0
  osa -e 'tell application "System Settings" to quit' >/dev/null || true
  publish_snap system-settings-file-providers
}

# ---------------------------------------------------------------------------- driving

# How high the backdrop has to go for a subject.
#
# Almost everything here is photographed over an ordinary window — a Finder window, the System
# Settings window — and those have to stay above the backdrop or the picture is of the backdrop.
# Control Center is the exception: its panel is drawn at status level, above every window, and it is
# translucent and wide enough to reach across whatever is behind it. Only there does the backdrop
# have to go above the windows too, and only there is that safe.
backdrop_height_for() {
  case "$1" in
    control-center-pause) echo windows ;;
    *) echo desktop ;;
  esac
}

capture_subject() {
  raise_backdrop "${APPEARANCE_NOW}" "$(backdrop_height_for "$1")"
  case "$1" in
    finder-menu) capture_finder_menu ;;
    finder-versions) capture_finder_versions ;;
    desktop-widget) capture_desktop_widget ;;
    control-center-pause) capture_control_center_pause ;;
    system-settings-file-providers) capture_system_settings_file_providers ;;
    *) echo "error: unknown subject '$1'" >&2; usage ;;
  esac
  drop_backdrop
}

capture_all() {
  local subject
  for subject in "$@"; do
    echo "${subject}:"
    capture_subject "${subject}"
  done
}

# Says on screen that the run is over.
#
# Everything else this prints goes to a terminal that spends the run buried under the surfaces being
# ---------------------------------------------------------------------------- backdrop

# Puts a chosen background behind the subject, and takes it away again.
#
# Every subject here is drawn in Liquid Glass, which samples what is behind it. Photograph a Control
# Center panel over a desktop and the desktop is in the picture twice: around the panel, and tinted
# through it — a blue wallpaper makes a blue panel, and no crop reaches that. Hiding the other apps
# deals with the windows and leaves the wallpaper, which is the half that actually colours the glass.
#
# So a plain gradient goes up first, above the desktop and its icons and below every ordinary
# window. The subject still floats over something and still refracts it; what it refracts is the
# same neutral grey on every machine and every run.
raise_backdrop() {
  local appearance="$1" height="${2:-desktop}"
  [ -x "${BACKDROP_BINARY}" ] || swiftc -O -o "${BACKDROP_BINARY}" "${BACKDROP_SOURCE}" || {
    echo "warning: could not build the backdrop; captures will show the desktop behind them" >&2
    return 0
  }
  # Spelled out rather than built as an array: /bin/bash here is 3.2, where expanding an empty one
  # under `set -u` is an error rather than nothing.
  local appearanceFlag="" heightFlag=""
  if [ "${appearance}" = dark ]; then appearanceFlag="--dark"; fi
  if [ "${height}" = windows ]; then heightFlag="--above-windows"; fi
  # shellcheck disable=SC2086  # each is one flag or the empty string, and must vanish when empty.
  "${BACKDROP_BINARY}" ${appearanceFlag} ${heightFlag} >/dev/null 2>&1 &
  BACKDROP_PID="$!"
  sleep 1
}

drop_backdrop() {
  [ -n "${BACKDROP_PID}" ] || return 0
  kill "${BACKDROP_PID}" 2>/dev/null || true
  wait "${BACKDROP_PID}" 2>/dev/null || true
  BACKDROP_PID=""
}

# Takes down the finish alert a previous run left up.
#
# It withdraws on its own, but on a timer measured against somebody walking back to their desk, not
# against the next run — and it opens centred, which is where a context menu opens too. Left alone
# it photographs itself: the alert saying to check the picture, in the picture.
clear_previous_alert() {
  pkill -f "display alert \"${FINISH_ALERT_TITLE}" 2>/dev/null || true
}

# One appearance's worth of captures, over a backdrop matching it.
capture_pass() {
  local appearance="$1"; shift
  if [ "${appearance}" = dark ]; then set_dark_mode true; else set_dark_mode false; fi
  APPEARANCE_NOW="${appearance}"
  capture_all "$@"
}

# photographed, so watching for the end of it means bringing that terminal forward — which is how a
# terminal window ends up across a Finder capture. An alert arrives without being watched for, and
# it is safe on screen because the last shutter has already closed.
#
# It hangs off the EXIT trap, so a run that dies on its third subject says so too rather than
# leaving someone waiting on a script that is no longer running. That is also why it names what
# reached the published directories rather than what was asked for: on a run that ends early, those
# are different lists.
announce_finish() {
  local captured="nothing"
  [ "${#CAPTURED_SLUGS[@]}" -eq 0 ] || captured="${CAPTURED_SLUGS[*]}"
  # Detached, and set to withdraw on its own. An alert waits for a click, and the wait outlives the
  # script: leave it in the foreground and the next run blocks on `osascript` before its first line
  # of output, behind a dialog nobody is looking at. Two runs in a row and there are two.
  osa -e "display alert \"${FINISH_ALERT_TITLE}\" \
          message \"Captured: ${captured}\" & return & return & \
          \"Look at every image before committing it: whatever was on screen is in it.\" \
          giving up after ${FINISH_ALERT_SECONDS}" \
    >/dev/null 2>&1 &
  disown 2>/dev/null || true
}

main() {
  local requested=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --appearance) APPEARANCE_MODE="${2:-}"; shift 2 ;;
      --file) TARGET_FILE="${2:-}"; shift 2 ;;
      --widget-name) WIDGET_NAME="${2:-}"; shift 2 ;;
      -h|--help) usage ;;
      -*) echo "error: unknown option '$1'" >&2; usage ;;
      *) requested+=("$1"); shift ;;
    esac
  done
  [ "${#requested[@]}" -gt 0 ] || requested=("${SUBJECTS[@]}")

  require_tools
  require_installed_app
  mkdir -p "${SITE_DIR}" "${HELP_DIR}"
  WORK="$(mktemp -d)"
  BACKDROP_BINARY="${WORK}/backdrop"
  MENU_FRAME_BINARY="${WORK}/finder-menu-frame"
  # shellcheck disable=SC2064  # WORK is expanded now on purpose: the trap must name this directory.
  trap "drop_backdrop; announce_finish; rm -rf '${WORK}'" EXIT

  ORIGINAL_DARK_MODE="$(current_dark_mode)"
  # shellcheck disable=SC2064  # as above; every one of these has to run however the script ends.
  trap "drop_backdrop; restore_appearance; announce_finish; rm -rf '${WORK}'" EXIT

  clear_previous_alert
  echo "Driving the screen — do not touch the mouse or keyboard unless asked to."
  case "${APPEARANCE_MODE}" in
    light) capture_pass light "${requested[@]}" ;;
    dark) capture_pass dark "${requested[@]}" ;;
    both)
      capture_pass light "${requested[@]}"
      capture_pass dark "${requested[@]}"
      ;;
    *) echo "error: --appearance takes light, dark, or both" >&2; usage ;;
  esac
  echo "Look at every image before committing it: whatever was on screen is in it."
}

main "$@"
