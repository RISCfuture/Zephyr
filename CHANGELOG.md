# Changelog

Release notes for Zephyr. The version headings are what
`Scripts/release-notes.sh` reads, and what the Release workflow attaches to a
GitHub release — so a heading is `## <version>`, matching the tag exactly.

## 2.0.1

### Fixed

- Keeping a very large folder downloaded, ignoring it, or deleting it on
  Dropbox no longer makes Zephyr stop syncing. A folder with more than about
  20,000 items beneath it could crash the part of Zephyr that talks to Finder.
  Such changes now reach Finder in several smaller steps, and a folder with
  that many items directly inside it opens without trouble too.
- When GitHub is too busy to answer Check for Updates, Zephyr now says so and
  suggests trying again later, instead of reporting a network error. Zephyr
  also keeps working while that message, or the “up to date” message, is on
  screen.

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

- Putting an item back on Dropbox and resuming its syncing now works. It
  reported that the file did not exist, and a folder came back empty on both
  sides even though its contents were still held on this Mac. Putting a folder
  back now restores everything beneath it, subfolders included.
- A Dropbox outage no longer reads as a broken account: a token request Dropbox
  answers with a server error or a rate limit is retried, and one that keeps
  failing reports a connection problem instead of asking you to relink.
- Renaming or moving many files at once no longer stalls. Zephyr sends Dropbox
  one change at a time instead of racing them into its rate limit, and a rename
  Dropbox has already made no longer shows up as a sync issue.

## 1.0

- First release.
