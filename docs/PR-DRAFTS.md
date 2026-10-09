# Ready-to-post issue/PR drafts

Two upstream reports, ready to file once you give the OK (I can run `gh issue create`).
Both reference `docs/HALO-CE-2026-ELECTRA-VIDEO.md` for full detail.

---

## 1 → Jfishin/winevideo  (issue)

**Title:** UE5 Electra H.264 black video on Porting Kit / Wineskin (stock WineHQ 10.0) — need a non-CrossOver build target

**Body:**

Reporting a UE5.5 ElectraPlayer title — **Halo: Campaign Evolved** — with the
`IMF2DBuffer` black-video symptom your 0005+0007 patches address, but on a
**Porting Kit / Wineskin** wrapper rather than CrossOver.

Environment: stock **WineHQ `wine-10.0 (Sikarugir)`** (`org.winehq.wine`, Porting
Kit 3.0.6_2), Apple GPTK **D3DMetal 4.0b2**, Apple Silicon. Cutscene is H.264 Main
1920×822 yuv420p + AAC-LC; decoder outputs 1920×832 NV12. Audio plays, video black,
one frame then stall — the `IMF2DBuffer` rejection.

I ported your 0005 (`MF_SA_D3D_AWARE=!is_macos()`, refuse D3D manager) and 0007
(always `PROVIDES_SAMPLES` on macOS) cleanly to Wine 10.0. Two findings for you:

1. **Vanilla Wine 10.0's `transform_ProcessOutput` uses `MFCreateMemoryBuffer`
   (flat) on the `PROVIDES_SAMPLES` path, not a 2D buffer.** So 0005+0007 alone
   don't produce an `IMF2DBuffer` on 10.0 — a `MFCreate2DMediaBuffer` (or
   allocator 2D) substitution is also needed. Does your CrossOver tree (Wine 11)
   already do this in ProcessOutput? If so it'd be worth noting the 10.0 gap.
2. **A winegstreamer.dll built outside Porting Kit's toolchain is ABI-incompatible
   with its wine core** — a pristine 10.0 rebuild faults in `ntdll` (`__wine_unix_call`
   dispatch), because the wrapper's dll was built with mingw **GCC 15.2.0** and only
   GCC 16.2.0 is available here. **A Wineskin/Porting-Kit (stock WineHQ 10.0) build
   target, or a documented toolchain, would unblock every UE5 Electra title on that
   platform.**

Patch attached (`winegstreamer-ue5-electra-2dbuffer-macos.patch`). Happy to test
builds. Would you accept Halo: Campaign Evolved on the compatibility list?

---

## 2 → MathiasKowoll/MacGameVideoFix  (issue)

**Title:** electra-h264-fix: unrecognized Electra build + RHIThread crash on Halo: Campaign Evolved (Porting Kit)

**Body:**

`libogg_64_electra.dll` installs cleanly and hooks all 8 MFT vtable slots on
**Halo: Campaign Evolved** (UE5.5 Electra, `HaloCampaignEvolved.exe`), but:

- The software-path patch can't find its site on this build:
  `IsSoftware (sw value): bytes are 30 48 8D, expected FF 50 28 -- different
  build, leaving it alone` (outer gate: `B0 00 00`).
- With `Electra.Win.H264UseOldOutputPath=1` set (read-only `Engine.ini`) to force
  the software path config-side, the shim's 2D-buffer handling **corrupts the
  RHIThread**: `EXCEPTION_ACCESS_VIOLATION writing 0x1790178018031801` (pixel data
  walked as a pointer — wrong pitch/frame-size for this build).
  Dump `UECC-Windows-8C00A9DE…`, PCallStackHash `8E8D9906F8488EE6929A5D021D462622ECF24130`.

Environment: Porting Kit / Wineskin, **stock WineHQ 10.0** (not CrossOver),
D3DMetal 4.0b2. Decoder outputs tight-stride NV12 1920×832 for a 1920×822 frame.

Could you add this Electra build's `IsSoftware` gate pattern and the correct NV12
pitch for 1920×822→832? I can run the diagnostic probe and attach `electra-probe`
logs — tell me what you'd want captured. Offering Halo: Campaign Evolved for the
table either way.

---

## To post
```
gh issue create --repo Jfishin/winevideo --title "…" --body-file <(…)
gh issue create --repo MathiasKowoll/MacGameVideoFix --title "…" --body-file <(…)
```
(Will run only on your go-ahead — these post publicly under your account.)
