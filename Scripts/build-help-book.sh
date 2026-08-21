#!/bin/bash
#
# Stages the Apple Help book into the app bundle being built and indexes it for search.
#
#   Scripts/build-help-book.sh <source.help> <resources-directory> <work-directory> \
#                              <anchor-source.swift>
#
# Run from the "Build Help Book" phase of each app target. The source book lives outside every
# synchronized group on purpose: Xcode has no file type for the ".help" extension, so a synchronized
# group descends into the bundle and treats each page as a loose resource, colliding the book's own
# Info.plist with the target's. Copying it here is what keeps the wrapper intact.
#
# Both editions ship under one bundle identifier, so one book identifier serves both and is checked
# in rather than stamped. (An app whose editions differ there has to stamp the copy instead: helpd
# keys its registry on the book's CFBundleIdentifier, and one identifier across two identifiers'
# worth of apps lets whichever registered last answer for the other.)
#
# helpd will index an unindexed local book on its own, but on its own schedule and into a cache it
# holds onto. Shipping the index makes search work on first launch and makes what ships a function
# of what is checked in.

set -euo pipefail

if [ "$#" -ne 4 ]; then
  echo "usage: $(basename "$0") <source-help-bundle> <resources-directory> <work-directory>" \
       "<anchor-source>" >&2
  exit 2
fi

SOURCE="$1"
RESOURCES="$2"
WORK_DIR="$3"
ANCHOR_SOURCE="$4"
STOPWORDS=/usr/share/hiutil/Stopwords.plist

# An index build assembles no resources directory, and a header or API install produces no bundle at
# all; in neither is there anything to stage into.
case "${ACTION:-build}" in
  indexbuild | installhdrs | installapi) exit 0 ;;
esac

[ -d "${SOURCE}" ] || { echo "error: no help book at ${SOURCE}" >&2; exit 1; }
[ -f "${ANCHOR_SOURCE}" ] || { echo "error: no anchor source at ${ANCHOR_SOURCE}" >&2; exit 1; }

DESTINATION="${RESOURCES}/$(basename "${SOURCE}")"

# The phase is always out of date -- no list of input paths can express "every file under this
# tree", and the failure mode of getting that wrong is a silently stale help book -- so the
# up-to-date check lives here. Hashing costs milliseconds and, unlike comparing timestamps, survives
# a fresh clone, where every file carries its checkout time.
fingerprint() {
  {
    find "${SOURCE}" -type f ! -name .DS_Store -exec shasum -a 256 {} +
    shasum -a 256 "${ANCHOR_SOURCE}"
  } | sort | shasum -a 256 | cut -d ' ' -f 1
}

STAMP="${WORK_DIR}/help-book.fingerprint"
CURRENT="$(fingerprint)"

# The destination is checked as well as the stamp. Both app targets stage this one book into a
# product of the same name, and the stamp lives in a directory of the target's own -- so a products
# directory cleaned out from under a surviving stamp would otherwise report "up to date" over
# nothing at all, and an app declaring a CFBundleHelpBookName no book inside it carries has no help
# whatsoever: not a stale page, not a missing anchor, a Help menu that opens nothing.
if [ "$(cat "${STAMP}" 2>/dev/null)" = "${CURRENT}" ] && [ -d "${DESTINATION}" ]; then
  exit 0
fi

# Every anchor the app asks for has to exist in the book it is about to ship. A misspelled anchor
# does not fail at runtime -- Help Viewer quietly opens the book's first page instead of the topic --
# so this is the only place the mistake is catchable. Checked in one direction only: the book carries
# far more anchors than the interface links to, and flagging the rest would be noise.
missing=""
while read -r anchor; do
  [ -n "${anchor}" ] || continue
  grep -qR "a name=\"${anchor}\"" "${SOURCE}" || missing="${missing} ${anchor}"
done <<EOF
$(sed -n 's/.*= "\([a-z0-9-]*\)".*/\1/p' "${ANCHOR_SOURCE}")
EOF

if [ -n "${missing}" ]; then
  echo "error: HelpAnchor names anchors the help book doesn't define:${missing}" >&2
  exit 1
fi

# Rebuilt rather than synced, so a page deleted upstream cannot survive in the bundle. Resource
# forks, extended attributes, and quarantine flags all go: this tree is about to be sealed by
# codesign, which treats them as detritus and refuses to sign around them.
rm -rf "${DESTINATION}"
mkdir -p "${RESOURCES}"
ditto --norsrc --noextattr --noqtn "${SOURCE}" "${DESTINATION}"
find "${DESTINATION}" -name .DS_Store -delete

# Resolved relative to each localization directory, so every language carries its own index under
# the same name.
INDEX_NAME="$(plutil -extract HPDBookCSIndexPath raw -o - "${DESTINATION}/Contents/Info.plist")"

for lproj in "${DESTINATION}"/Contents/Resources/*.lproj; do
  [ -d "${lproj}" ] || continue

  language="$(basename "${lproj}" .lproj)"
  base="${language%%[-_]*}"

  # --anchors builds the anchor dictionary, without which HelpLink(anchor:) has nothing to open; it
  # is off by default. hiutil ships stopword lists for only seven languages, so they are passed only
  # when there is one to pass.
  options=(--create --anchors --min-term-length 3 --locale "${language}")
  if plutil -extract "${base}" raw -o - "${STOPWORDS}" >/dev/null 2>&1; then
    options+=(--stopwords "${base}")
  fi

  hiutil "${options[@]}" --index-format corespotlight --file "${lproj}/${INDEX_NAME}" "${lproj}"
done

mkdir -p "${WORK_DIR}"
printf '%s\n' "${CURRENT}" > "${STAMP}"
