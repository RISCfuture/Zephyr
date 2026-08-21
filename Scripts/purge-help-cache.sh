#!/bin/bash
#
# Drops the Help book copies macOS serves, so the next open reads the book that was last built.
#
#   Scripts/purge-help-cache.sh [cache-name-prefix]
#
# helpd does not read the book out of the app bundle. It copies it into its own group container the
# first time it sees the book and serves that copy ever after, under a name keyed on the *app's*
# CFBundleShortVersionString:
#
#   codes.tim.Zephyr.codes.tim.Zephyr.help*1.0.help
#
# The book's own version is not in that key, and neither is anything derived from the content. So
# while the marketing version stays put -- which is every build between releases -- each rebuild is
# ignored and the copy taken the first time is what the reader gets. An edit that never shows up, a
# page stuck without its images, a Help menu landing on the generic macOS Tips page: all the same
# cause, and all fixed by dropping the copy so helpd has to take a fresh one.
#
# `hiutil -P` clears helpd's own caches and registrations but leaves that copy behind, so both halves
# are needed. Nothing here is precious: everything removed is rebuilt from the app bundle on demand.

set -euo pipefail

# Names the entries this script drops by hand. Both caches name their entries for the app rather than
# the book, so one prefix reaches everything Zephyr registered.
PREFIX="${1:-codes.tim.Zephyr}"
SERVED="${HOME}/Library/Group Containers/group.com.apple.helpviewer.content/Library/Caches"
REGISTERED="${HOME}/Library/Caches/com.apple.helpd/Generated"

removed=0

drop() {
  for entry in "$1/${PREFIX}"*; do
    [ -e "${entry}" ] || continue
    rm -rf "${entry}"
    echo "removed $(basename "${entry}")"
    removed=$((removed + 1))
  done
}

# Tips.app is the Help Viewer on current macOS. It holds the book open, so it goes first.
osascript -e 'tell application "Tips" to quit' >/dev/null 2>&1 || true

# The system's own purge, and system-wide: it clears every app's registrations, not just this
# project's. That is the documented way to do this and the entries it takes are re-taken on demand,
# so the cost is a slow first open of somebody else's help book. It works by asking a *running* helpd
# to shut down, though, and when there is none it fails and clears nothing at all -- so the drops
# below are what make the purge land either way, and they reach the one thing it never touches.
hiutil -P >/dev/null 2>&1 || true

drop "${SERVED}"
drop "${REGISTERED}"

if [ "${removed}" -eq 0 ]; then
  echo "nothing cached matched ${PREFIX}*"
fi

# Which of the two matters depends on where the app being read is. helpd watches /Applications, so a
# book there is registered on its own within a minute of the first request -- the request that
# triggers it is answered "The selected content is currently unavailable", and everything after it
# resolves. A build run from DerivedData sits outside every watched folder and is never registered
# that way, so there the root open is what registers it and no amount of waiting substitutes.
cat <<'NEXT'

Open the book at its root before clicking any help button:

  open "help:openbook=codes.tim.Zephyr.help"

Until helpd has registered the book, an anchor resolves to "The selected content is
currently unavailable" -- a help button clicked first looks broken and isn't.
NEXT
