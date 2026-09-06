# Evidence

Raw diagnostic data behind the conclusions in [README.md](README.md), kept
separate so the reasoning can be audited or contradicted.

Captured on: Apple M5 Pro, macOS 26.6.2 (25G83), Wine 10.0 under Rosetta 2,
UE 5.5.4 Shipping build, 2026-09-05.

---

## 1. The crash (D3DMetal 2.1)

From `CrashContext.runtime-xml` in the engine's `Saved/Crashes/UECC-*` dump.

```
ErrorMessage         Unhandled Exception: EXCEPTION_ACCESS_VIOLATION
                     reading address 0x0000000000000000
CrashType            Crash
EngineVersion        5.5.4
BuildConfiguration   Shipping
Misc.PrimaryGPUBrand Apple M5 Pro
```

Thread roster — 37 threads captured, exactly one crashed:

```
                 tid=1536   GameThread
                 tid=1656   RHIInterruptThread
                 tid=1660   RHISubmissionThread
  *** CRASHED *** tid=1668  RHIThread
                 tid=1672   RenderThread 0
                 ... 32 more, none crashed
```

Crashed-thread call stack (game frames unsymbolicated — x86_64 under Rosetta):

```
ntdll + f5a4
kernelbase + 73678
kernelbase + 7370e
HaloCampaignEvolved + 370869c
HaloCampaignEvolved + a7d13b7
VCRUNTIME140 + 1a9c0        ← C++ runtime
ntdll + f744 / 45235 / 479de / f776
```

Reproducibility: five dumps over ~40 minutes, `RHIThread` crashed in four;
one variant crashed on `GameThread`.

---

## 2. Ruling out the `MOLTENVKCX` theory

**Hypothesis:** the wrapper is on MoltenVK, so D3DMetal is untested; flip the
renderer before grafting.

**Test:** flip `D3DMETAL 0→1`, `MOLTENVKCX 1→0`, leave libraries at 2.1, and
diff the crash contexts.

**Result — only 6 fields differ, all per-run identifiers:**

| Field | Pre-flip | Post-flip |
|---|---|---|
| `CrashGUID` | `...8CCD4B73...` | `...E9F505F5...` |
| `ExecutionGuid` | `1156832A...` | `5DEE39D6...` |
| `ProcessId` | 916 | 1532 |
| `TimeOfCrash` | 639241821048320000 | 639241844774630000 |
| `PCallStack` | `+ daa7d292` | `+ da9b2292` |
| `PCallStackHash` | `E93E91EB...` | `65FD6ECB...` |

**Every environment field was identical across the flip:**

```
RHI.RHIName      = D3D12
RHI.AdapterName  = AMD Compatibility Mode
RHI.GPUVendor    = AMD
RHI.DeviceId     = 66AF
RHI.FeatureLevel = SM6
RHI.IntegratedGPU= false
```

**The string attribution.** `"AMD Compatibility Mode"` is emitted by
D3DMetal and nothing else:

| Binary | occurrences |
|---|---|
| `D3DMetal.framework/.../D3DMetal` (2.1) | **1** |
| `D3DMetal.framework/.../D3DMetal` (4.0b2) | **1** |
| `libd3dshared.dylib` | 0 |
| `x86_64-windows/d3d12.dll` | 0 |
| `x86_64-windows/dxgi.dll` | 0 |
| `Frameworks/libMoltenVK.dylib` | **0** |

**Conclusion:** D3DMetal was the active renderer before *and* after the flip.
`MOLTENVKCX` steers the Vulkan/MoltenVK path, which a D3D12 title never
enters. The flip was a no-op; the variable was never the renderer.

---

## 3. The prefix DLLs are not DXVK

MD5 comparison, prefix `system32` vs. builtin `lib/wine/x86_64-windows`:

```
d3d11.dll     prefix=665b6c9d8941  builtin=665b6c9d8941  IDENTICAL
d3d12.dll     prefix=1f3ac1c247f6  builtin=1f3ac1c247f6  IDENTICAL
dxgi.dll      prefix=f8360e746809  builtin=f8360e746809  IDENTICAL
winemetal.dll prefix=edf99adf737e  builtin=edf99adf737e  IDENTICAL
```

String markers in the prefix `d3d11.dll`: `D3DMetal`, `Wine builtin`.
DXVK marker count: **0**.

There is no DXVK anywhere in this wrapper.

---

## 4. Post-graft: the video wedge

