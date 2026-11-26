# Bundled source notices

These files are tracked so a normal VJDeck build does not depend on a previous
FFmpeg source build under `.ffmpeg-build/`.

| File | Upstream version and source | SHA-256 |
| --- | --- | --- |
| `FFmpeg-LGPL-2.1.txt` | `COPYING.LGPLv2.1` from [FFmpeg 9.0.2](https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz) | `246041b6ecf9bc32d718a62c57877c78b5eb397b6467e74ed7ae2626ab189c30` |
| `dav1d-BSD-2-Clause.txt` | `COPYING` from [dav1d 1.5.1](https://code.videolan.org/videolan/dav1d/-/raw/1.5.1/COPYING) | `b327887de263238deaa80c34cdd2ff3e0ba1d35db585ce14a37ce3e74ee389e9` |
| `Syphon-BSD.txt` | License headers from the checked-in `Frameworks/Syphon.framework/Headers/SyphonServer.h` and `SyphonMetalServer.h` (blank-line whitespace removed) | `2d488394b367687709bc453601f423271d82d4b4d00354ade6b1d9e489aefaee` |

The FFmpeg and dav1d hashes were measured from downloaded upstream files and
matched the corresponding files in the original local source directories. The
Syphon text was copied from the bundled framework's tracked headers.
`scripts/bootstrap.sh` checks the tracked copies. The app bundles these notices, the Signalsmith
licenses already in `Sources/ThirdParty/`, and the web tool licenses fetched by
`scripts/fetch-web-tools.sh`.
