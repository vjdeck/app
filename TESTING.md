# Testing

Start in a clean checkout on Apple Silicon with the requirements in
[README.md](README.md#빌드). Run:

```bash
./scripts/bootstrap.sh
./scripts/bootstrap.sh --verify-only
Tests/Scripts/build-ffmpeg-source-tests.sh
python3 Tests/Scripts/release-tests.py
xcodegen generate
xcodebuild -project VJDeck.xcodeproj -scheme VJDeck -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$PWD/.build/DerivedData" \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test
xcodebuild -project VJDeck.xcodeproj -scheme VJDeck -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$PWD/.build/DerivedData" \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test
xcodebuild -project VJDeck.xcodeproj -scheme VJDeck -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$PWD/.build/DerivedData" \
  CODE_SIGNING_ALLOWED=NO build
```

These are the same preparation, test, and build checks used in CI. Use a separate
`-derivedDataPath` for concurrent runs and a fresh `-resultBundlePath` if you
need a saved test result. The full suite runs in both Debug and Release; the
Release build also checks the app target. The FFmpeg source test verifies pinned
downloads and checksum failure handling without replacing the bundled binaries.
See [the regression matrix](Tests/REGRESSION_MATRIX.md) for playback and sync
coverage and [the rebuild guide](docs/ffmpeg-rebuild.md) for an isolated FFmpeg
and dav1d build.

`AppUpdaterTests` uses isolated signed fixtures to cover download validation,
install location restrictions, helper setup failures with a live parent,
ownership handoff, and forced termination before and after the atomic bundle
exchange. Cleanup checks preserve live downloads and orphaned child processes,
then remove abandoned downloads and staging without touching the installed app.
Release script tests use temporary git repositories
and mocked build/GitHub commands; they never publish an actual release.

For the connected software sync checks, run `-only-testing:VJDeckTests/SyncPipelineIntegrationTests`
with either configuration and a fresh result bundle. These tests prepare seeded
PCM reference audio, feed complete host-timestamped query windows through a fake
microphone capture boundary, and observe the real orchestrator, Shazam custom
catalog, local refiner, and sync view model. They use a controlled playback clock
and callback sink and do not request microphone permission or open an audio device.

The test target compiles `PlaylistStore` with `VJDECK_TESTING`, so its default
playlist library URL is stable within a test process and lives in a unique
temporary directory. Explicit-URL persistence tests use their own temporary
destinations. The application target retains its Application Support URL.

For changes involving playback or hardware, also run the app in Xcode and
exercise the affected path with real media. Microphone sync, MIDI controllers,
and Syphon receivers require their respective devices or applications and
cannot be established by the automated suite alone.
