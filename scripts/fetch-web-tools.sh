#!/bin/bash
set -euo pipefail

# Reproducibly fetch the web-video helper binaries used by VJDeck.
# Artifacts are staged under .web-tools/ and intentionally not committed.

MODE="fetch"
if [ "$#" -gt 1 ]; then
    echo "Usage: $0 [--verify-only]" >&2
    exit 64
fi
if [ "$#" -eq 1 ]; then
    if [ "$1" != "--verify-only" ]; then
        echo "Usage: $0 [--verify-only]" >&2
        exit 64
    fi
    MODE="verify"
fi

YT_DLP_VERSION="2026.08.19"
YT_DLP_SHA256="0f192b7ec147ab6288885d6351d9ab67367640029b4377576ef46dd79cf7b202"
YT_DLP_LICENSE_SHA256="7e12e5df4bae12cb21581ba157ced20e1986a0508dd10d0e8a4ab9a4cf94e85c"
YT_DLP_THIRD_PARTY_SHA256="472aefe951c7db35e1657c1d13fd337140511ed6f2b329205105ad441c5a02b7"

DENO_VERSION="2.9.6"
DENO_ARCHIVE_SHA256="213a2f304f04d3c9cb5220669afad138f60a5aab1fe80962abdeb8f35807a472"
DENO_BINARY_SHA256="b3ac3bd206e48c26026cadd80c1367e96c149f9c66130952382a642b09fa8a71"
DENO_LICENSE_SHA256="f62497fffecc0852960c8d3e6934b9db86d16396e9b604072e923892cae3a588"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TOOLS_DIR="$PROJECT_DIR/.web-tools"
BIN_DIR="$TOOLS_DIR/bin"
LICENSE_DIR="$TOOLS_DIR/licenses"
CREDITS_FILE="$PROJECT_DIR/Resources/Credits.rtf"

YT_DLP_URL="https://github.com/yt-dlp/yt-dlp/releases/download/${YT_DLP_VERSION}/yt-dlp_macos"
YT_DLP_LICENSE_URL="https://raw.githubusercontent.com/yt-dlp/yt-dlp/${YT_DLP_VERSION}/LICENSE"
YT_DLP_THIRD_PARTY_URL="https://raw.githubusercontent.com/yt-dlp/yt-dlp/${YT_DLP_VERSION}/THIRD_PARTY_LICENSES.txt"
DENO_ARCHIVE_URL="https://github.com/denoland/deno/releases/download/v${DENO_VERSION}/deno-aarch64-apple-darwin.zip"
DENO_LICENSE_URL="https://raw.githubusercontent.com/denoland/deno/v${DENO_VERSION}/LICENSE.md"

for command_name in awk curl ditto file grep shasum; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "ERROR: required command not found: $command_name" >&2
        exit 1
    fi
done

verify_sha256() {
    local path="$1"
    local expected="$2"
    local actual
    actual="$(shasum -a 256 "$path" | awk '{print $1}')"
    if [ "$actual" != "$expected" ]; then
        echo "ERROR: checksum mismatch for $(basename "$path")" >&2
        echo "  expected: $expected" >&2
        echo "  actual:   $actual" >&2
        exit 1
    fi
}

verify_existing() {
    local path="$1"
    local expected="$2"
    if [ ! -f "$path" ]; then
        echo "ERROR: required web tool artifact is missing: $path" >&2
        echo "Run scripts/fetch-web-tools.sh before building VJDeck." >&2
        exit 1
    fi
    verify_sha256 "$path" "$expected"
}

validate_executables() {
    if [ ! -x "$BIN_DIR/yt-dlp" ] || [ ! -x "$BIN_DIR/deno" ]; then
        echo "ERROR: yt-dlp and Deno must be executable" >&2
        exit 1
    fi
    if ! file "$BIN_DIR/yt-dlp" | grep -q "Mach-O universal binary"; then
        echo "ERROR: yt-dlp is not the expected universal macOS executable" >&2
        exit 1
    fi
    if ! file "$BIN_DIR/deno" | grep -q "arm64"; then
        echo "ERROR: Deno is not an Apple Silicon executable" >&2
        exit 1
    fi
}

print_versions() {
    echo "yt-dlp: $("$BIN_DIR/yt-dlp" --version)"
    echo "Deno:    $("$BIN_DIR/deno" --version | head -n 1)"
}

