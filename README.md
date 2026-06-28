# daw

A native macOS DAW (GarageBand-class) whose differentiator is a **taste engine** — Suno generates
musical ideas, Moises/Music.ai dissects and finishes audio, and you stay the producer. See the design:

- [`docs/VISION.md`](docs/VISION.md) — the *why/what*: philosophy, use-case catalog, taste engine.
- [`docs/SPEC.md`](docs/SPEC.md) — the *how*: native-macOS architecture, data model, API contracts, phases.

## Status

**Phase 1 — DAW bones** ✅ import audio (picker or drag-and-drop), multi-track waveform timeline,
synchronized AVAudioEngine playback, transport (play/stop/seek + spacebar), per-track volume/mute/solo, zoom.

**Phase 2 — Music.ai integration** ✅ (first slice). Right-click any clip → **Split into Stems**
(each stem lands as a new track) or **Analyze** (key · BPM · chords). Jobs run async with a progress
indicator in the transport bar; the API key is stored in your Keychain.

### Music.ai setup (needed for the AI actions)

1. Get an API key from the [Music.ai](https://music.ai) developer dashboard (it has a free tier).
2. Open **Daw → Settings (⌘,)** and paste the key.
3. In Settings, set the **workflow slugs** to match your Music.ai **Workflows** page — copy the exact
   slugs (e.g. `music-ai/stems-vocals-accompaniment`). The defaults are starting points and may differ
   from what your account exposes; if a job errors, check the slug first.

## Build & run

Requires Xcode 16+ and [XcodeGen](https://github.com/yonsm/XcodeGen) (`brew install xcodegen`).
The `.xcodeproj` is generated from [`project.yml`](project.yml) and is git-ignored.

```sh
make open      # generate Daw.xcodeproj and open it in Xcode
# then press ⌘R in Xcode (pick your signing team on first run)
```

Other targets: `make generate` (regenerate the project), `make build` (command-line compile check,
no signing), `make clean`.

## Layout

```
Daw/
  App/      DawApp entry, palette + helpers
  Models/   AudioAsset / Clip / Track, ProjectStore, AppSettings
  Audio/    AudioEngine (AVAudioEngine graph), WaveformLoader, LibraryStorage, Keychain
    AI/     MusicAIClient, JobManager, AI types (stems / analyze)
  Views/    Editor, TransportBar, Timeline, TrackHeader, ClipLane/Waveform, Settings
docs/       VISION.md, SPEC.md
```
