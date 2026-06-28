# daw

A native macOS DAW (GarageBand-class) whose differentiator is a **taste engine** — Suno generates
musical ideas, Moises/Music.ai dissects and finishes audio, and you stay the producer. See the design:

- [`docs/VISION.md`](docs/VISION.md) — the *why/what*: philosophy, use-case catalog, taste engine.
- [`docs/SPEC.md`](docs/SPEC.md) — the *how*: native-macOS architecture, data model, API contracts, phases.

## Status

**Phase 1 — DAW bones** (in progress). Working today: import audio (file picker or drag-and-drop),
multi-track waveform timeline, synchronized AVAudioEngine playback, transport (play/stop/seek + spacebar),
per-track volume / mute / solo, and zoom. No AI yet — that's Phase 2+.

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
  Models/   AudioAsset / Clip / Track, ProjectStore (in-memory project + transport)
  Audio/    AudioEngine (AVAudioEngine graph), WaveformLoader, LibraryStorage
  Views/    Editor, TransportBar, Timeline, TrackHeader, ClipLane/Waveform
docs/       VISION.md, SPEC.md
```
