# Headless validation of the video-decode fix (no game launch)

The game's Electra player can't be driven by hand, so to validate the fix
without launching Halo, the H.264 decoder MFT — the exact winegstreamer
transform the game uses — was driven directly by a small Media Foundation
harness (`scratchpad/mfharness/mftest4.c`) under the wrapper's own Wine:

1. Extract the menu-background video's H.264 as an Annex-B elementary stream
   (`ffmpeg -bsf:v h264_mp4toannexb`): 2250 access units, SPS/PPS inline.
2. Feed each access unit as one byte-stream sample via `ProcessInput`.
3. Pull decoded frames via `ProcessOutput`, sizing the output sample from the
   1920x1080 frame = **3,110,400 bytes — exactly how Electra sizes it.**
4. Count frames, stream-changes, and errors per winegstreamer build.

## Result (real patched MFT, Electra-style output buffer)

| build | frames | stream-changes | outcome |
|---|---:|---:|---|
| pristine wine-10.0 | 2250 | **1** | fires MF_E_TRANSFORM_STREAM_CHANGE at frame 0 — the event the game stalls on |
| v5 (no streamheader) | 2250 | **1** | still fires it |
| v6 (suppress caps change) | 0 | 0 | "Output buffer is too small" → error → the game *skips* the video (matches observed behaviour) |
| **v7 (no output align)** | **2250** | **0** | **entire video decoded into the game-sized buffer, no change, no error** |

v7 is the only build that delivers the complete video into the exact buffer
the game allocates, with nothing for Electra to stall on (no stream-change)
and nothing to skip on (no error).

## Why the stream-change is the culprit

The decoder pads 1080 -> 1088 for 16-row alignment, so its NV12 output is
3,133,440 bytes while the client sized its buffer for 1080 = 3,110,400. The
MFT signals a dynamic format change purely to grow that buffer. A correct MF
client reallocates and continues (the harness does, decoding all 2250). The
game's Electra player instead stalls when that mid-stream change fires —
consistent with a render-target reconfiguration deadlock (render thread parked
in `os_sync_wait`, every Electra thread idle).

- v5 keeps the change -> stall (observed in-game).
- v6 suppresses the change but the frame no longer fits -> error -> skip
  (observed in-game: playable menu, no video).
- **v7 removes the padding so the 1080 output fits the 1080 buffer: no size
  change, and with v6's framerate-only caps gate, no caps change either ->
  no format change at all -> the decode loop just runs.**

## Visual correctness

Frame 150 decoded through v7 was dumped as NV12 (3,110,400 bytes — tight 1080,
no padding) and converted to PNG: a clean, correct frame of the opening
cinematic (the Pillar of Autumn over a planet). No corruption, no green strip,
no vertical squash. See `v7-decoded-frame150.png`.

## Status

This validates the decoder + fix end to end: driven exactly as a client drives
it, with the game's buffer size, v7 delivers the full video correctly and is
the unique build that avoids the stall-trigger. Final in-game confirmation
(Electra actually presenting the frames) still requires launching Halo, but
that launch now tests a fix validated against the real MFT rather than a
hypothesis.

The v7 change is one line in `dlls/winegstreamer/wg_transform.c`
(`output_plane_align` forced to 0 at the copy site), layered on v6 (framerate-
only caps-change gate) and v2 (decoder-error reporting). Patch:
`wg_transform-v7-no-align.patch`.
