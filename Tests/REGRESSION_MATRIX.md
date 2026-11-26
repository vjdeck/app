# Playback and synchronization regression matrix

The original audio-sync regression report (legacy issue #2) is covered by the tests below. The test target compiles the named production sources, including the real in-process decoder, player service, player view model, sync orchestrator, sync view model, and master renderer. `VJDECK_TESTING` is defined only for the test target in Debug and Release; the application keeps its normal compile conditions.

| Area | Automated assertions | Test file |
| --- | --- | --- |
| Frame queue and cache | FIFO, full rejection, ring wrap, peek, flush, resize minimum, 2 ms presentation boundary, late-frame dropping, future-frame retention, sorted insertion, duplicate PTS, farthest-frame byte eviction, oversized single frame | `FrameQueueLifecycleTests.swift` |
| Decoder and PCM sharing | Tiny-write RIFF/RF64 streams, odd metadata chunk, truncated header/data and incomplete float rejection, bundled FFmpeg 9.0.2-to-synthetic-PCM extraction, per-URL cache eviction, shared extraction with one consumer cancelled, running FFmpeg child termination | `AudioExtractionLifecycleTests.swift` |
| PCM render | Sustained rate accuracy, variable callback sizes, pause/reentry, seek/scratch/stop/load/loop resets, reverse and silent tail | `PCMAudioEngineTests.swift` (integrated PCM commit) |
| Real player | Silent video load, seek, play, pause, stop, replacement, missing-file recovery, observable EOF stop and decode-thread loop completion | `RealPlayerLifecycleTests.swift` |
| Player session | Rapid A-to-B replacement and unload after actual audio-bearing player load and offline PCM engine creation, player-owned synthetic PCM eviction and engine release, stale load/time/audio callbacks, render source generation | `PlayerViewModelLifecycleTests.swift` |
| Sync view model with fake orchestrator | Start/stop/restart, old stream event rejection, rate reset, fake-clock microphone watchdog failure, failure cleanup | `SyncSessionLifecycleTests.swift` |
| Real sync orchestrator with fake microphone capture | Prepared reference and reset generation, start/stop/restart, old capture callbacks ignored, capture-start failure cleanup, stream finish and capture shutdown | `AudioSyncOrchestratorLifecycleTests.swift` |
| Connected software sync pipeline | Seeded reference PCM and complete 88,200-frame capture windows through fake microphone delivery, real query accumulator and `SHSession` custom catalog, Shazam acquisition at 5.000 s, real view-model seek and rate callback, next-stride local refinement, unrelated-audio no-match without a seek, and stopped-session callback rejection after restart | `SyncPipelineIntegrationTests.swift` |
| Master output | Offscreen Metal red/blue blend endpoints and midpoint, missing deck, zero opacity, stale render session rejection, deck registration/removal and render-state snapshot | `MasterOutputLifecycleTests.swift`, `MasterOutputViewModelLifecycleTests.swift` |

## Repeatable verification

Run on Apple Silicon macOS with Xcode and XcodeGen. First run `./scripts/bootstrap.sh` to verify the tracked FFmpeg and Syphon frameworks and install the pinned web helpers in ignored `.web-tools/`. The ordinary test build does not need `.ffmpeg-build/`; see [the rebuild guide](../docs/ffmpeg-rebuild.md) if rebuilding FFmpeg. Choose fresh result bundle and derived-data paths for each run:

```sh
xcodegen generate
xcodebuild test -project VJDeck.xcodeproj -scheme VJDeck -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/vjdeck-integration-debug -resultBundlePath /tmp/vjdeck-integration-debug.xcresult -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO
xcodebuild test -project VJDeck.xcodeproj -scheme VJDeck -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/vjdeck-integration-release -resultBundlePath /tmp/vjdeck-integration-release.xcresult -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO
```

The synthetic video fixtures are checked in; `Tests/Fixtures/README.md` records their generation commands. Real extraction tests resolve FFmpeg from the built sibling `VJDeck.app`, verify version 9.0.2, and override the executable only for their fixture URL; no Homebrew FFmpeg is needed. The cancellation test uses a short local script as a child executable for one URL. The audio-bearing player tests hold an actual load after the synthetic PCM handle and offline engine exist, then await replacement/unload cleanup before asserting cache eviction and engine release. They do not open an audio device. `SyncSessionLifecycleTests` injects a fake orchestrator and clock into the real view model. `AudioSyncOrchestratorLifecycleTests` instantiates the real orchestrator with prepared PCM/Shazam reference state and injects only fake microphone capture, so it exercises its own session and cleanup methods without requesting microphone permission. The app still constructs the same concrete microphone capture and player services by default.

Baseline verification on 2026-09-29: full Debug and Release runs at the previous commit each passed **327 tests with zero failures or skips**. Both runs included all five `PCMAudioEngineTests` from the integrated PCM commit. Their logs and result bundles are `/tmp/vjdeck-core-fbf651-full-debug.log`, `/tmp/vjdeck-core-fbf651-full-debug.xcresult`, `/tmp/vjdeck-core-fbf651-full-release.log`, and `/tmp/vjdeck-core-fbf651-full-release.xcresult`. The new orchestrator suite is verified separately below; final combined suites are integration-owned.

Focused orchestrator verification on 2026-09-29: Debug and Release each passed **3 tests with zero failures or skips**. Logs and result bundles are `/tmp/vjdeck-orchestrator-debug-final.log`, `/tmp/vjdeck-orchestrator-debug-final.xcresult`, `/tmp/vjdeck-orchestrator-release.log`, and `/tmp/vjdeck-orchestrator-release.xcresult`.

Combined integration verification on 2026-09-29: the full Debug and Release suites each passed **330 tests with zero failures or skips**. Logs and result bundles are under `/tmp/vjdeck-public-readiness-task_cf58a3c6dd1c/`: `debug-final.log`, `debug-final.xcresult`, `release-final.log`, and `release-final.xcresult`. The Release app build also passed; see `release-app-final.log` and `release-app-final.xcresult` in the same directory.

Clean-host extraction and lifecycle follow-up verification on 2026-09-29: the affected Debug and Release suites each passed **13 tests**, and the complete Debug and Release suites each passed **331 tests with zero failures or skips**. Logs and result bundles are under `/tmp/vjdeck-readiness-fix-task_f23f3cc9eb10/`. The real extraction test explicitly checks the built app's bundled FFmpeg 9.0.2; the added audio-bearing fixture runs through real player ownership while an offline PCM engine prevents hardware output. Release app and project parity evidence are recorded in the external implementation report.

Issue #7 connected-pipeline verification on 2026-09-29: focused Debug and Release suites each passed **3 tests**, full Debug and Release suites each passed **334 tests with zero failures or skips**, and the Release app build passed. The final result bundles and logs use the `/tmp/vjdeck-issue7-final-` prefix. The synthetic query starts at reference 5.000 s; the actual Shazam anchor was 5.000 s in both configurations, the next local refinement was 6.250 s, and the seek callback was 7.153 s in Debug and 7.132 s in Release, reflecting query age and the configured latency offset. Against the host-time extrapolation formula, the observed seek errors were -2.1 ms and -1.5 ms respectively. The corresponding rate callbacks were 1.0000× at acquisition and approximately 1.0003× after local refinement. These are software-only results.

## Remaining software scope

The connected pipeline tests execute Shazam acquisition and the local refinement branch at normal playback rate. Tempo-invariant acquisition, discontinuity recovery after a confirmed jump, repeated query failures, and sustained playback-rate changes remain covered by component tests rather than a connected view-model session. Capture is deterministic PCM injected at the microphone boundary, with a controlled playback clock and callback sink. No physical microphone or audio output device is opened.

## Remaining device checks

Actual microphone permission, device interruption and restart, MIDI control surfaces, Syphon receivers, display timing, audio output latency, and long multi-deck playback require a supervised hardware session. The offline Metal blend test requires a GPU and shader library; it explicitly skips if either is unavailable. The tests do not establish audio/video synchronization quality under live capture or sustained thermal load.
