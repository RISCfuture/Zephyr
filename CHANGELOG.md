# Changelog

Release notes for Zephyr. The version headings are what
`Scripts/release-notes.sh` reads, and what the Release workflow attaches to a
GitHub release — so a heading is `## <version>`, matching the tag exactly.

## 2.0

### Requirements

- Zephyr now requires macOS 27. On macOS 26 the last version you can run is
  1.1, and it keeps working — but it will not see further updates.

## 1.1

### New

- Keep a folder or a file downloaded on this Mac. A kept item is fetched right
  away, stays current as it changes on Dropbox, and is never evicted to reclaim
  disk space. Right-click an item in Finder and choose Keep Downloaded on This
  Mac; Stop Keeping Downloaded on This Mac hands the space back. Zephyr's
  Settings lists everything you are keeping downloaded.

### Changed

- Zephyr's website has moved to zephyrmac.app.

### Fixed

- A Dropbox outage no longer reads as a broken account: a token request Dropbox
  answers with a server error or a rate limit is retried, and one that keeps
  failing reports a connection problem instead of asking you to relink.
- Renaming or moving many files at once no longer stalls. Zephyr sends Dropbox
  one change at a time instead of racing them into its rate limit, and a rename
  Dropbox has already made no longer shows up as a sync issue.

## 1.0

- First release.
