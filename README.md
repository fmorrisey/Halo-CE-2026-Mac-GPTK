# porting-kit-d3dmetal-graft

Scripts and field notes for grafting a newer **Game Porting Toolkit
D3DMetal** into a Porting Kit / Wineskin game wrapper on Apple Silicon — to
fix a crash the wrapper's bundled version could not survive.

**Case study:** a UE 5.5 DirectX 12 title crashing on `RHIThread` with
`EXCEPTION_ACCESS_VIOLATION` seconds after launch under D3DMetal 2.1.
Grafting in GPTK 4.0 beta 2 fixed it — the game reaches the menu and plays.

> ### ⚠️ No Apple binaries here
> Apple's GPTK license does not permit redistributing D3DMetal. This repo
> ships **scripts and documentation only**; they operate on a redist you
> download from Apple with your own developer account. A pre-commit hook
> blocks binaries from ever being committed.

> ### ⚠️ Unsupported
> This replaces the graphics translation layer inside an app bundle with
> **beta** libraries. Not supported by Apple, CodeWeavers, Porting Kit, or
> the game's developer. Back up first — the scripts insist on it.

## Start here

- **[docs/README.md](docs/README.md)** — prerequisites, the diagnosis chain,
  the graft procedure, results, rollback, and known issues.
- **[docs/EVIDENCE.md](docs/EVIDENCE.md)** — crash signatures, the hang
  analysis, and how two plausible theories were ruled out.

## Quick start

```bash
export WRAPPER_APP="/Applications/Ported Games/<Wrapper>.app"
export GPTK_VOLUME="/Volumes/Evaluation environment for Windows games 4.0 beta 2"

./scripts/backup-wrapper.sh        # two verified tarballs
./scripts/overlay-gptk.sh --dry-run
./scripts/overlay-gptk.sh --execute
```

Roll back with `./scripts/restore-d3dmetal-v2.1.sh`.

## Scripts

| Script | Purpose |
|---|---|
| `backup-wrapper.sh` | Capture + verify the pristine graphics state |
| `overlay-gptk.sh` | The graft, `--dry-run` by default |
| `restore-d3dmetal-v2.1.sh` | Full rollback: libraries **and** plist |
| `restore-renderer-moltenvk.sh` | Surgical rollback: three renderer keys |
| `movies-toggle.sh` | Enable/disable movie playback (video wedge workaround) |
| `check-no-binaries.sh` | Blocks Apple binaries from the repo |

Every destructive script dry-runs first, refuses to touch a running wrapper,
and verifies backups before writing.

## Two findings worth stealing

1. **`"AMD Compatibility Mode"` in a UE crash dump means D3DMetal is
   active.** That string lives only in `D3DMetal.framework` — not in
   MoltenVK, not in the PE DLLs. It settles "which renderer is actually
   running" when config flags are ambiguous.
2. **A crash context is better evidence than the Metal HUD.** It is written
   on every crash, needs no screenshot, and survives a Shipping build's empty
   log directory.

## Enable the safety hook after cloning

```bash
git config core.hooksPath .githooks
```

## License

MIT for the scripts and docs — see [LICENSE](LICENSE). This does not extend
to Apple's Game Porting Toolkit or D3DMetal, which are never distributed
here.
