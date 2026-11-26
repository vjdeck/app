# Contributing to VJDeck

Use an Apple Silicon Mac with macOS 15.4 or later, Xcode 16.3 or later, and
XcodeGen 2.40 or later. Follow the bootstrap, generation, Debug and Release test,
and Release app build commands in [TESTING.md](TESTING.md). The first bootstrap
downloads pinned yt-dlp and Deno binaries and their licenses; the downloaded
files stay in ignored `.web-tools/`. The FFmpeg and Syphon binaries are already
tracked in `Frameworks/`. A normal build does not run `scripts/build-ffmpeg.sh`
or require `.ffmpeg-build/`.

Before proposing a change, run the checks in [TESTING.md](TESTING.md). If you
edit `project.yml`, run `xcodegen generate` and include the generated
`VJDeck.xcodeproj` changes in the same commit. Do not commit `.web-tools/`,
`.ffmpeg-build/`, `.build/`, or other local build products.

When changing a bundled dependency, update its version, source provenance,
license notice, and verification value together. The checked-in FFmpeg and
dav1d notices are documented in [Notices/README.md](Notices/README.md); the
web helper versions and SHA-256 values live in `scripts/fetch-web-tools.sh`.
Measure hashes from the actual upstream artifacts before updating them.
For a reproducible FFmpeg and dav1d rebuild, use the isolated staging procedure
in [docs/ffmpeg-rebuild.md](docs/ffmpeg-rebuild.md).

For the step-by-step Korean release procedure and failure recovery commands,
see [the release guide](docs/release-guide.ko.md).

To publish a release, add a `## [VERSION]` section to `CHANGELOG.md`, merge it,
and run `scripts/release.sh patch|minor|major|VERSION` from a clean `main` that
matches `origin/main` (`--dry-run` previews it). The script bumps
`Resources/Info.plist`, builds and ad-hoc signs the Release app, pushes the
`Bump version to vVERSION` commit and tag, and uploads `VJDeck.dmg` and
`VJDeck-VERSION.zip` to the public
[vjdeck/site releases](https://github.com/vjdeck/site/releases) with that
changelog section as notes. It needs `gh auth login` with write access there.
Missing or empty release notes and missing repository write access stop the
script before the version changes. If publishing fails after committing, the
script prints commands to finish the release using the existing commit, tag,
and assets. Both release commands use `scripts/build-dmg.sh` for building,
signing, and packaging; `--app PATH --output PATH` packages an existing app.

Release builds check that repository on launch. Writable copies directly in
`/Applications` or `~/Applications` download and verify
`VJDeck-VERSION.zip`, and install it when VJDeck quits or from Settings →
General → Restart to Update, after a confirmation that playback will stop.
Other locations, missing zip assets, and failed automatic updates show a manual
download link in Settings. Development Release builds are never replaced.
Downloads have separate work directories in `~/Library/Caches/com.bada.VJDeck/Updates`.
Each download records its owning app, subprocess, and installer. On launch,
VJDeck removes abandoned marked downloads and staging directories for that
installed copy, preserving live processes and their remaining child processes.
The installer copies onto the destination volume, rechecks the signature and
metadata, and uses the bundled `VJDeckUpdateSwap` tool to exchange complete
bundles atomically. A failed install leaves the existing app in place and records
the version plus a `failed-version.log` diagnostic in that cache directory;
that version is offered for manual installation instead of downloading again.
Even when helper setup fails, relaunch waits for the old app to exit first.
Keep that asset name and the bundle ID unchanged,
or installed copies ignore the release. Debug builds skip the check unless
launched with `-forceUpdateCheck YES`; that flag still respects install locations.
Ad-hoc signature verification detects damage but does not authenticate the
publisher. Update authenticity continues to rely on control of vjdeck/site;
separate signed update metadata is not part of this implementation.

Copies released before the move to the `vjdeck` organization still query
`ImBada/VJDeck-site`, which GitHub redirects to `vjdeck/site` because the
repository was transferred. Never create a repository at that old path, or those
copies stop receiving updates.
