# Halo: Campaign Evolved (UE5.5 Electra) — black video cutscenes under Porting Kit / D3DMetal

Report + patch for maintainers of [winevideo](https://github.com/Jfishin/winevideo)
and [MacGameVideoFix](https://github.com/MathiasKowoll/MacGameVideoFix).

## Summary

Cutscenes play audio but render **black** (one decoded frame delivered, then the
pipeline back-pressures to a stop). This is the known UE5 ElectraPlayer
`IMF2DBuffer` rejection, but on a **Porting Kit / Wineskin** wrapper rather than
CrossOver, and on a **Halo-specific Electra build** that both existing fixes miss.

## Environment

| | |
|---|---|
| Game | Halo: Campaign Evolved (internal UE project "Meteorite"), `HaloCampaignEvolved.exe` (~230 MB, monolithic Shipping) |
| Engine | UE 5.5, **ElectraPlayer** + MediaCompositing (Sequencer media tracks). No WmfMedia plugin shipped. |
| Cutscene | H.264 Main, 1920×822, yuv420p 8-bit + AAC-LC, faststart. Decoder outputs 1920×832 NV12. |
| Wrapper | Porting Kit / Wineskin (`CFBundleVersion 3.0.6_2`), **stock WineHQ `wine-10.0 (Sikarugir)`** (`org.winehq.wine`) |
| GPU layer | Apple GPTK **D3DMetal 4.0b2** (`PROJECT:D3DMetal-4.0b2`), D3D12→Metal, Apple Silicon M5 Pro, macOS 26.6.2, Rosetta x86_64 |

## Root cause (confirmed)

Electra rejects every decoded video frame whose output buffer does not implement
`IMF2DBuffer`. With `winegstreamer` delivering NV12 in a flat system-memory
buffer, Electra takes one frame, cannot `QueryInterface(IMF2DBuffer)` / `Lock2D`,
drops it, and the decode pipeline stalls. Audio is a separate path, so it keeps
playing over a frozen black first frame.

Confirmed in-game: decoder delivers exactly one `read_transform_output_video:
Copied 2396160 bytes` (1920×832 NV12, system memory via `release_memory_sample`),
then zero further frames while the title stays responsive (skippable cinematic).

## What worked / partially worked here

- **D3D-awareness off** (binary-patched the stock dll: `MF_SA_D3D_AWARE` /
  `MF_SA_D3D11_AWARE` TRUE→FALSE at both create sites) moved the title from a
  **hard RenderThread hang** → audio + cinematic running + one system-memory
  frame. Necessary but not sufficient.

## What did NOT work, and why (the two gaps worth fixing upstream)

### 1. winevideo patches 0005+0007 can't be built for this wrapper

Ported 0005 (`MF_SA_D3D_AWARE=!is_macos()`, refuse the D3D manager) and 0007
(always `MFT_OUTPUT_STREAM_PROVIDES_SAMPLES` on macOS) to Wine 10.0 cleanly —
see `patches/winegstreamer-ue5-electra-2dbuffer-macos.patch`. Two findings:

- **Vanilla Wine 10.0 `transform_ProcessOutput` uses `MFCreateMemoryBuffer`
  (flat) on the `PROVIDES_SAMPLES` path, not a 2D buffer.** So 0005+0007 alone
  are insufficient on 10.0 — a `MFCreate2DMediaBuffer` substitution (or the
  allocator's 2D buffer) is also needed. CrossOver's tree evidently already
  does this; worth confirming the 10.0 vs 11.0 difference for a Wine-upstream
  submission.
- **A self-built `winegstreamer.dll` is ABI-incompatible with this wrapper's
  wine core.** Even a *pristine* 10.0 rebuild page-faults inside `ntdll.dll`
  (the PE↔unix `__wine_unix_call` dispatch), identically at `-O0` and `-O2`.
  The wrapper's dll was built with **mingw GCC 15.2.0**; the only toolchain
  available here is **GCC 16.2.0**. The `.so` stays compatible; the PE dll does
  not. A working build needs Porting Kit's exact wine toolchain. **This is the
  blocker for shipping a winegstreamer-side fix on Porting Kit** — a prebuilt
  pair (or a documented toolchain) for Wineskin/Porting Kit wine 10.0 would
  unblock every UE5 Electra title on that platform, not just this one.

### 2. MGVF's in-process shim crashes on this Electra build

`libogg_64_electra.dll` proxy installs cleanly (exports verified, Ogg ABI
stable) and hooks all 8 MFT vtable slots. But:

- Its software-path binary patch doesn't match our Electra:
  `IsSoftware (sw value): bytes are 30 48 8D, expected FF 50 28 -- different
  build, leaving it alone` (and the outer gate: `B0 00 00` vs `FF 50 28`).
- Even with `Electra.Win.H264UseOldOutputPath=1` in
  `Saved/Config/Windows/Engine.ini` (read-only) to force the software path
  config-side, the shim's 2D-buffer handling **corrupts the RHIThread**:
  `EXCEPTION_ACCESS_VIOLATION writing address 0x1790178018031801` (garbage =
  pixel data walked as a pointer; wrong pitch/frame-size for this build). Crash
  dump `UECC-Windows-8C00A9DE…`, PCallStackHash `8E8D9906F8488EE6929A5D021D462622ECF24130`.

Likely needs this Halo build's correct software-gate offset/pattern and the
correct NV12 pitch (our decoder outputs tight 1920 stride for a 1920×822 frame
padded to 832).

## Asks

1. **winevideo**: a Wineskin/Porting-Kit (stock WineHQ 10.0) build target for the
   patched `winegstreamer` pair, or a documented toolchain (GCC 15.2.0) so the
   pair can be built ABI-compatibly. Plus confirm the 10.0 `ProcessOutput`
   2D-buffer gap above.
2. **MacGameVideoFix**: support for this Halo Electra build — the `IsSoftware`
   gate pattern (`30 48 8D` / `B0 00 00`) and the NV12 pitch for 1920×822→832.
3. Add **Halo: Campaign Evolved** to the compatibility tables either way.

## Config lever that IS build-agnostic and does belong in the per-game setup

```
# %LOCALAPPDATA%\Meteorite\Saved\Config\Windows\Engine.ini  (make read-only)
[SystemSettings]
Electra.Win.H264UseOldOutputPath=1
Electra.Win.H265UseOldOutputPath=1
```
This forces Electra's old/software output path without binary-patching Electra
(the per-build patch that failed here). It still requires a 2D-buffer provider.
