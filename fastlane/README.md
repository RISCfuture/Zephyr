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

### mac screenshots

```sh
[bundle exec] fastlane mac screenshots
```

Regenerate the site's and the App Store listing's screenshots from the UI test harness

### mac upload_app_store_screenshots

```sh
[bundle exec] fastlane mac upload_app_store_screenshots
```

Replace the App Store listing's screenshots with the captured set

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
