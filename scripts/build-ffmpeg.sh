#!/bin/bash
set -euo pipefail

# Build FFmpeg shared libraries (dylibs) for macOS arm64
# Output: Frameworks/FFmpeg/{lib,include,bin}
# Install names use @rpath for embedding in VJDeck.app/Contents/Frameworks/
# Dynamic linking satisfies LGPL-2.1 §6(b) (users can replace dylibs).

FFMPEG_VERSION="9.0.2"
FFMPEG_SHA256="8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e"
DAV1D_VERSION="1.5.1"
DAV1D_SHA256="401813f1f89fa8fd4295805aa5284d9aed9bc7fc1fdbe554af4292f64cbabe21"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${FFMPEG_BUILD_DIR:-$PROJECT_DIR/.ffmpeg-build}"
OUTPUT_DIR="${FFMPEG_OUTPUT_DIR:-$PROJECT_DIR/Frameworks}"

if [ "$#" -gt 1 ] || { [ "$#" -eq 1 ] && [ "$1" != "--prepare-sources" ]; }; then
    echo "Usage: $0 [--prepare-sources]" >&2
    exit 2
fi

case "$BUILD_DIR:$OUTPUT_DIR" in
    /*:/*) ;;
    *) echo "ERROR: FFMPEG_BUILD_DIR and FFMPEG_OUTPUT_DIR must be absolute paths" >&2; exit 2 ;;
esac

# FFmpeg configure splits --extra-cflags/--extra-ldflags on whitespace, including
# the dav1d include and library paths derived from BUILD_DIR.
case "$BUILD_DIR" in
    *[[:space:]]*)
        echo "ERROR: FFMPEG_BUILD_DIR must contain no whitespace; set it to an absolute whitespace-free path" >&2
        exit 2
        ;;
esac

echo "=== FFmpeg Shared Library Builder ==="
echo "Version: $FFMPEG_VERSION"
echo "dav1d: $DAV1D_VERSION"
echo "Build dir: $BUILD_DIR"
echo "Output dir: $OUTPUT_DIR"
echo ""

# Prerequisites check
for cmd in curl shasum tar; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: $cmd not found" >&2
        exit 1
    fi
done

# Verify cached archives on every run, then extract fresh source trees. A failed
# or interrupted download never becomes a trusted cache entry.
prepare_source() {
    local NAME=$1 VERSION=$2 URL=$3 EXPECTED_SHA256=$4
    local ARCHIVE="$BUILD_DIR/${NAME}-${VERSION}.tar.xz"
    local SOURCE="$BUILD_DIR/${NAME}-${VERSION}"
    local ACTUAL_SHA256

    if [ ! -f "$ARCHIVE" ]; then
        echo ">>> Downloading ${NAME} ${VERSION}..."
        if ! curl --fail --location --retry 3 --silent --show-error \
            --output "${ARCHIVE}.partial" "$URL"; then
            rm -f "${ARCHIVE}.partial"
            echo "ERROR: could not download $URL" >&2
            exit 1
        fi
        mv "${ARCHIVE}.partial" "$ARCHIVE"
    fi

    ACTUAL_SHA256=$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')
    if [ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]; then
        echo "ERROR: SHA-256 mismatch for $ARCHIVE" >&2
        echo "Expected: $EXPECTED_SHA256" >&2
        echo "Actual:   $ACTUAL_SHA256" >&2
        exit 1
    fi
    echo ">>> Verified ${NAME} ${VERSION}: $ACTUAL_SHA256"

    rm -rf "$SOURCE"
    tar -xf "$ARCHIVE" -C "$BUILD_DIR"
    if [ ! -d "$SOURCE" ]; then
        echo "ERROR: source directory missing from $ARCHIVE" >&2
        exit 1
    fi
}

FFMPEG_TAR="ffmpeg-${FFMPEG_VERSION}.tar.xz"
FFMPEG_URL="https://ffmpeg.org/releases/${FFMPEG_TAR}"
FFMPEG_SRC="$BUILD_DIR/ffmpeg-${FFMPEG_VERSION}"
DAV1D_TAR="dav1d-${DAV1D_VERSION}.tar.xz"
DAV1D_URL="https://downloads.videolan.org/pub/videolan/dav1d/${DAV1D_VERSION}/${DAV1D_TAR}"
DAV1D_SRC="$BUILD_DIR/dav1d-${DAV1D_VERSION}"

mkdir -p "$BUILD_DIR"
prepare_source ffmpeg "$FFMPEG_VERSION" "$FFMPEG_URL" "$FFMPEG_SHA256"
prepare_source dav1d "$DAV1D_VERSION" "$DAV1D_URL" "$DAV1D_SHA256"

if [ "$#" -eq 1 ]; then
    echo ">>> Source preparation complete"
    exit 0
fi

for cmd in nasm pkg-config make meson ninja clang sysctl install_name_tool otool; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: $cmd not found (see docs/ffmpeg-rebuild.md)" >&2
        exit 1
    fi
done

build_dav1d() {
    local ARCH=$1
    local PREFIX="$BUILD_DIR/dav1d-install-$ARCH"
    local BUILD="$BUILD_DIR/dav1d-build-$ARCH"
    local CROSS_FILE="$BUILD_DIR/dav1d-$ARCH.ini"

    echo ">>> Building static dav1d for $ARCH..."
    rm -rf "$BUILD" "$PREFIX"
    cat > "$CROSS_FILE" <<CROSS_FILE
[binaries]
c = 'clang'
ar = 'ar'
strip = 'strip'

[built-in options]
c_args = ['-arch', '$ARCH', '-mmacosx-version-min=13.0']
c_link_args = ['-arch', '$ARCH', '-mmacosx-version-min=13.0']
default_library = 'static'

[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = '$ARCH'
endian = 'little'
CROSS_FILE

    meson setup "$BUILD" "$DAV1D_SRC" \
        --cross-file "$CROSS_FILE" \
        --prefix "$PREFIX" --libdir lib --buildtype release \
        --default-library static \
        -Denable_tools=false -Denable_examples=false \
        -Denable_tests=false -Denable_docs=false
    meson compile -C "$BUILD" -j "$(sysctl -n hw.ncpu)"
    meson install -C "$BUILD"

    if [ ! -f "$PREFIX/lib/libdav1d.a" ] || [ ! -f "$PREFIX/lib/pkgconfig/dav1d.pc" ]; then
        echo "ERROR: dav1d static library or pkg-config file missing under $PREFIX" >&2
        exit 1
    fi
}

# Common configure flags
COMMON_FLAGS=(
    --disable-static
    --enable-shared
    --install-name-dir=@rpath
    --disable-ffplay
    --disable-ffprobe
    --disable-doc
    --disable-htmlpages
    --disable-manpages
    --disable-podpages
    --disable-txtpages
    --disable-network
    --disable-autodetect
    --disable-debug
    --enable-pic
    --enable-videotoolbox
    --enable-audiotoolbox

    # Decoders
    --disable-decoders
    --enable-decoder=h264
    --enable-decoder=hevc
    --enable-decoder=vp8
    --enable-decoder=vp9
    --enable-decoder=av1
    --enable-libdav1d
    --enable-decoder=libdav1d
    --enable-decoder=mpeg4
    --enable-decoder=msmpeg4v1
    --enable-decoder=msmpeg4v2
    --enable-decoder=msmpeg4v3
    --enable-decoder=mpeg1video
    --enable-decoder=mpeg2video
    --enable-decoder=mjpeg
    --enable-decoder=theora
    --enable-decoder=h263
    --enable-decoder=flv
    --enable-decoder=rawvideo
    --enable-decoder=prores
    --enable-decoder=dvvideo
    --enable-decoder=huffyuv
    --enable-decoder=ffv1
    --enable-decoder=indeo4
    --enable-decoder=indeo5
    --enable-decoder=wmv1
    --enable-decoder=wmv2
    --enable-decoder=wmv3
    --enable-decoder=vc1
    --enable-decoder=cinepak
    --enable-decoder=indeo3
    --enable-decoder=msvideo1
    --enable-decoder=aac
    --enable-decoder=mp3
    --enable-decoder=opus
    --enable-decoder=vorbis
    --enable-decoder=flac
    --enable-decoder=pcm_s16le
    --enable-decoder=pcm_f32le
    --enable-decoder=wmav1
    --enable-decoder=wmav2
    --enable-decoder=wmapro
    --enable-decoder=adpcm_ms
    --enable-decoder=adpcm_ima_wav
    --enable-decoder=dca
    --enable-decoder=ac3
    --enable-decoder=eac3
    --enable-decoder=truehd

    # HW acceleration
    --enable-hwaccel=h264_videotoolbox
    --enable-hwaccel=hevc_videotoolbox

    # Demuxers
    --disable-demuxers
    --enable-demuxer=matroska
    --enable-demuxer=avi
    --enable-demuxer=mov
    --enable-demuxer=flv
    --enable-demuxer=ogg
    --enable-demuxer=asf
    --enable-demuxer=mpegts
    --enable-demuxer=mpegps
    --enable-demuxer=mpegvideo
    --enable-demuxer=rawvideo
    --enable-demuxer=wav
    --enable-demuxer=mp3
    --enable-demuxer=aac
    --enable-demuxer=flac

    # Muxers (minimal, for remux)
    --disable-muxers
    --enable-muxer=mp4
    --enable-muxer=ipod
    --enable-muxer=matroska
    --enable-muxer=wav

    # Encoders (minimal, for audio extraction)
    --disable-encoders
    --enable-encoder=aac
    --enable-encoder=pcm_f32le

    # Protocols
    --disable-protocols
    --enable-protocol=file
    --enable-protocol=pipe

    # Parsers
    --disable-parsers
    --enable-parser=h264
    --enable-parser=hevc
    --enable-parser=vp8
    --enable-parser=vp9
    --enable-parser=av1
    --enable-parser=mpeg4video
    --enable-parser=aac
    --enable-parser=opus
    --enable-parser=vorbis
    --enable-parser=flac
    --enable-parser=mpegaudio
    --enable-parser=dca
    --enable-parser=ac3

    # Filters (minimal — aresample needed for sample-format conversion during audio transcode,
    # e.g. FLAC s16 / MP3 s16p / Opus flt / PCM / ADPCM → AAC fltp)
    --disable-filters
    --enable-filter=aresample
    --enable-filter=anull
    --enable-filter=aformat

    # BSFs
    --disable-bsfs
    --enable-bsf=h264_mp4toannexb
    --enable-bsf=hevc_mp4toannexb
    --enable-bsf=aac_adtstoasc

    # Misc
    --enable-swscale
    --enable-swresample
    --disable-avdevice
)

build_arch() {
    local ARCH=$1
    local PREFIX="$BUILD_DIR/install-$ARCH"
    local BUILD="$BUILD_DIR/build-$ARCH"

    echo ""
    echo ">>> Building FFmpeg for $ARCH..."

    rm -rf "$BUILD" "$PREFIX"
    mkdir -p "$BUILD"
    cd "$BUILD"

    local EXTRA_CFLAGS=""
    local EXTRA_LDFLAGS=""

    local DAV1D_PREFIX="$BUILD_DIR/dav1d-install-$ARCH"
    local PKG_CONFIG_LIBDIR="$DAV1D_PREFIX/lib/pkgconfig"
    local PKG_CONFIG_PATH=""
    local PKG_CONFIG_SYSROOT_DIR=""
    local PKG_CONFIG_DIR=""
    export PKG_CONFIG_LIBDIR PKG_CONFIG_PATH PKG_CONFIG_SYSROOT_DIR PKG_CONFIG_DIR

    if [ "$(pkg-config --modversion dav1d)" != "$DAV1D_VERSION" ] || \
       [ "$(pkg-config --variable=prefix dav1d)" != "$DAV1D_PREFIX" ]; then
        echo "ERROR: pkg-config did not resolve isolated dav1d $DAV1D_VERSION in $DAV1D_PREFIX" >&2
        exit 1
    fi

    if [ "$ARCH" = "arm64" ]; then
        EXTRA_CFLAGS="-arch arm64"
        EXTRA_LDFLAGS="-arch arm64"
    else
        EXTRA_CFLAGS="-arch x86_64"
        EXTRA_LDFLAGS="-arch x86_64"
    fi

    "$FFMPEG_SRC/configure" \
        --prefix="$PREFIX" \
        --arch=$ARCH \
        --target-os=darwin \
        --extra-cflags="$EXTRA_CFLAGS -mmacosx-version-min=13.0 -I$DAV1D_PREFIX/include" \
        --extra-ldflags="$EXTRA_LDFLAGS -mmacosx-version-min=13.0 -L$DAV1D_PREFIX/lib" \
        --cc="clang" \
        "${COMMON_FLAGS[@]}"

    make -j$(sysctl -n hw.ncpu)
    make install

    echo ">>> $ARCH build complete: $PREFIX"
}

# Normalize dylib names + install_names so the app embeds them
# as @rpath/libfoo.dylib (no SONAME version suffix in the filename).
# Also rewrites inter-library deps and the ffmpeg CLI binary.
normalize_dylibs() {
    local PREFIX=$1
    local LIBS_LOCAL=(libavcodec libavformat libavfilter libavutil libswresample libswscale)

    echo ""
    echo ">>> Normalizing dylib install_names (rpath)..."

    # Step 1: rename real dylibs to unversioned filenames, delete SONAME symlinks
    for lib in "${LIBS_LOCAL[@]}"; do
        local REAL
        REAL=$(find "$PREFIX/lib" -maxdepth 1 -type f -name "${lib}.*.dylib" | head -n1)
        if [ -z "$REAL" ]; then
            echo "ERROR: ${lib} dylib not found under $PREFIX/lib"
            exit 1
        fi
        # Remove any existing unversioned file/symlink, then move real dylib there
        rm -f "$PREFIX/lib/${lib}.dylib"
        mv "$REAL" "$PREFIX/lib/${lib}.dylib"
        # Delete residual SONAME symlinks (libfoo.61.dylib etc.)
        find "$PREFIX/lib" -maxdepth 1 -name "${lib}.*.dylib" -delete 2>/dev/null || true
        # Set install ID
        install_name_tool -id "@rpath/${lib}.dylib" "$PREFIX/lib/${lib}.dylib"
    done

    # Step 2: rewrite inter-library references (each FFmpeg dylib may depend on the others)
    for lib in "${LIBS_LOCAL[@]}"; do
        local DYLIB="$PREFIX/lib/${lib}.dylib"
        otool -L "$DYLIB" | tail -n +2 | awk '{print $1}' | while read -r dep; do
            local base
            base=$(basename "$dep")
            for target in "${LIBS_LOCAL[@]}"; do
                if [[ "$base" == ${target}.*.dylib || "$base" == "${target}.dylib" ]]; then
                    install_name_tool -change "$dep" "@rpath/${target}.dylib" "$DYLIB"
                fi
            done
        done
    done

    # Step 3: fix ffmpeg CLI — rewrite its FFmpeg dylib refs + add rpath
    local FFMPEG_BIN="$PREFIX/bin/ffmpeg"
    if [ -x "$FFMPEG_BIN" ]; then
        otool -L "$FFMPEG_BIN" | tail -n +2 | awk '{print $1}' | while read -r dep; do
            local base
            base=$(basename "$dep")
            for target in "${LIBS_LOCAL[@]}"; do
                if [[ "$base" == ${target}.*.dylib || "$base" == "${target}.dylib" ]]; then
                    install_name_tool -change "$dep" "@rpath/${target}.dylib" "$FFMPEG_BIN"
                fi
            done
        done
        # When CLI lives at VJDeck.app/Contents/Resources/ffmpeg,
        # @executable_path/../Frameworks resolves to Contents/Frameworks/.
        install_name_tool -add_rpath "@executable_path/../Frameworks" "$FFMPEG_BIN" 2>/dev/null || true
    fi
}

# Build arm64 only (Apple Silicon)
build_dav1d arm64
build_arch arm64
normalize_dylibs "$BUILD_DIR/install-arm64"

# Stage arm64-only output as the install dir (no lipo needed for single-arch)
echo ""
echo ">>> Staging arm64 shared libraries..."

UNIVERSAL_DIR="$BUILD_DIR/install-universal"
LIBS=(libavcodec libavformat libavfilter libavutil libswresample libswscale)

rm -rf "$UNIVERSAL_DIR"
mkdir -p "$UNIVERSAL_DIR/lib"
cp -R "$BUILD_DIR/install-arm64/include" "$UNIVERSAL_DIR/include"

for lib in "${LIBS[@]}"; do
    cp "$BUILD_DIR/install-arm64/lib/$lib.dylib" "$UNIVERSAL_DIR/lib/$lib.dylib"
done

# Create framework directory structure (vendored as dylib bundle)
echo ""
echo ">>> Creating FFmpeg framework bundle..."

FRAMEWORK_DIR="$OUTPUT_DIR/FFmpeg"
rm -rf "$FRAMEWORK_DIR"
mkdir -p "$FRAMEWORK_DIR/lib"
mkdir -p "$FRAMEWORK_DIR/include"
mkdir -p "$FRAMEWORK_DIR/bin"
cp "$BUILD_DIR/install-arm64/bin/ffmpeg" "$FRAMEWORK_DIR/bin/ffmpeg"
chmod +x "$FRAMEWORK_DIR/bin/ffmpeg"

cp "$UNIVERSAL_DIR/lib/"*.dylib "$FRAMEWORK_DIR/lib/"
cp -R "$UNIVERSAL_DIR/include/"* "$FRAMEWORK_DIR/include/"

# dav1d is absorbed into libavcodec.dylib via static linking during FFmpeg shared build.
# No separate libdav1d shipped — dav1d's BSD-2-Clause license permits static absorption.

# Create module map for Swift bridging
cat > "$FRAMEWORK_DIR/include/module.modulemap" << 'MODULEMAP'
module FFmpeg [system] {
    header "libavcodec/avcodec.h"
    header "libavformat/avformat.h"
    header "libavutil/avutil.h"
    header "libavutil/hwcontext.h"
    header "libavutil/hwcontext_videotoolbox.h"
    header "libavutil/imgutils.h"
    header "libavutil/opt.h"
    header "libavutil/pixdesc.h"
    header "libavutil/channel_layout.h"
    header "libavutil/samplefmt.h"
    header "libswscale/swscale.h"
    header "libswresample/swresample.h"
    link "z"
    link "bz2"
    link "lzma"
    link "iconv"
    export *
}
MODULEMAP

echo ""
echo "=== Build complete ==="
echo "Output: $FRAMEWORK_DIR"
echo ""
echo "Libraries:"
ls -lh "$FRAMEWORK_DIR/lib/"
echo ""
echo "ffmpeg CLI dylib references:"
otool -L "$FRAMEWORK_DIR/bin/ffmpeg" | head -20
echo ""
echo "Total size:"
du -sh "$FRAMEWORK_DIR"
echo ""
echo "Next steps:"
echo "  1. xcodegen generate"
echo "  2. xcodebuild -project VJDeck.xcodeproj -scheme VJDeck -configuration Debug build"
