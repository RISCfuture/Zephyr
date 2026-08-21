#!/bin/bash
#
# Packages the notarized build into the installer package the GitHub release ships.
#
#   Scripts/make-pkg.sh <path/to/Zephyr.app> <version> <output-directory>
#
# Produces "<output-directory>/Zephyr-<version>.pkg" and prints its path.
#
# The package exists because a disk image cannot deliver a working copy of this particular app. The
# Finder stamps com.apple.quarantine onto anything dragged out of a mounted image; macOS then runs a
# quarantined app from a read-only App Translocation mount rather than from where it was put; and it
# refuses to run a File Provider extension for a translocated process at all. A dragged Zephyr can
# therefore never put a Dropbox in Finder, however long it is left to try. An installer writes the
# bundle directly and the flag is never applied.
#
# Two components, because one of them is optional. The app is the package's reason to exist and
# cannot be deselected; the `zephyr` command-line tool is a convenience that belongs on nobody's
# PATH uninvited, so it is a payload-free component carrying only the script that links it, and one
# checkbox turns it off.
#
# This script only packages. The caller signs the result with a Developer ID Installer identity,
# notarizes it, and staples the ticket — a downloaded package is judged by Gatekeeper before the
# Installer will open it, and the app inside being notarized is a separate gate from the package
# being notarized.

set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: $(basename "$0") <app-path> <version> <output-directory>" >&2
  exit 2
fi

APP="$1"
VERSION="$2"
OUT_DIR="$3"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# What each receipt is filed under, and what an upgrade matches itself against. Deliberately not the
# app's own identifier: a receipt is not the app.
APP_COMPONENT_IDENTIFIER="codes.tim.Zephyr.installer"
CLI_COMPONENT_IDENTIFIER="codes.tim.Zephyr.installer.cli"

# Refuse anything older than the app itself will run on, rather than installing onto a Mac that
# cannot launch what was installed.
MINIMUM_OS_VERSION="26.0"

[ -d "${APP}" ] || { echo "error: no app bundle at ${APP}" >&2; exit 1; }

mkdir -p "${OUT_DIR}"
PKG="${OUT_DIR}/Zephyr-${VERSION}.pkg"
rm -f "${PKG}"

STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT

# The payload is the app alone, installed into /Applications. Copied rather than referenced so that
# a stray extended attribute on the source tree cannot end up in the receipt.
mkdir -p "${STAGE}/root"
cp -R "${APP}" "${STAGE}/root/"

pkgbuild \
  --root "${STAGE}/root" \
  --scripts "${SCRIPT_DIR}/pkg/app" \
  --install-location /Applications \
  --identifier "${APP_COMPONENT_IDENTIFIER}" \
  --version "${VERSION}" \
  "${STAGE}/app.pkg" >/dev/null

# No payload: the link this component makes is not a file the installer can lay down, because it
# points into a bundle the other component has only just written.
pkgbuild \
  --nopayload \
  --scripts "${SCRIPT_DIR}/pkg/cli" \
  --identifier "${CLI_COMPONENT_IDENTIFIER}" \
  --version "${VERSION}" \
  "${STAGE}/cli.pkg" >/dev/null

# `customize="allow"` keeps the default path to two clicks and a password while still offering the
# one choice there is to make. The app choice is `enabled="false"`: it is shown, so the customize
# pane accounts for everything being installed, but it cannot be turned off.
#
# `rootVolumeOnly` confines the install to the boot volume, because a copy anywhere else would leave
# the CLI component's link into /usr/local/bin pointing at a path other accounts cannot read. A
# `<domains>` element is the spelling Apple documents in its place, and this is deliberately not
# that: any `<domains>` at all makes the Installer present a Destination Select pane, and there is
# only ever one destination to select. Without it the defaults apply, which already refuse a home
# directory.
#
# The deprecated attribute is load-bearing, so if a macOS ever stops honouring it the restriction
# falls back to allowing anywhere. What still stands in that case is the volume check below: a
# volume without a new enough macOS on it is filtered out of the destination list regardless.
cat > "${STAGE}/distribution.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>Zephyr ${VERSION}</title>
    <options customize="allow" require-scripts="true" rootVolumeOnly="true"/>
    <volume-check>
        <allowed-os-versions>
            <os-version min="${MINIMUM_OS_VERSION}"/>
        </allowed-os-versions>
    </volume-check>
    <choices-outline>
        <line choice="app"/>
        <line choice="cli"/>
    </choices-outline>
    <choice id="app"
            title="Zephyr"
            description="The Zephyr app, installed in your Applications folder."
            enabled="false"
            selected="true">
        <pkg-ref id="${APP_COMPONENT_IDENTIFIER}"/>
    </choice>
    <choice id="cli"
            title="Command-Line Tool"
            description="Links the zephyr command into /usr/local/bin, for working with your Dropbox from Terminal. You can install it later from Zephyr's settings instead."
            selected="true">
        <pkg-ref id="${CLI_COMPONENT_IDENTIFIER}"/>
    </choice>
    <pkg-ref id="${APP_COMPONENT_IDENTIFIER}" version="${VERSION}">app.pkg</pkg-ref>
    <pkg-ref id="${CLI_COMPONENT_IDENTIFIER}" version="${VERSION}">cli.pkg</pkg-ref>
</installer-gui-script>
EOF

productbuild \
  --distribution "${STAGE}/distribution.xml" \
  --package-path "${STAGE}" \
  "${PKG}" >/dev/null

echo "${PKG}"