verify_credits_versions() {
    if [ ! -f "$CREDITS_FILE" ]; then
        echo "ERROR: About credits file is missing: $CREDITS_FILE" >&2
        exit 1
    fi
    if ! grep -Fq "yt-dlp $YT_DLP_VERSION macOS executable" "$CREDITS_FILE"; then
        echo "ERROR: Credits.rtf does not list pinned yt-dlp $YT_DLP_VERSION" >&2
        exit 1
    fi
    if ! grep -Fq "Deno $DENO_VERSION (MIT)" "$CREDITS_FILE"; then
        echo "ERROR: Credits.rtf does not list pinned Deno $DENO_VERSION" >&2
        exit 1
    fi
}

if [ "$MODE" = "verify" ]; then
    verify_existing "$BIN_DIR/yt-dlp" "$YT_DLP_SHA256"
    verify_existing "$BIN_DIR/deno" "$DENO_BINARY_SHA256"
    verify_existing "$LICENSE_DIR/yt-dlp-Unlicense.txt" "$YT_DLP_LICENSE_SHA256"
    verify_existing "$LICENSE_DIR/yt-dlp-Third-Party.txt" "$YT_DLP_THIRD_PARTY_SHA256"
    verify_existing "$LICENSE_DIR/Deno-MIT.txt" "$DENO_LICENSE_SHA256"
    validate_executables
    verify_credits_versions
    echo "=== Web video tools verified ==="
    echo "yt-dlp: $YT_DLP_VERSION"
    echo "Deno:    $DENO_VERSION"
    exit 0
fi

mkdir -p "$BIN_DIR" "$LICENSE_DIR"
FETCH_DIR="$(mktemp -d "$TOOLS_DIR/.fetch.XXXXXX")"
cleanup() {
    if [ -d "$FETCH_DIR" ]; then
        find "$FETCH_DIR" -depth -delete
    fi
}
trap cleanup EXIT

fetch_verified() {
    local url="$1"
    local destination="$2"
    local expected="$3"
    local temporary="$FETCH_DIR/$(basename "$destination").download"

    if [ -f "$destination" ]; then
        if [ "$(shasum -a 256 "$destination" | awk '{print $1}')" = "$expected" ]; then
            return
        fi
        echo ">>> Replacing invalid local artifact: $(basename "$destination")"
    fi

    echo ">>> Downloading $(basename "$destination")"
    curl --fail --location --retry 3 --output "$temporary" "$url"
    verify_sha256 "$temporary" "$expected"
    mv -f "$temporary" "$destination"
}

fetch_verified "$YT_DLP_URL" "$BIN_DIR/yt-dlp" "$YT_DLP_SHA256"
fetch_verified "$YT_DLP_LICENSE_URL" "$LICENSE_DIR/yt-dlp-Unlicense.txt" "$YT_DLP_LICENSE_SHA256"
fetch_verified "$YT_DLP_THIRD_PARTY_URL" "$LICENSE_DIR/yt-dlp-Third-Party.txt" "$YT_DLP_THIRD_PARTY_SHA256"

DENO_ARCHIVE="$FETCH_DIR/deno-aarch64-apple-darwin.zip"
if [ ! -f "$BIN_DIR/deno" ] \
    || [ "$(shasum -a 256 "$BIN_DIR/deno" | awk '{print $1}')" != "$DENO_BINARY_SHA256" ]; then
    echo ">>> Downloading deno-aarch64-apple-darwin.zip"
    curl --fail --location --retry 3 --output "$DENO_ARCHIVE" "$DENO_ARCHIVE_URL"
    verify_sha256 "$DENO_ARCHIVE" "$DENO_ARCHIVE_SHA256"
    ditto -x -k "$DENO_ARCHIVE" "$FETCH_DIR/deno-extracted"
    if [ ! -f "$FETCH_DIR/deno-extracted/deno" ]; then
        echo "ERROR: verified Deno archive did not contain deno" >&2
        exit 1
    fi
    verify_sha256 "$FETCH_DIR/deno-extracted/deno" "$DENO_BINARY_SHA256"
    mv -f "$FETCH_DIR/deno-extracted/deno" "$BIN_DIR/deno"
fi
fetch_verified "$DENO_LICENSE_URL" "$LICENSE_DIR/Deno-MIT.txt" "$DENO_LICENSE_SHA256"

chmod 755 "$BIN_DIR/yt-dlp" "$BIN_DIR/deno"
validate_executables
verify_credits_versions

echo "=== Web video tools ready ==="
print_versions
echo "Output:  $TOOLS_DIR"
