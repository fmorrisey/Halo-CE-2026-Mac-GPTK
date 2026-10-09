# Halo: Campaign Evolved — working video cutscenes under Porting Kit / D3DMetal ✅

**Status: SOLVED.** Menu background video + campaign cutscenes render (confirmed
2026-10-09, M5 Pro, D3DMetal 4.0b2, Porting Kit/Wineskin stock WineHQ 10.0).

## The complete working recipe

Four things together:

1. **winegstreamer v8** (D3D_AWARE=FALSE). The stock dll binary-patched so the
   H.264 MFT reports `MF_SA_D3D_AWARE`/`MF_SA_D3D11_AWARE = FALSE` (4 bytes flipped
   at both create sites). Keeps decode on the system-memory path, no hard hang.
   → `~/Desktop/winegstreamer.dll.v8-d3daware-false` (md5 8cf273c0).

2. **Engine.ini CVar** (forces Electra's software output path), read-only so UE
   can't delete it:
   ```
   %LOCALAPPDATA%\Meteorite\Saved\Config\Windows\Engine.ini
   [SystemSettings]
   Electra.Win.H264UseOldOutputPath=1
   Electra.Win.H265UseOldOutputPath=1
   ```

3. **The in-process shim** = MacGameVideoFix's `electra-h264-fix.c` with TWO
   edits for this Halo build (`electra-h264-fix-halo.c` here), built as a
   `libogg_64.dll` proxy (standalone PE, GCC 16 is fine), installed into
   `…/Halo Campaign Evolved/Engine/Binaries/ThirdParty/Ogg/Win64/VS2015/`:

   - **Edit A — stop the crash.** The stock shim's "force software path" code does
     `int *cvar = *(int**)(base + RVA_CVAR_PTR); cvar[0]=1; cvar[1]=1;` with a
     hardcoded RVA for *its* Electra build. On this Halo build that RVA reads a
     garbage pointer (`0x1790178018031801`) and the unconditional write faults the
     RHIThread. **Disabled the in-memory poke** (we set the CVar via Engine.ini,
     item 2, instead).
   - **Edit B — make Electra accept the frame.** UE 5.5 Electra QIs the output
     buffer for **`IMF2DBuffer2`**, not just `IMF2DBuffer`. The stock shim only
     answers `IMF2DBuffer` (10-method vtable), so the QI failed and the frame was
     dropped. **Added `IMF2DBuffer2`** (IID `33ae5ea6-…`) to the buffer's QI and a
     12-method `two_d` vtable with `Lock2DSize`/`Copy2DTo`.

   Log proof: `gave Electra an IMF2DBuffer over its own buffer (1920x1080, pitch 1920)`.

## Install
```
# shim
cd "…/Halo Campaign Evolved/Engine/Binaries/ThirdParty/Ogg/Win64/VS2015"
mv libogg_64.dll libogg_64_real.dll
cp <this repo>/halo-electra-fix/libogg_64_halo-electra-fix.dll libogg_64.dll
# CVar: drop Engine.ini (item 2), chmod 444
# winegstreamer: v8 dll already in place
```
Undo: restore `libogg_64_real.dll` → `libogg_64.dll`, delete Engine.ini.

## Why the "clean" winegstreamer-only fix wasn't usable here
The winevideo 0005+0007 source patch is correct, but a winegstreamer.dll built
on this Mac (GCC 16 *or* clang 23) faults in the wrapper's `ntdll` — it needs
Porting Kit's exact GCC-15.2.0 wine build, which isn't reproducible locally. The
in-process shim sidesteps that (standalone PE, no wine-builtin ABI). Both routes
reach the same place: Electra gets a system-memory `IMF2DBuffer2` frame.
