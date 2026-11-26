# Rebuilding the bundled FFmpeg libraries

`scripts/build-ffmpeg.sh` builds the Apple Silicon FFmpeg libraries and CLI used
by VJDeck. It builds dav1d as a static library first, then builds FFmpeg shared
libraries with the same codec, demuxer, parser, filter, and rpath settings as
the bundled version. dav1d is linked into `libavcodec.dylib`; there is no
separate dav1d dylib to embed.

## Prerequisites and pinned source

Use an Apple Silicon Mac with Xcode Command Line Tools and Homebrew. Install the
build tools with `brew install meson ninja nasm pkg-config`. The script also uses
the macOS tools `clang`, `make`, `sysctl`, `install_name_tool`, `otool`, `curl`,
`tar`, and `shasum`. It targets macOS 13.0 or later and builds arm64 only.

| Source | URL | SHA-256 |
| --- | --- | --- |
| FFmpeg 9.0.2 | <https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz> | `8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e` |
| dav1d 1.5.1 | <https://downloads.videolan.org/pub/videolan/dav1d/1.5.1/dav1d-1.5.1.tar.xz> | `401813f1f89fa8fd4295805aa5284d9aed9bc7fc1fdbe554af4292f64cbabe21` |

The dav1d digest is published in VideoLAN's adjacent `.sha256` file. The FFmpeg
digest matches the official release archive and the archive used for the
current vendored build.
The script verifies both archives before extracting them, including cached
copies. An HTTP failure, partial download, or digest mismatch stops the build.

## Build and verify in an isolated directory

Run from the repository root. Use a fresh absolute staging path so the tracked
`Frameworks/FFmpeg` bundle stays untouched. `FFMPEG_BUILD_DIR` must contain no
whitespace because FFmpeg splits its compiler and linker flags on whitespace.
If the repository is under a path with spaces, override the default build path
with a whitespace-free absolute path such as the one below. `FFMPEG_OUTPUT_DIR`
may use spaces.

```sh
stage="$(mktemp -d /tmp/vjdeck-ffmpeg-rebuild.XXXXXX)"
FFMPEG_BUILD_DIR="$stage/build" FFMPEG_OUTPUT_DIR="$stage/output" \
  scripts/build-ffmpeg.sh

test -f "$stage/build/dav1d-install-arm64/lib/libdav1d.a"
test -f "$stage/build/dav1d-install-arm64/lib/pkgconfig/dav1d.pc"
test -f "$stage/output/FFmpeg/lib/libavcodec.dylib"
otool -D "$stage/output/FFmpeg/lib/libavcodec.dylib"
otool -L "$stage/output/FFmpeg/lib/libavcodec.dylib"
DYLD_LIBRARY_PATH="$stage/output/FFmpeg/lib" \
  "$stage/output/FFmpeg/bin/ffmpeg" -hide_banner -decoders | grep libdav1d
```

Check that the `otool` output has an `@rpath/libavcodec.dylib` install ID and
no Homebrew `libdav1d.dylib` dependency. The decoder list should include
`libdav1d`. The full build also rewrites the CLI's FFmpeg library references
and embeds `@executable_path/../Frameworks` for the app's CLI placement.

For source integrity checks without compiling, run
`Tests/Scripts/build-ffmpeg-source-tests.sh`. It downloads the pinned sources
to its own temporary directory, confirms that corrupt cached archives are
rejected, and removes that directory afterward. For a fast check of the path
guard alone, run `Tests/Scripts/build-ffmpeg-source-tests.sh --path-only`.
To prepare sources only, run
`scripts/build-ffmpeg.sh --prepare-sources` with the same staging environment
variables.

The default build locations remain `.ffmpeg-build` and `Frameworks`. Running
without staging variables replaces the repository's bundled FFmpeg files;
review the resulting binaries and licenses before intentionally updating them.
The regular app bootstrap and license input paths are described separately in
the main build instructions.