After the 4.0b2 graft the crash is gone and the game plays, but any `.mp4`
playback hangs the load. A 10-second `sample` of the wedged process (140
threads, 265,262 samples) plus a 5-second `sample` of `wineserver`.

### Thread state distribution

| Threads | State | Verdict |
|---:|---|---|
| 95 | blocked in `NtWaitForMultipleObjects` | idle, waiting correctly |
| 14 | `PSOPrecompilePool #0–13`, all 1907/1907 blocked | **parked, zero compiler frames** |
| 5 | D3DMetal (`D3DMetalWineThread` + 4× `D3DMCommandQueueWorker`), `os_sync_wait_on_address` | idle, awaiting submissions |
| 1 | `vtdechw2:src` in `gst_vtdec_output_loop` | **SPINNING** |
| 1 | `game_MAIN_THREAD`, 550/1907 in `NtUserGetGUIThreadInfo` | polling |

```
total samples = 265,262
running       =   5,025  (1.9%)
blocked       = 260,237  (98.1%)
```

### It is not shader compilation

Frame counts across the entire call graph:

```
MTLCompiler   0
AGXMetal      0
GPUCompiler   0
Metal         0
```

All 14 PSO threads parked, no compiler frames, and RSS flat at 3.6 GB — far
below the 10–20 GB a real UE5 PSO precompile balloons to. Nothing is being
compiled.

### It is not a sync storm

The `wineserver` sample shows its main thread **87% parked** in its own event
loop; ~13% servicing requests. Nothing spinning. The traffic has a single
source — `game_MAIN_THREAD` doing 550 `NtUserGetGUIThreadInfo` →
`wine_server_call` round-trips, a GUI-state poll, not sync-object traffic.

The RHI and D3DMetal threads issue **zero** server calls: with `WINEMSYNC=1`
their waits stay in-process (`os_sync_wait_on_address`). The graphics stack
and `wineserver` load are causally unrelated — so changing the sync backend
(`WINEMSYNC=0 / WINEESYNC=1`) would not address this.

### It is not a dead D3DMetal/winemetal seam

This was the flagged residual risk, and the evidence contradicts it.
D3DMetal 4.0b2 initialised **successfully**:

```
com.apple.D3DMetal (4.0b2 - 4.0b2)     loaded
AGXMetalG17X (353.14)                  loaded   ← MTLDevice created
com.Metal.MappingDispatch              present
MetalFX.framework (31.8)               loaded   ← D3DM_ENABLE_METALFX took
libmetalirconverter / libdxccontainer  loaded
```

Cinematics rendered before the wedge. The four `D3DMCommandQueueWorker`
threads are idle-parked waiting for submissions that never arrive —
downstream victims, not the cause.

### It is the media pipeline

Every Electra thread is blocked while the GStreamer VideoToolbox decoder
spins:

```
vtdechw2:src                   SPINNING  gst_vtdec_output_loop (libgstapplemedia)
ElectraPlayer::Video decoder   blocked
ElectraPlayer::MP4 streamer    blocked
ElectraPlayer::EventDispatch   blocked
ElectraPlayer::SharedWorker    blocked
Electra::ExecAsync             blocked
FMediaTicker                   blocked
```

**Reading:** the decoder wedges, end-of-stream never fires, UE's movie player
never completes, the game thread waits on it, and the renderer idles behind
it. The ~180% CPU is entirely the spinning decoder (~1 core) plus the GUI
poll (~0.6 core).

**Status: open.** The fault is in Wine's GStreamer/Electra stack, not in
D3DMetal. Current workaround is renaming the `.mp4` files out of the way
(`scripts/movies-toggle.sh`). Worth retesting after a Wine or GPTK update.

---

## Method notes

- **Crash contexts beat the Metal HUD.** `RHI.AdapterName` and friends are
  recorded in every dump. The HUD needs a running game and a screenshot; the
  wrapper writes no run log unless `Debug Mode` is on, and UE's `Saved/Logs`
  is empty in a Shipping build.
- **String attribution is decisive** when a config flag's effect is
  ambiguous. Finding which binary emits a value settles which code path ran,
  where reasoning from the flag's name misleads.
- **Diff whole crash contexts, not just call stacks.** The fact that only
  per-run identifiers changed across the renderer flip is what proved the
  flip was a no-op.
- **Under Rosetta, ignore the translated frames.** Deep repeated
  `__wine_syscall_dispatcher` chains are unwind artifacts. The native frames
  (D3DMetal, GStreamer, `libsystem_*`) carry the signal.
