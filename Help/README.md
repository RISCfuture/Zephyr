# The Zephyr Help book

`Zephyr.help` is the Apple Help book both editions ship. It is one book, in one
language folder, staged into each app at build time.

```text
Zephyr.help/Contents/
  Info.plist                        book metadata
  Resources/
    help-icon.png                   HPDBookIconPath, reached as ../help-icon.png
    en.lproj/
      index.html                    the landing page and full table of contents
      *.html                        one article per topic
      zephyr-help.css
      images/                       generated — see Screenshots below
```

## How to write for it

**The model is Apple's own user guides, not this project's marketing site.** A
help book is read by somebody who is stuck; restating what Zephyr is good at
wastes their time. macOS no longer ships Safari's help locally, but
`/Library/Documentation/Help/Offline.help` is a real Apple help book on disk —
read its HTML and its `harrier/app.css` when a question comes up, rather than
guessing.

What that model means in practice:

- **A page is one task**, titled as the reader's goal ("Turn on Zephyr in
  Finder") or the reader's symptom ("If your Dropbox doesn't appear in Finder").
  Never a feature name, never a benefit.
- **The first paragraph is one plain sentence** saying what you can do here.
- **The body is `<div class="Task">` blocks** — an `<h2 class="Name">` and a
  `<div class="TaskBody">` of numbered steps naming exact controls and exact
  menu paths. "Before you begin" is its own block, with a `<ul>`.
- **A do-it-for-me link goes inside the step** that sends the reader somewhere:
  `<a href="x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
  class="URL">`. The same URLs are in `SystemSettings` in `ZephyrScenes.swift`.
  Apple's own `x-help-action://openPrefPane` is a private scheme; don't rely on
  it.
- **A note is not a box.** `<div class="Alert"><p class="Note"><em>Note: </em>…`
  and nothing else: no background, no border, no rule. The italic lead-in is the
  whole treatment, which is what Apple's stylesheet does.
- **"See also" closes the page**, as
  `<div class="LinkUniversal"><strong>See also</strong>` plus
  `a.xRef.AppleTopic` links.

Every page carries `<meta name="robots" content="anchors">` — Apple's spelling —
and its own `<a name="…">` as the first element in `<body>`, matching the
`<body id>` and the filename stem.

**One linkable anchor per page**, which is Apple's own practice rather than a
workaround: `hiutil` records a single target per page, so a second anchor
part-way down is reachable by an in-page `href="#…"` but a `HelpAnchor` pointing
at it lands at the top of the page instead. If the interface needs to land on a
topic, give that topic its own page.

The anchors the interface asks for are named once in
`libZephyr/Support/HelpAnchor.swift`, and the build **fails** when that enum
names one the book doesn't define — a misspelled anchor doesn't error at
runtime, it quietly opens the book's first page instead of the topic, so the
build is the only place to catch it. The check runs one way only: the book
carries far more anchors than the interface links to.

For styling and copy alone, skip the build: the pages are ordinary HTML and
`open Help/Zephyr.help/Contents/Resources/en.lproj/index.html` renders them in a
browser. Only anchors, search, and the icon need a real book.

## How it gets into the app

The book sits outside every synchronized group on purpose. Xcode has no file
type for the `.help` extension, so a synchronized group descends into the bundle
and treats each page as a loose resource, colliding the book's own `Info.plist`
with the target's. Staging it with a script phase is what keeps the wrapper
intact.

That phase is **Build Help Book**, on each app target, and it runs
`Scripts/build-help-book.sh`: the book is copied into the app's
`Contents/Resources` and `hiutil` builds the CoreSpotlight search index each
localization ships. Both editions share one bundle identifier, so one book
identifier serves both and is checked in rather than stamped.

`CFBundleHelpBookFolder` and `CFBundleHelpBookName` live in
`Zephyr-MAS-Info.plist` and `Zephyr-download-Info.plist`, which exist for those
two keys alone. Everything else in each app's `Info.plist` is still generated
from build settings — but Xcode carries only the keys it knows through
`INFOPLIST_KEY_`, and silently drops these two.

## Reading it the way a user does

The viewer is **Tips.app**. `com.apple.helpviewer` resolves to
`/System/Applications/Tips.app` on current macOS — there is no longer a Help
Viewer.app to look for. The book can be opened without going through the app at
all:

```sh
open "help:openbook=codes.tim.Zephyr.help"
open "help:anchor=settings-bandwidth%20bookID=codes.tim.Zephyr.help"
```

## When an edit doesn't show up

**`helpd` does not read the book out of the app.** It copies it into its own
group container the first time it sees it, and serves the copy ever after:

```text
~/Library/Group Containers/group.com.apple.helpviewer.content/Library/Caches/
  codes.tim.Zephyr.codes.tim.Zephyr.help*1.0.help
```

That `*1.0` is the **app's** `CFBundleShortVersionString`, and it is the whole
cache key. The book's own version isn't in it, and neither is anything derived
from the content — so while the marketing version stays put, every rebuild is
ignored and the copy taken the first time is what the reader gets. An edit that
never shows up, a page stuck without its images, a Help menu landing on the
generic macOS Tips page: all the same cause.

`hiutil -P` does **not** clear that copy — it clears what `helpd` derived,
system-wide, and leaves the served copy where it is. *System-wide* is not a
figure of speech: running the purge drops every other app's registration too, so
for the next half-minute their help buttons report the same failure. That is
worth knowing before concluding this book is the broken one. Both halves are
`Scripts/purge-help-cache.sh`:

```sh
Scripts/purge-help-cache.sh
```

