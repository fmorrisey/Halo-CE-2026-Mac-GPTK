# Apple Feedback Assistant draft — D3DMetal: no planar-YUV (NV12/P010) texture support breaks video in translated games

**File at:** https://feedbackassistant.apple.com (needs your Apple ID). Area: Graphics & Games → Game Porting Toolkit / Metal. Attach a sysdiagnose + the crash dump if asked.

**This is the root-cause fix** — if D3DMetal supports NV12 textures, every Media Foundation / UE Electra / Bink-via-MF video in every translated game just works, with no Wine-side or per-game workaround.

---

**Title:** D3DMetal cannot create `DXGI_FORMAT_NV12` (and P010/planar-YUV) textures — video decode output can't be presented; games show black video with audio.

**Environment:** Apple Game Porting Toolkit, D3DMetal **4.0b2**, macOS 26.6.2, Apple Silicon M5 Pro, x86_64 under Rosetta, via Porting Kit/Wineskin (stock WineHQ Wine 10.0). HUD shows "Game Porting Toolkit 4.0b2  D3D12".

**What happens:** Windows games that decode H.264/HEVC video through Media Foundation (very common: Unreal Engine ElectraPlayer titles, many others) produce decoded **NV12** frames that the engine then uploads to a D3D11/D3D12 texture for presentation. D3DMetal does not implement planar-YUV texture formats (`DXGI_FORMAT_NV12`, `P010`, DXGI formats ~100–114). The frame can't become a GPU texture, so cutscenes render **black while audio plays**. In some paths the unsupported-format allocation aborts/returns badly and the game crashes on the render thread instead.

**Concrete case:** *Halo: Campaign Evolved* (UE 5.5, ElectraPlayer). Decoder emits 1920×832 NV12 system-memory frames correctly; video is black because the NV12→texture step has no supported path. We confirmed the decode is healthy (2250/2250 frames in a Media Foundation harness) — the gap is purely D3DMetal's planar-YUV texture support.

**Impact:** This single gap blocks video in a large class of translated games. Community workarounds exist (Wine-side 2D-buffer shims, per-game DLL injection — see https://github.com/MathiasKowoll/MacGameVideoFix and https://github.com/Jfishin/winevideo) but they're fragile, per-game, and shouldn't be necessary. Native D3DMetal NV12/P010 texture support (sampleable as a biplanar/`MTLPixelFormat` pair, with the matching `CreateShaderResourceView` behavior) would fix the whole category.

**Ask:** Implement planar-YUV (`DXGI_FORMAT_NV12`, `P010`) texture creation and SRV sampling in D3DMetal, and if full support isn't feasible, at minimum return a clean `E_INVALIDARG`/`DXGI_ERROR_UNSUPPORTED` from `CreateTexture2D` for these formats instead of aborting, so engines can fall back gracefully rather than crash.
