# WineHQ Bugzilla draft — winegstreamer H.264 MFT: provide IMF2DBuffer2 system-memory samples on macOS

**File at:** https://bugs.winehq.org (needs a WineHQ account). Product: Wine, Component: winegstreamer.
**Also acceptable:** a merge request at https://gitlab.winehq.org/wine/wine (patch attached below; needs maintainer build/test — see caveat).

---

**Summary:** On macOS, UE5 ElectraPlayer (and other direct-`IMFTransform` H.264 clients) get black video with working audio because winegstreamer's H.264 decoder MFT never produces an output buffer that implements `IMF2DBuffer`/`IMF2DBuffer2`. The client queries the decoded sample's buffer for `IMF2DBuffer2`, the QI fails, and every frame is dropped.

**Version:** Reproduced on Wine 10.0 (`Sikarugir`), x86_64, running under Apple's Game Porting Toolkit (D3DMetal, D3D12→Metal) on Apple Silicon via Porting Kit/Wineskin.

**How to reproduce:** Play an H.264 cutscene in a UE 5.5 game that uses ElectraPlayer (e.g. *Halo: Campaign Evolved*). Audio plays; video is black. The MF H.264 decoder decodes NV12 frames fine (confirmed: an `IMFSourceReader`/direct-MFT harness decodes all frames), but ElectraPlayer's `FElectraDecoderOutputVideo` path does:
```
buffer->QueryInterface(IID_IMF2DBuffer2, ...)   // fails
```
and discards the frame.

**Root cause / analysis:**
- In `dlls/winegstreamer/video_decoder.c`, `transform_ProcessOutput` on the `MFT_OUTPUT_STREAM_PROVIDES_SAMPLES` path allocates the output buffer with **`MFCreateMemoryBuffer`** (~line 944, Wine 10.0) — a plain 1D buffer that does **not** implement `IMF2DBuffer`/`IMF2DBuffer2`.
- When the client allocates the buffer (no PROVIDES_SAMPLES), it's also a plain buffer.
- UE Electra (and Windows' real `CMSH264DecoderMFT`, which returns DXGI/2D buffers) require a 2D-capable buffer. So on macOS/software output, Electra never accepts a frame.
- Related: on macOS the decoder also shouldn't advertise `MF_SA_D3D_AWARE`/`MF_SA_D3D11_AWARE` (no backend can make NV12 D3D11 textures) — otherwise clients build a D3D path and demand `IMFDXGIBuffer`, which system-memory samples can't satisfy. (This is the `is_macos()`/`CW HACK 26265` area.)

**Proposed fix:** On macOS, have the H.264 (and VP9) decoder provide its own output samples whose buffers implement `IMF2DBuffer2` — e.g. allocate via `MFCreate2DMediaBuffer(width, height, fourcc, FALSE, &buffer)` instead of `MFCreateMemoryBuffer` on the PROVIDES_SAMPLES path, and advertise `MF_SA_D3D*_AWARE = FALSE` on macOS. This mirrors the shape real Media Foundation returns.

**Prior art / confirmation this is the fix:** two community projects work around exactly this from outside Wine:
- winevideo patches 0005 (no D3D awareness on macOS) + 0007 (provide samples on macOS): https://github.com/Jfishin/winevideo
- MacGameVideoFix's in-process shim substitutes an `IMF2DBuffer2` over the flat buffer: https://github.com/MathiasKowoll/MacGameVideoFix/issues/6
Both make the video appear. Fixing it in winegstreamer makes every downstream (CrossOver, GPTK, Gcenx, Porting Kit, Kegworks, Whisky) get it for free.

**Patch:** a Wine-10.0 port of the D3D-awareness half is attached (`patches/winegstreamer-ue5-electra-2dbuffer-macos.patch`). The 2D-buffer half (MFCreate2DMediaBuffer substitution in ProcessOutput) still needs to be written against current Wine and build-tested — I couldn't build a working winegstreamer.dll locally (a self-built Wine-10.0 dll faults in ntdll under both mingw GCC 16.2.0 and llvm-mingw clang 23; only the distro's GCC-15.2.0 build loads). Happy to test a maintainer build.
