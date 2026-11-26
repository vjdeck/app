Small, two-frame black videos for duration preflight tests (no third-party media).
They have long sample durations, so testing the 30-minute boundary needs no large files.

Generated with FFmpeg:

```sh
ffmpeg -f lavfi -i color=c=black:s=16x16:r=1/900 -t 1800 -c:v mpeg4 -an thirty-minutes.mp4
ffmpeg -f lavfi -i color=c=black:s=16x16:r=1/930 -t 1860 -c:v mpeg4 -an thirty-one-minutes.mkv
```

`delayed-video-thirty-minutes.mp4` has a 29-minute video starting at 61 seconds
and 10 seconds of silent audio starting at zero. The overall timeline is 30:01.

```sh
ffmpeg -copyts -f lavfi -i color=c=black:s=16x16:r=1/870 -f lavfi -i anullsrc=r=8000:cl=mono -filter_complex '[0:v]trim=end=1740,settb=1/1000,setpts=PTS+61000[v];[1:a]atrim=end=10[a]' -map '[v]' -map '[a]' -fps_mode passthrough -enc_time_base:v 1:1000 -c:v libx264 -preset ultrafast -c:a aac -avoid_negative_ts disabled delayed-video-thirty-minutes.mp4
```

`core-red-silent.mp4` and `core-blue-silent.mp4` are short, silent MPEG-4
fixtures for the real player load, seek, EOF, loop, and replacement tests.
`core-long-silent.mp4` runs six seconds so the decoder can fill its queue
without reaching EOF.
Their lack of an audio track keeps these tests independent of output hardware.
`core-green-audio.mp4` adds one second of AAC for cancellation and PCM cache
ownership tests. Those tests install an offline PCM engine and never open an
audio output device. Tests run the built app's bundled FFmpeg 9.0.2 for extraction.

```sh
ffmpeg -nostdin -f lavfi -i color=c=red:s=32x32:r=8:d=0.75 -c:v mpeg4 -q:v 2 -an core-red-silent.mp4
ffmpeg -nostdin -f lavfi -i color=c=blue:s=32x32:r=8:d=0.75 -c:v mpeg4 -q:v 2 -an core-blue-silent.mp4
ffmpeg -nostdin -f lavfi -i color=c=yellow:s=32x32:r=8:d=6 -c:v mpeg4 -q:v 2 -an core-long-silent.mp4
ffmpeg -nostdin -f lavfi -i color=c=green:s=32x32:r=8:d=1 \
  -f lavfi -i sine=frequency=440:sample_rate=44100:duration=1 \
  -c:v mpeg4 -q:v 2 -c:a aac -b:a 64k -shortest core-green-audio.mp4
```
