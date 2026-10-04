# Grafting a newer D3DMetal into a Porting Kit / Wineskin wrapper

Swapping the Game Porting Toolkit graphics-translation layer inside a
Porting Kit wrapper to fix a crash the shipped version could not survive —
and the diagnostic trail that got there.

**Case study:** a UE 5.5 DirectX 12 title crashing on `RHIThread` at startup
under D3DMetal 2.1. Grafting in Apple's GPTK 4.0 beta 2 D3DMetal fixed it.
The game now reaches the main menu and plays.

---

## ⚠️ Read this first

- **This is unsupported.** You are replacing the graphics translation layer
  inside an app bundle with libraries from a **beta** toolkit. Nobody
  supports the result — not Apple, not CodeWeavers, not Porting Kit, not the
  game's developer.
- **No Apple binaries are in this repository, and none may be added.**
  Apple's GPTK license does not permit redistributing D3DMetal. These scripts
  operate on a redist **you** download from Apple with your own developer
  account. A pre-commit hook enforces this — see
  [`scripts/check-no-binaries.sh`](../scripts/check-no-binaries.sh).
- **Back up before you touch anything.** `scripts/backup-wrapper.sh` exists
  for this and the overlay refuses to run without it.
- **A beta translation layer can regress things that used to work.** It did
  here: see [Known issues](#known-issues).

---

## Prerequisites

| Requirement | Notes |
|---|---|
| Apple Silicon Mac | Developed on an M5 Pro, macOS 26.6.2 |
| Apple Developer account | Needed to download the GPTK |
| **Game Porting Toolkit redist** | "Evaluation environment for Windows games". Mount the outer `.dmg`, then the **inner** `.dmg` inside it — that inner volume is the one with `redist/lib/`. |
| A Porting Kit / Wineskin wrapper | Must already use a D3DMetal-capable engine (a `lib/external/D3DMetal.framework` must already exist). This grafts a **newer** D3DMetal in; it does not add D3DMetal to a wrapper that never had it. |
| Command-line tools | `ditto`, `codesign`, `PlistBuddy`, `tar` — all stock macOS. |

Confirm the redist layout before starting:

```
/Volumes/<GPTK volume>/redist/lib/
├── external/
│   ├── D3DMetal.framework/
│   └── libd3dshared.dylib
└── wine/
    ├── x86_64-unix/       (.so symlinks -> ../../external/libd3dshared.dylib)
    └── x86_64-windows/    (d3d11.dll, d3d12.dll, dxgi.dll, ...)
```

If it does not look like this, **stop.** The scripts refuse rather than guess.

---

## Configuration

Everything machine-specific is a variable. Set these once per shell:

```bash
export WRAPPER_APP="/Applications/Ported Games/<Wrapper>.app"
export GPTK_VOLUME="/Volumes/Evaluation environment for Windows games 4.0 beta 2"
export BACKUP_DIR="$HOME/Desktop"
```

The worked example from development:

```bash
export WRAPPER_APP="/Applications/Ported Games/Halo CE 2026.app"
export GPTK_VOLUME="/Volumes/Evaluation environment for Windows games 4.0 beta 2"
```

---

## The problem

A UE 5.5 DX12 title in a Porting Kit wrapper crashed within seconds of
launch, every time:

```
ErrorMessage    Unhandled Exception: EXCEPTION_ACCESS_VIOLATION
                reading address 0x0000000000000000
Crashed thread  RHIThread
Engine          UE 5.5.4, Shipping
```

`RHIThread` is Unreal's render-hardware-interface thread — the one that talks
to D3D12. A null dereference there points at the D3D→Metal translation layer,
not at game logic.

---

## Diagnosis

The useful part of this project is not the file copying. It is the chain of
evidence, because **two plausible theories were both wrong**, and the crash
dump settled it. Full detail in [EVIDENCE.md](EVIDENCE.md).

### 1. The `MOLTENVKCX` red herring

The wrapper's `Info.plist` had:

```
D3DMETAL   = 0        ← D3DMetal "off"
MOLTENVKCX = 1        ← MoltenVK path "on"
```

The obvious reading: the wrapper is on MoltenVK/DXVK, so D3DMetal was never
being exercised and the graft is pointless until the renderer is flipped.

**That reading was wrong.** Flipping `D3DMETAL=1 / MOLTENVKCX=0` changed
*nothing* — the crash was byte-for-byte identical. Diffing the crash contexts
from before and after the flip showed only 6 differing fields, every one a
per-run identifier (`CrashGUID`, `ProcessId`, `TimeOfCrash`, ...). Every
environment field was unchanged, including:

```
RHI.RHIName     = D3D12
RHI.AdapterName = AMD Compatibility Mode
RHI.GPUVendor   = AMD
RHI.DeviceId    = 66AF
```

`"AMD Compatibility Mode"` is the tell. That exact string appears **only** in
`D3DMetal.framework` — it is absent from `libMoltenVK.dylib` and from every
PE-side DLL:

```bash
strings -a .../D3DMetal.framework/Versions/A/D3DMetal | grep -c "AMD Compatibility Mode"   # 1
strings -a .../Frameworks/libMoltenVK.dylib          | grep -c "AMD Compatibility Mode"   # 0
```

**D3DMetal was the active renderer the entire time.** `MOLTENVKCX` steers the
Vulkan path, which a D3D12 title never touches. The crash was always
D3DMetal's.

### 2. The byte-identical prefix DLLs

The wrapper carries two copies of `d3d11/d3d12/dxgi.dll`: builtin ones in
`lib/wine/x86_64-windows/`, and another set in the Wine prefix's
`system32`/`syswow64`. It would be easy to assume the prefix set is DXVK
overriding the builtins.

They are the same files:

```
d3d11.dll     prefix=665b6c9d8941  builtin=665b6c9d8941  IDENTICAL
d3d12.dll     prefix=1f3ac1c247f6  builtin=1f3ac1c247f6  IDENTICAL
dxgi.dll      prefix=f8360e746809  builtin=f8360e746809  IDENTICAL
winemetal.dll prefix=edf99adf737e  builtin=edf99adf737e  IDENTICAL
```

Zero DXVK strings in them; they carry `D3DMetal` and `Wine builtin` markers.
There is no DXVK in this wrapper at all. Backed up anyway
([manifest](MANIFEST-prefix-system32-v2.1.txt)) so rollback is total.

### 3. Dating the version island

`ls -l` on the builtin directory separates the GPTK files from the base Wine
build cleanly:

```
d3d11.dll     110592  Jan 22  2025   ← GPTK 2.1 island
d3d12.dll      77824  Jan 22  2025   ← GPTK 2.1
dxgi.dll       69632  Jan 22  2025   ← GPTK 2.1
d3d10.dll     270350  Oct 27  2025   ← base Wine
winemetal.dll  36878  Oct 27  2025   ← base Wine
```

That date split defines exactly which files the graft may touch. The 32-bit
`i386-windows` tree is entirely Oct 2025 — never GPTK — so it is left alone.

---

## The graft

```bash
# 1. Back up (produces two tarballs; verifies both)
./scripts/backup-wrapper.sh

# 2. Preview every copy. Nothing is written.
./scripts/overlay-gptk.sh --dry-run

# 3. Apply
./scripts/overlay-gptk.sh --execute
```

The overlay refuses to run if the wrapper is running, if backups are missing
or fail CRC, or if the redist layout is unexpected.

### What moves, and what deliberately does not

| File | Action | Why |
|---|---|---|
| `lib/external/D3DMetal.framework` | replace | The translation layer itself |
| `lib/external/libd3dshared.dylib` | replace | **Version-coupled** with the framework — they must move together |
| `x86_64-windows/d3d11,d3d12,dxgi.dll` | replace | The PE-side forwarders, part of the same GPTK drop |
| `x86_64-windows/nvapi64.dll` | add | New in the newer redist |
| `x86_64-windows/nvngx-on-metalfx.dll` | add | Backs `D3DM_ENABLE_METALFX` |
| `x86_64-unix/{nvapi64,nvngx-on-metalfx}.so` | add | Symlinks → `../../external/libd3dshared.dylib` |
| `d3d10.dll` | **keep** | Redist ships one, but its siblings `d3d10_1`/`d3d10core` have no counterpart. Replacing only `d3d10` splits that trio. D3D12 titles never load it. |
| `winemetal.dll` | **keep** | The redist ships **no** replacement — see [Residual risk](#residual-risk) |
| `d3d12core.dll`, `d3d9.dll` | keep | Base Wine |
| entire `i386-windows/` tree | keep | Never GPTK |
| `atidxx64.so` | keep | Newer redists drop it; it still resolves correctly |
| prefix `drive_c` DLLs | keep | `WINEDLLOVERRIDES=...=b` forces builtin, bypassing them |

### Environment settings

Set in `Info.plist`. The Wineskin launcher only plumbs a fixed set of keys
(`D3DMETAL`, `MOLTENVKCX`, `METAL_HUD`, `WINEMSYNC`, `WINEESYNC`, ...) —
verified by running `strings` on the launcher binary. Anything else must go
through `CLI Custom Commands`, which the launcher injects as shell:

```bash
/usr/libexec/PlistBuddy -c 'Set :"CLI Custom Commands" \
  "export ROSETTA_ADVERTISE_AVX=1;export D3DM_ENABLE_METALFX=1;"' \
  "$WRAPPER_APP/Contents/Info.plist"
plutil -lint "$WRAPPER_APP/Contents/Info.plist"
```

Adding these as top-level plist keys does nothing — the launcher never reads
them.

### Verifying the graft

```bash
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
  "$WRAPPER_APP/Contents/SharedSupport/wine/lib/external/D3DMetal.framework/Versions/A/Resources/Info.plist"
codesign --verify --deep --strict \
  "$WRAPPER_APP/Contents/SharedSupport/wine/lib/external/D3DMetal.framework"
```

A valid signature after copying confirms `ditto` preserved the bundle intact.

The wrapper-scoped Metal HUD (`METAL_HUD=1` in `Info.plist`) is more precise
than the global `launchctl setenv MTL_HUD_ENABLED 1`, which affects every
Metal app. In practice the **crash context is better evidence than the HUD**:
`RHI.AdapterName` and friends are recorded in every dump.

---

## Results

**The crash is fixed.** `RHIThread` no longer faults; the game reaches the
main menu and plays.

| | Before | After |
|---|---|---|
| D3DMetal | 2.1 | 4.0b2 |
| `libd3dshared.dylib` | 107,088 b | 241,888 b |
| `RHIThread` | `EXCEPTION_ACCESS_VIOLATION` at ~0s | runs |
| Playable | no | yes |

### Residual risk

The redist ships **no `winemetal.dll`**, so that half of the bridge remains
from the older base Wine build while `libd3dshared` is new. This is the one
version seam the graft cannot close. It has not caused problems here, but if
a future redist expects a newer `winemetal` interface, expect a failure to
start rather than a gameplay crash — roll back if that happens.

---

## Known issues

### 1. Video playback wedges the engine (open)

**Movies are currently disabled as a workaround.** Any `.mp4` the engine
tries to play hangs the load: Wine's GStreamer/Electra pipeline gets stuck
and never signals end-of-stream, so the engine waits forever.

A 10-second sample during a hang showed **98.1% of threads parked**, with
exactly one spinning:

```
vtdechw2:src   SPINNING in gst_vtdec_output_loop  (libgstapplemedia)
ElectraPlayer::Video decoder / MP4 streamer / EventDispatch   all blocked
RHIThread, RenderThread, all 14 PSOPrecompilePool threads     all parked
```

Zero `MTLCompiler` / `AGXMetal` / `GPUCompiler` frames anywhere — so this is
**not** shader compilation, and not a D3DMetal problem. The graphics layer is
idle, waiting on a media pipeline that never finishes. Full analysis in
[EVIDENCE.md](EVIDENCE.md).

**Retested 2026-10-03** — nearly a month later, with D3DMetal 4.0b2 in place
and the game otherwise stable: re-enabling the movies reproduced the hang
immediately. It froze during the opening logo parade, before reaching the
main menu. No crash dump was produced, confirming a hang rather than a crash.
Movies were disabled again and play resumed normally. **Still open.**

Manage it with:

```bash
./scripts/movies-toggle.sh status
./scripts/movies-toggle.sh off            # disable all
./scripts/movies-toggle.sh off cinematics # one group
./scripts/movies-toggle.sh on             # re-enable (to retest)
```

This renames `*.mp4` ↔ `*.mp4.disabled`. **The investigation is open** — the
wedge is in Wine's media stack, and re-testing after a Wine or GPTK update is
worthwhile. Re-enable and see whether it still hangs.

### 2. Changing graphics settings triggers a mass PSO recompile

Expected for a DX12 title: altering settings invalidates the pipeline-state-
object cache and the engine rebuilds it. Long stall, not a hang. Let it
finish; it is much shorter the second time.

### 3. 5.1 channel mapping is wrong and unstable (external — not a graft issue)

**Closed as external 2026-10-03.** Documented because the symptom points
convincingly at the game and is not the game.

**Symptom, as first observed.** 5.1 output worked and almost everything
played — music, weapons, ambience, in-person dialogue — but **radio/comms VO
(Cortana, Foehammer) was silent**, and the mix sounded subtly off. After
reconfiguring the AV chain the voices returned but arrived from the **wrong
speaker** (centre dialogue emerging from the left surround).

**Cause: the AV chain negotiates an inconsistent 5.1 channel order.** The
signal path is

```
Mac ──HDMI──▶ Samsung display ──eARC──▶ Sonos ──▶ 5.1
```

and it does not deliver channels in the order macOS assumes. Worse, **the
order changes between sessions.** Two separate hand-built assignments were
each needed to get macOS's white-noise test into the right speakers:

| Speaker | Session A | Session B | macOS default |
|---|---:|---:|---:|
| Left | 3 | 1 | 1 |
| Right | 4 | 2 | 2 |
| Centre | 6 | 4 | 3 |
| Subwoofer | 5 | 3 | 4 |
| Left surround | 1 | 5 | 5 |
| Right surround | 2 | 6 | 6 |

Because the negotiated layout differs per eARC handshake, **no static remap
holds** — a saved assignment simply becomes wrong in a new way.

**Why it looked like a game bug.** Radio comms VO is 2D non-diegetic and
conventionally **centre-locked**, while in-person dialogue is 3D-positioned
across L/R/surrounds. A mangled centre channel therefore silences exactly one
category of voice and leaves everything else intact — which reads as a
game-audio defect rather than a wiring one.

| Voice type | Positioning | Effect of a broken centre |
|---|---|---|
| In-person dialogue | 3D, L/R/surrounds | unaffected |
| Radio/comms VO | 2D, centre-locked | silent or mislocated |

**Proof it is not the wrapper.** The fault reproduces in **Audio MIDI Setup's
own white-noise speaker test**, with no game running. No Wine, no D3DMetal,
no FAudio involved. It will affect any 5.1 application on the machine.

**Current state: chain-level fault, not fixable in Audio MIDI Setup.**
Remapping corrects against a moving target. Fix the handshake instead:
disable CEC/Anynet+ on the display (the usual cause of spontaneous eARC
re-handshakes), pin the digital output to a fixed audio format rather than
Auto, update firmware on both display and soundbar, and replace the eARC
HDMI cable with a certified high-speed one. Then reset Audio MIDI Setup to
the default 1–6 so you are observing the chain rather than your own
compensation.

**If you hit this**, check the channel map before suspecting the graft:
Audio MIDI Setup → your device → *Configure Speakers* → 5.1 → test each
speaker and confirm the right one sounds. Note also that the game exposes
**no speaker-configuration setting** — UE5 takes whatever channel count the
output device reports — so there is no in-game override for a broken map.
If chasing the drift is not worth it, sending stereo from the Mac and letting
the soundbar upmix trades discrete channels for stability.

Full reasoning in [EVIDENCE.md](EVIDENCE.md#5-audio-51-channel-mapping-external).

---

## Rolling back

```bash
./scripts/restore-d3dmetal-v2.1.sh        # full: libraries + plist
./scripts/restore-renderer-moltenvk.sh    # surgical: 3 renderer keys only
```

The full restore removes `lib/external` and `lib/wine` wholesale before
extracting, so files the graft **added** (`nvapi64.dll`,
`nvngx-on-metalfx.dll` and their symlinks) are removed too — leaving a newer
`nvapi64` beside an older `libd3dshared` would recreate exactly the version
mismatch this project avoids. The script asserts they are gone.

Note the full restore also reverts `Info.plist` **entirely**, which clears
`CLI Custom Commands` along with the renderer keys. Use the surgical script
if you want to keep your environment variables.

---

## Repository layout

```
scripts/
  common.sh                     shared config, path helpers, guards
  backup-wrapper.sh             produces + verifies both backup tarballs
  overlay-gptk.sh               the graft (--dry-run / --execute)
  restore-d3dmetal-v2.1.sh      full rollback
  restore-renderer-moltenvk.sh  surgical renderer-key rollback
  movies-toggle.sh              enable/disable movie playback
  check-no-binaries.sh          blocks Apple binaries from the repo
docs/
  README.md                     this file
  EVIDENCE.md                   crash signatures + hang analysis
  MANIFEST-lib-tree-v2.1.txt         pristine library tree contents
  MANIFEST-prefix-system32-v2.1.txt  pristine prefix DLL contents
```

The manifests record what the pristine backups contained. **The tarballs
themselves are not in this repo** — they hold Apple binaries. Generate your
own with `backup-wrapper.sh`.

---

## License

Scripts and documentation here: MIT (see [LICENSE](../LICENSE)).

See [NOTICE](../NOTICE) for important limitations regarding Apple software:
the MIT license covers only what is authored here, and no Game Porting
Toolkit binary is distributed in this repository.
