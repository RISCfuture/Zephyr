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
- Finder's search field now searches your whole Dropbox, not just what is on
  this Mac. Results include files you have never downloaded, and finding them
  costs no network — the search runs against Zephyr's own index.

### Upgrading

- This release re-registers each account's Finder location, which is the only
  way to turn search on for a location that already exists. Files currently on
  this Mac download again as you open them. Nothing is lost, and nothing needs
  doing — but a large Dropbox will be busy for a while afterwards.

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
