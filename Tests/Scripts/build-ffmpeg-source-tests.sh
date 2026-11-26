#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_DIR="$(mktemp -d /tmp/vjdeck-ffmpeg-source-test.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
export FFMPEG_BUILD_DIR="$TEST_DIR/build"
export FFMPEG_OUTPUT_DIR="$TEST_DIR/output with space"

BUILDER="$PROJECT_DIR/scripts/build-ffmpeg.sh"
SPACED_BUILD_DIR="$TEST_DIR/spaced build"
if FFMPEG_BUILD_DIR="$SPACED_BUILD_DIR" "$BUILDER" --prepare-sources > "$TEST_DIR/spaced-build.log" 2>&1; then
    echo "ERROR: whitespace in FFmpeg build path was accepted" >&2
    exit 1
fi
grep -q 'FFMPEG_BUILD_DIR must contain no whitespace' "$TEST_DIR/spaced-build.log"
test ! -e "$SPACED_BUILD_DIR"
test ! -e "$FFMPEG_OUTPUT_DIR"

if [ "${1:-}" = "--path-only" ]; then
    echo "Build path rejection passed."
    exit 0
fi

"$BUILDER" --prepare-sources

FFMPEG_ARCHIVE="$FFMPEG_BUILD_DIR/ffmpeg-9.0.2.tar.xz"
DAV1D_ARCHIVE="$FFMPEG_BUILD_DIR/dav1d-1.5.1.tar.xz"
test -f "$FFMPEG_ARCHIVE"
test -f "$DAV1D_ARCHIVE"
test -f "$FFMPEG_BUILD_DIR/ffmpeg-9.0.2/configure"
test -f "$FFMPEG_BUILD_DIR/dav1d-1.5.1/meson.build"

mv "$FFMPEG_ARCHIVE" "$TEST_DIR/ffmpeg-good.tar.xz"
printf 'corrupt archive\n' > "$FFMPEG_ARCHIVE"
if "$BUILDER" --prepare-sources > "$TEST_DIR/ffmpeg-bad.log" 2>&1; then
    echo "ERROR: corrupted FFmpeg archive was accepted" >&2
    exit 1
fi
grep -q 'SHA-256 mismatch' "$TEST_DIR/ffmpeg-bad.log"
mv "$TEST_DIR/ffmpeg-good.tar.xz" "$FFMPEG_ARCHIVE"

mv "$DAV1D_ARCHIVE" "$TEST_DIR/dav1d-good.tar.xz"
printf 'corrupt archive\n' > "$DAV1D_ARCHIVE"
if "$BUILDER" --prepare-sources > "$TEST_DIR/dav1d-bad.log" 2>&1; then
    echo "ERROR: corrupted dav1d archive was accepted" >&2
    exit 1
fi
grep -q 'SHA-256 mismatch' "$TEST_DIR/dav1d-bad.log"
mv "$TEST_DIR/dav1d-good.tar.xz" "$DAV1D_ARCHIVE"

"$BUILDER" --prepare-sources > "$TEST_DIR/recovery.log"
echo "Source download, checksum rejection, and recovery passed."
