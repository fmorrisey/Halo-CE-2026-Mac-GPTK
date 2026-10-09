# CodeWeavers / CrossOver report draft — winegstreamer H.264 output not 2D-buffer-capable on macOS (UE5 Electra black video)

**File at:** CodeWeavers support / bug tracker (https://www.codeweavers.com/support or the CrossOver forum), or email your CrossOver support contact. CrossOver ships the macOS Wine most Mac gamers run and owns the `CW HACK 26265` winegstreamer code, so this is the practical vendor fix in addition to the WineHQ one.

---

**Summary:** On macOS/Apple Silicon (CrossOver + D3DMetal, GPTK 4.0b2), UE5.5 ElectraPlayer H.264 cutscenes render black with audio. winegstreamer's H.264 decoder MFT doesn't give the client a buffer that implements `IMF2DBuffer2`, which Electra requires, so every decoded frame is dropped.

**Details (two parts, both in winegstreamer `dlls/winegstreamer/video_decoder.c`):**
1. The `MFT_OUTPUT_STREAM_PROVIDES_SAMPLES` output path uses `MFCreateMemoryBuffer` (flat) — not a 2D buffer. Electra QIs the frame buffer for `IMF2DBuffer2` (IID `33ae5ea6-4316-436f-8ddd-d73d22f829ec`); the QI fails and the frame is discarded.
2. The `CW HACK 26265` `is_macos()` NV12-censoring in `transform_GetOutputAvailableType` should be gated on "a D3D manager is set," not macOS alone — Electra's software path needs NV12 enumerable. (winevideo's 0005 makes exactly this change.)

**Suggested fix:** On macOS, (a) advertise `MF_SA_D3D_AWARE`/`MF_SA_D3D11_AWARE = FALSE`, (b) provide decoder-owned output samples whose buffers implement `IMF2DBuffer2` (e.g. `MFCreate2DMediaBuffer`), (c) narrow the NV12 censor to the have-D3D-manager case. This matches what real Media Foundation returns and what Electra expects.

**Confirmation:** reproduced and fixed from outside the engine; both a Wine-patch set and an in-process shim make the video appear:
- winevideo (winegstreamer patches 0005/0007): https://github.com/Jfishin/winevideo / issue https://github.com/Jfishin/winevideo/issues/2
- MacGameVideoFix (in-process `IMF2DBuffer2` shim + the fixes this build needed): https://github.com/MathiasKowoll/MacGameVideoFix/issues/6

**Also reported to WineHQ** (winegstreamer) and to Apple (the deeper D3DMetal NV12-texture gap, which would make the winegstreamer workaround unnecessary). Fixing it in CrossOver's winegstreamer flows to GPTK and the Mac wrappers built on it.

**Environment:** CrossOver/WineHQ Wine 10.0, D3DMetal 4.0b2, macOS 26.6.2, Apple Silicon M5 Pro. Repro title: *Halo: Campaign Evolved* (UE 5.5).