**Then open the book at its root before clicking any help button.** An anchor
resolves only once `helpd` has *registered* the book, which is a separate thing
from having a copy of it:

```text
~/Library/Caches/com.apple.helpd/Generated/codes.tim.Zephyr.help*1.0
```

The file to watch for is `en.cshelpindex` inside it — helpd builds its *own* index
from the book's pages rather than serving the one we ship, and an anchor
resolves only once that file exists. Measured on this project: about 25 seconds
after the first request, for a copy in `/Applications`.

```sh
ls ~/Library/Caches/com.apple.helpd/Generated/codes.tim.Zephyr.help*1.0/
```

Until that exists, every help button reports "The selected content is currently
unavailable", and so does a `help:anchor=` URL. A help button clicked first
after a purge looks exactly like a broken button, and isn't.

What registers the book depends on where the app is, which is why this bites in
development and barely shows in the wild:

- **In `/Applications`**, which `helpd` watches: the first help request wakes
  `helpd` and starts registration. That request still fails, but registration
  lands about half a minute later on its own and every request after it
  resolves.
- **Anywhere else**, which is every build run out of DerivedData: `helpd` never
  registers the book off a request, and waiting does nothing. Opening the book
  at its root is what registers it, and it is the only thing that does.

`NSHelpManager.registerBooks(in:)` does not substitute for either.

One more trap when two copies of the app exist: they share a bundle identifier,
and LaunchServices decides which one `helpd` resolves the book from. If the
pages you are looking at are older than the ones you just built, check which
copy won before assuming the build is at fault.

## Screenshots

The book's images are taken from the running app, not captured by hand.
`bundle exec fastlane mac screenshots` drives `ScreenshotUITests` and
`Scripts/export-screenshots.sh` writes each still into the site's images, the
App Store's, and the book's — one capture run for all three, so a page in the
book can never illustrate an older build than the site does. Commit the images
with the article changes.

The lane **owns** `Help/Zephyr.help/Contents/Resources/en.lproj/images` and
empties it before writing, so nothing else may be kept there — which is why the
book's icon sits at `Contents/Resources/help-icon.png` and `HPDBookIconPath`
reaches it as `../help-icon.png`.

The APNG the site plays is deliberately not copied here: a looping animation is
the one thing a help page must not carry, so the book embeds the first-page
still instead.

Captures are taken on a 2× display, so a page embeds one at half its pixel size
— `width="448" height="480"` for the 896×960 menu-bar panel. The lane checks
that declaration against the file the page names, and checks that some page
embeds every capture the suite takes: an image nobody embeds is served from the
site and shipped inside both app bundles for nothing, and since the suite goes
on taking it there is nothing to notice. Pages on the site count towards that
too, so dropping a picture from an article here only fails the check when
nothing in `docs/` embeds it either.

**Settings is captured twice, and the book embeds the narrower one.**
`settings-bandwidth` is the band between the Bandwidth and Metered Networks
headings, and `settings-bandwidth.html` is the only page that embeds it. The
whole window, `settings`, is the site's and the listing's, and does not belong
on a page here on two counts: scaled into the column a help window gives it, it
is a picture of a window rather than of the setting the paragraph beside it
describes, and it carries the two lines where the editions differ — that the
store keeps Zephyr up to date, that the command-line tool comes with the
download. One book is built into both editions, so a page embedding the whole
window tells a reader of the other edition about somebody else's app.

**There is a second images directory, held on the opposite terms.**
`Contents/Resources/en.lproj/system` is for pictures of the surfaces macOS draws
*around* Zephyr — Finder's context menu, the control in Control Center, the File
Providers switch in System Settings. `Scripts/capture-system-shots.sh`
writes it, by hand, and the lane neither owns it nor empties it. The rule above
is about `images` alone. The two directories keep opposite lifecycles: `images`
is a build product, so anything else kept in it is destroyed on the next run and
a capture in it can be trusted to be current because it was taken minutes ago,
while nothing regenerates `system` — what is committed there stays until
somebody deletes it, and an image that has fallen behind the interface goes on
being wrong with nothing in the project to say so.

**Three subjects are kept there**, in both appearances: `finder-menu`,
`control-center-pause`, and `system-settings-file-providers`. No page embeds one
yet, so pointing an article at one costs nothing beyond writing the `<img>`.

Each is framed on itself rather than on the screen — the context menu on its own
bounds, the File Providers sheet on the sheet rather than the window beneath it,
Control Center on its grid of round tiles — which is what keeps the machine it
was taken on out of the picture: a terminal behind the Finder window, the Wi-Fi
network by name, the operator's own name and Apple Account down the side of
System Settings. The menu
is cut where Zephyr's actions end, so the Quick Actions of whatever else is
installed on that Mac stay out of Zephyr's help.

A neutral backdrop goes up for the length of a run, because framing cannot reach
what a translucent surface refracts: Liquid Glass samples what is behind it, and
a Control Center panel photographed over a blue wallpaper is a blue panel on
every page that embeds it.

**Two subjects are deliberately not captured, and nothing here should wait for
them.** The version-history sheet and the widget are Zephyr's own, so the lane
already photographs both out of the design gallery — `file-versions`,
`widget-small`, `widget-medium`, all in `images`, all current by construction. A
hand-taken picture of the same sheet on a real Finder window, or of the widget
sitting on a desktop, would say no more and would go stale on its own. Illustrate
those pages from `images`.

So illustrate a page with a system capture when what the page is about is a
thing macOS draws — the switch the reader has to find in System Settings, the
menu item they are being told to choose. Anything Zephyr draws itself is already
in `images` and costs nothing to embed.
