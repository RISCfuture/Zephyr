#!/bin/bash
#
# Packages the notarized build into a disk image for the GitHub release.
#
#   Scripts/make-dmg.sh <path/to/Zephyr.app> <version> <output-directory>
#
# Produces "<output-directory>/Zephyr-<version>.dmg" and prints its path. The image holds the
# app and a symlink to /Applications, which is the whole of the expected drag-to-install gesture;
# no background art or window geometry, both of which would need a scripted Finder session.
#
# This script only packages. The caller signs, notarizes, and staples the image afterwards — a
# downloaded image is quarantined and judged by Gatekeeper on its own merits, so notarizing the app
# inside it is not enough.

set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: $(basename "$0") <app-path> <version> <output-directory>" >&2
  exit 2
fi

APP="$1"
VERSION="$2"
OUT_DIR="$3"

[ -d "${APP}" ] || { echo "error: no app bundle at ${APP}" >&2; exit 1; }

mkdir -p "${OUT_DIR}"
DMG="${OUT_DIR}/Zephyr-${VERSION}.dmg"
rm -f "${DMG}"

# hdiutil refuses to overwrite, and a stale staging directory would ship whatever it holds.
STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT

cp -R "${APP}" "${STAGE}/"
ln -s /Applications "${STAGE}/Applications"

hdiutil create \
  -volname "Zephyr ${VERSION}" \
  -srcfolder "${STAGE}" \
  -ov \
  -format UDZO \
  "${DMG}" >/dev/null

echo "${DMG}"
