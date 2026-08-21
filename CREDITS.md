# Credits

Zephyr itself is licensed under the [MIT License](LICENSE). The components below carry
their own terms.

## Prior art

Zephyr is a reimplementation of [Maestral](https://github.com/samschott/maestral) by Sam
Schott — MIT. No Maestral code is used or distributed; Zephyr shares none of its Python,
and reimplements its behavior against Apple's replicated File Provider model. What Zephyr
does carry over is Maestral's judgment: its always-excluded filename set, its one-week
history retention, its longpoll backoff padding, and the design of its delta-cursor
handling. It is the reason this project was tractable, and it deserves the credit.

## Apache-2.0 notices

Section 4(d) of the Apache License 2.0 attaches a notice obligation on binary
distribution, so these are called out explicitly rather than left to the list below.

- **[swift-argument-parser](https://github.com/apple/swift-argument-parser)** —
  Copyright the Swift project authors. Licensed under the Apache License, Version 2.0,
  with the Swift Runtime Library Exception.
- **[swift-async-algorithms](https://github.com/apple/swift-async-algorithms)** —
  Copyright the Swift project authors. Licensed under the Apache License, Version 2.0,
  with the Swift Runtime Library Exception.
- **[swift-collections](https://github.com/apple/swift-collections)** — Copyright the
  Swift project authors. Licensed under the Apache License, Version 2.0, with the Swift
  Runtime Library Exception.
- **[swift-log](https://github.com/apple/swift-log)** — Copyright 2018–2019 The SwiftLog
  Project. Licensed under the Apache License, Version 2.0, with no exception. It contains
  a derivation of the lock implementation from
  [SwiftNIO](https://github.com/apple/swift-nio), also Apache-2.0.

The Runtime Library Exception waives the attribution that sections 4(a), 4(b), and 4(d)
would otherwise require for portions of those libraries embedded into a binary product.
They are listed here regardless.

The full text of the Apache License, Version 2.0 is available at
<https://www.apache.org/licenses/LICENSE-2.0>.

## Swift packages

Direct dependencies of Zephyr:

- [GRDB.swift](https://github.com/groue/GRDB.swift) by Gwendal Roué — MIT. The SQLite
  layer under the per-account sync index.
- [Semaphore](https://github.com/groue/Semaphore) by Gwendal Roué — MIT.
- [swift-argument-parser](https://github.com/apple/swift-argument-parser) —
  Apache-2.0 with the Swift Runtime Library Exception. Used by `zephyr-cli` only.
- [swift-async-algorithms](https://github.com/apple/swift-async-algorithms) —
  Apache-2.0 with the Swift Runtime Library Exception.
- [GitHubUpdateChecker](https://github.com/RISCfuture/GitHubUpdateChecker) — MIT.
- [sentry-cocoa](https://github.com/getsentry/sentry-cocoa) — MIT. Crash reporting.
- [XCUITestKit](https://github.com/RISCfuture/XCUITestKit) — MIT. Test-only; not shipped
  in the app.

Pulled in transitively:

- [swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui) by Guillermo
  Gonzalez — MIT. Via GitHubUpdateChecker.
- [NetworkImage](https://github.com/gonzalezreal/NetworkImage) by Guille Gonzalez — MIT.
  Via swift-markdown-ui.
- [swift-cmark](https://github.com/swiftlang/swift-cmark) — **BSD 2-Clause**, Copyright
  © 2014 John MacFarlane. Via swift-markdown-ui. Not Apache-2.0: the Swift fork carries
  upstream cmark's BSD 2-Clause terms, and portions derived from
  [houdini](https://github.com/vmg/houdini), GitHub's buffer code, and
  [utf8proc](https://juliastrings.github.io/utf8proc/) are MIT.
- [swift-log](https://github.com/apple/swift-log) — Apache-2.0. Via GitHubUpdateChecker.
- [swift-collections](https://github.com/apple/swift-collections) — Apache-2.0 with the
  Swift Runtime Library Exception. Via swift-async-algorithms.

Every version is pinned in
`Zephyr.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`. The
licenses above were read from the checkouts of those exact pinned revisions.

## Dropbox

Zephyr is an independent client built against Dropbox's public HTTP API. It is **not
affiliated with, endorsed by, or sponsored by Dropbox, Inc.**, and bundles no Dropbox
code or SDK. Dropbox is a trademark of Dropbox, Inc.
