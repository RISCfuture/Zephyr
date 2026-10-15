#!/bin/bash
#
# Publishes the screenshot VM's Finder capture as the still the App Store listing leads with.
#
#   Scripts/screenshot-vm/publish-finder-window.sh
#
# Takes ~/VMs/zephyr-share/finder-window.png, written by capture-finder.sh in the guest, and gives
# it the treatment every other capture gets — out of the display's colour space, metadata stripped
# so a re-run is not a diff — before writing docs/assets/system/finder-window.webp, which
# promo/storyboard.json names.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly REPO_ROOT
readonly CAPTURE="${HOME}/VMs/zephyr-share/finder-window.png"
readonly STILL="${REPO_ROOT}/docs/assets/system/finder-window.webp"
readonly SRGB_PROFILE="/System/Library/ColorSync/Profiles/sRGB Profile.icc"

[ -f "${CAPTURE}" ] || { echo "error: no capture at ${CAPTURE}" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
sips --matchTo "${SRGB_PROFILE}" "${CAPTURE}" --out "${WORK}/srgb.png" >/dev/null
magick "${WORK}/srgb.png" -strip "${WORK}/flat.png"
cwebp -quiet -q 90 -m 6 -sharp_yuv -exact "${WORK}/flat.png" -o "${STILL}"
echo "${STILL}"
