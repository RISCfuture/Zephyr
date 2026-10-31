fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## Mac

### mac release

```sh
[bundle exec] fastlane mac release
```

Build the App Store edition and upload it to App Store Connect

### mac beta

```sh
[bundle exec] fastlane mac beta
```

Build the App Store edition and upload it to TestFlight

### mac download_release

```sh
[bundle exec] fastlane mac download_release
```

Archive, notarize, and package the downloadable edition for release

### mac ci_release

```sh
[bundle exec] fastlane mac ci_release
```

Archive one edition and ship it (CI)

### mac ci_next_build_number

```sh
[bundle exec] fastlane mac ci_next_build_number
```

Resolve the next build number and write it where CI can read it

### mac ci_verify_release

```sh
[bundle exec] fastlane mac ci_verify_release
```

Refuse to start a release that names the wrong version, sits off main, or lacks notes (CI)

### mac ci_finish_release

```sh
[bundle exec] fastlane mac ci_finish_release
```

Write the release notes and attach the build to its version (CI)

### mac site_screenshots

```sh
[bundle exec] fastlane mac site_screenshots
```

Regenerate the site's and the help book's screenshots from the UI test harness

### mac mac_screenshots

```sh
[bundle exec] fastlane mac mac_screenshots
```

Capture the Mac windows and render the Mac App Store screenshots

### mac verify

```sh
[bundle exec] fastlane mac verify
```

Check the rendered media against Apple's rules and the screenshots against the storyboard

### mac upload_mac_screenshots

```sh
[bundle exec] fastlane mac upload_mac_screenshots
```

Upload the rendered Mac screenshots to App Store Connect

### mac upload_metadata

```sh
[bundle exec] fastlane mac upload_metadata
```

Upload fastlane/metadata to the version open for editing

### mac download_metadata

```sh
[bundle exec] fastlane mac download_metadata
```

Download the live listing into fastlane/metadata

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
