#!/bin/bash
#
# Boots the screenshot VM, a macOS guest with Zephyr installed and the App Store demo account
# linked, for photographing surfaces macOS draws around Zephyr.
#
#   Scripts/screenshot-vm/run.sh
#
# Finder, its sidebar, and its context menus show whatever the machine they run on holds: the
# owner's name and home folder, every other cloud provider installed, the accounts they have
# linked. A guest built for the purpose holds none of that, so what it shows is publishable as it
# stands, and photographing it takes over nobody's screen.
#
# The guest sees two folders under /Volumes/My Shared Files:
#
#   * tools — this directory, read-only, so the guest always runs the committed scripts;
#   * out   — ~/VMs/zephyr-share, where those scripts write their captures and logs.
#
# The guest is `zephyr-screens`, run by tart (https://tart.run), which must be installed. Its one
# user is `zephyr` with the password `zephyr`, a throwaway that unlocks nothing beyond the guest.
# The host cannot reach the guest's network, so it is driven through its window: log in, open
# Terminal, and run a script from `tools`, e.g.
#
#   "/Volumes/My Shared Files/tools/capture-finder.sh" ~/Library/CloudStorage/Zephyr-*/Photos \
#       icon finder-window 112 500 1120

set -euo pipefail

readonly VM_NAME="zephyr-screens"
TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TOOLS_DIR
readonly OUT_DIR="${HOME}/VMs/zephyr-share"

tart_binary() {
  command -v tart 2>/dev/null && return 0
  local bundled="${HOME}/Applications/tart.app/Contents/MacOS/tart"
  [ -x "${bundled}" ] && { echo "${bundled}"; return 0; }
  echo "error: tart is not installed (https://github.com/cirruslabs/tart/releases)" >&2
  return 1
}

main() {
  local tart
  tart="$(tart_binary)"
  "${tart}" get "${VM_NAME}" >/dev/null 2>&1 || {
    echo "error: no VM named ${VM_NAME}; see the comment at the top of this script" >&2
    exit 1
  }
  mkdir -p "${OUT_DIR}"
  exec "${tart}" run --dir="tools:${TOOLS_DIR}:ro" --dir="out:${OUT_DIR}" "${VM_NAME}"
}

main "$@"
