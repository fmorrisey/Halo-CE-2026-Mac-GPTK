# Bug report draft — winegstreamer: decoder error is not propagated, media playback deadlocks

Draft for <https://bugs.winehq.org>. Not yet filed. Component: `winegstreamer`.

---

## Summary

When a GStreamer decoder inside `winegstreamer` fails on an input packet, the
error is never propagated to the application. `wg_transform` blocks
indefinitely waiting for output from a decoder that has already stopped
producing, and the application hangs with no error, no timeout, and no way to
recover.

## Component

`winegstreamer` — specifically the `wg_transform` output path
(`dlls/winegstreamer/wg_transform.c`).

## Environment

Reported honestly, because it is not a stock Wine build:

| | |
|---|---|
| Wine | 10.0 (as reported by the bundled `wine64`) |
| Packaging | Wineskin / Porting Kit wrapper (third-party), **not** upstream Wine |
| Host | macOS 26.6.2 (25G83), Apple M5 Pro |
| Architecture | x86_64 Windows application under Rosetta 2 translation |
| GStreamer | 1.23.90, bundled inside the wrapper |
| Application | Unreal Engine 5.5 title using the Electra media player |

The graphics translation layer in this wrapper has been modified by the
reporter (D3DMetal replaced). **That modification is not implicated**: the
fault reproduces entirely within the media pipeline, is visible in GStreamer's
own debug log, and involves no graphics code. Noted for completeness.

## Expected behaviour

When a decoder fails on an input packet, the error should surface — either as
a `GST_MESSAGE_ERROR` on the bus or as a failure return from the
`wg_transform` read — so that the application can skip the media, fall back,
or report the failure.

## Actual behaviour

The decoder errors. Nothing is propagated. `wg_transform` blocks forever and
the application deadlocks.

## Evidence

From a `GST_DEBUG` capture taken while the application was hung
(`GST_DEBUG=*:2,GST_ELEMENT_FACTORY:4,decodebin:5,GST_PADS:4,GST_STATES:4,GST_EVENT:5,qtdemux:4`):

```
0:00:24.950840834 caps event: video/x-h264, stream-format=(string)byte-stream
                  -> <avdec_h264-2:sink>
0:00:24.951692292 segment event -> <avdec_h264-2:sink>
0:00:24.951721667 tag event     -> <avdec_h264-2:sink>
0:00:24.951770542 ERROR  libav :0:: no frame!
0:00:24.951782000 WARN   videodecoder gstvideodecoder.c:4800:
                         <avdec_h264-2> error: Failed to send data for decoding
0:00:24.951785542 WARN   videodecoder gstvideodecoder.c:4802:
                         <avdec_h264-2> error: Invalid input packet
0:00:24.970932584 caps event: video/x-raw, format=(string)I420 -> videoconvert6
0:00:24.971223625 caps event: video/x-raw, format=(string)NV12 -> sink
0:00:24.971268084 WARN   videopool gstvideopool.c:194:
                         <wgvideobufferpool3> allocation params alignment ...
0:00:24.974819875 WARN   WINE wg_transform.c:970:read_transform_output_video:
                         Copied 3133440 bytes, sample 0x1255260, flags 0x1e
```

The log then stops. Verified static while the application remained hung.

Counts across the full capture:

```
wg_transform video frames read out : 1
errors propagated to the bus       : 0
avdec_h264-0 errors                : 0    (a different, smaller clip decoded fine)
avdec_h264-1 errors                : 0
avdec_h264-2 errors                : 2    (the clip that triggers the hang)
```

A single 3,133,440-byte frame (1920x1088 NV12) was read out, then nothing.

## Process state while hung

From `sample(1)` on the hung process:

```
CPU                      10%        (normal playback is ~250%)
libgstreamer frames      0          pipeline fully torn down
libavcodec frames        0
AGXMetal frames          0          rendering stopped
busiest thread           33/1015    nothing spinning
```

No thread is spinning. Every thread is parked. This is a quiet deadlock, not
a livelock or a slow operation.

## Steps to reproduce

1. Run a Windows application that decodes H.264 media through Media Foundation
   (here, UE5's Electra player).
2. Supply a clip whose packets `avdec_h264` rejects. In this case a 97 MB
   1920x1088 H.264 Main profile Level 4.1 MP4; a 25 MB clip with the same
   codec decodes correctly, so it is content-specific rather than
   codec-specific.
3. The decoder logs `Invalid input packet` and the application hangs
   permanently.

## Secondary observation (possibly a separate bug)

The failing decoder instance receives caps of
`video/x-h264, stream-format=(string)byte-stream, alignment=(string)au`,
while the instances that decode successfully receive
`video/x-h264, stream-format=(string)avc, ..., codec_data=(buffer)014d4029ffe1...`.

Valid `codec_data` is present earlier in the pipeline (H.264 Main profile,
Level 4.1). The `avc` to `byte-stream` conversion losing or mis-placing
SPS/PPS would explain `Invalid input packet`, and may be the underlying cause
of the rejected packet. The deadlock, however, is independent: whatever makes
the packet invalid, a decoder error should not hang the application.

## Workaround

None at the application level. The media files must be renamed so the engine
cannot find them.

## Notes

A second, unrelated hang in the same stack was traced to GStreamer's
`applemedia` plugin (`vtdec_hw` spinning in `gst_vtdec_output_loop`), which is
upstream GStreamer rather than Wine. That one is worked around with
`GST_PLUGIN_FEATURE_RANK=vtdec_hw:NONE,vtdec:NONE`. Applying that workaround
is what exposed the `winegstreamer` deadlock described here.
