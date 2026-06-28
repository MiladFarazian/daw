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

**Phase 3 — Suno generation** ✅ (first slice). **Generate** in the transport bar opens a panel: describe
a vibe → get candidates in a variant tray → audition each → add the keepers to the timeline. Uses a local
Suno session-wrapper, with **Open in Suno (manual)** (copies the prompt, opens Suno, drag the result back)
as a zero-setup fallback.

### Suno setup (for one-click generation)

Run a local Suno API wrapper such as [`gcui-art/suno-api`](https://github.com/gcui-art/suno-api) signed in
to your own Suno account (it holds your session cookie), then set its URL in **Settings → Suno**
(default `http://127.0.0.1:3000`). No sidecar? Use **Open in Suno (manual)** — it needs nothing but the
Suno subscription you already have.

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
  Audio/    AudioEngine (AVAudioEngine graph), WaveformLoader, LibraryStorage, Keychain, PreviewPlayer
    AI/     MusicAIClient + JobManager (stems/analyze), SunoSidecarClient, AI/Suno types
  Views/    Editor, TransportBar, Timeline, TrackHeader, ClipLane/Waveform, Settings, GeneratePanel
docs/       VISION.md, SPEC.md
```
