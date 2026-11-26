#!/bin/bash
set -euo pipefail

# Prepare a clean checkout for XcodeGen and verify the checked-in libraries.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

if [ "$#" -gt 1 ] || { [ "$#" -eq 1 ] && [ "$1" != "--verify-only" ]; }; then
    echo "Usage: $0 [--verify-only]" >&2
    exit 64
fi

if [ "$(uname -m)" != "arm64" ]; then
    echo "ERROR: VJDeck's checked-in FFmpeg libraries and Deno helper require Apple Silicon (arm64)." >&2
    exit 1
fi

for dependency in \
    Frameworks/FFmpeg/bin/ffmpeg \
    Frameworks/FFmpeg/lib/libavcodec.dylib \
    Frameworks/FFmpeg/lib/libavformat.dylib \
    Frameworks/FFmpeg/lib/libavfilter.dylib \
    Frameworks/FFmpeg/lib/libavutil.dylib \
    Frameworks/FFmpeg/lib/libswresample.dylib \
    Frameworks/FFmpeg/lib/libswscale.dylib \
    Frameworks/Syphon.framework/Syphon; do
    if [ ! -f "$PROJECT_DIR/$dependency" ]; then
        echo "ERROR: missing checked-in dependency: $dependency" >&2
        exit 1
    fi
done

verify_notice() {
    local path="$1"
    local expected="$2"
    local actual
    if [ ! -f "$PROJECT_DIR/$path" ]; then
        echo "ERROR: missing source notice: $path" >&2
        exit 1
    fi
    actual="$(shasum -a 256 "$PROJECT_DIR/$path" | awk '{print $1}')"
    if [ "$actual" != "$expected" ]; then
        echo "ERROR: source notice checksum mismatch: $path" >&2
        exit 1
    fi
}

verify_notice Notices/FFmpeg-LGPL-2.1.txt 246041b6ecf9bc32d718a62c57877c78b5eb397b6467e74ed7ae2626ab189c30
verify_notice Notices/dav1d-BSD-2-Clause.txt b327887de263238deaa80c34cdd2ff3e0ba1d35db585ce14a37ce3e74ee389e9
verify_notice Notices/Syphon-BSD.txt 2d488394b367687709bc453601f423271d82d4b4d00354ade6b1d9e489aefaee

"$SCRIPT_DIR/fetch-web-tools.sh" "$@"
echo "=== VJDeck bootstrap verified; run xcodegen generate ==="
