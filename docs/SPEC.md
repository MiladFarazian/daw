# Gosan — Technical Spec (native macOS)

Companion to `docs/VISION.md`. This is the **how**. Decisions locked 2026-06-28: native macOS app,
spec-first, all hero workflows as composable capabilities, Suno via a session-wrapper on Milad's own
account (manual bridge fallback).

---

## 1. Target & frameworks

| Concern | Choice | Notes |
|---|---|---|
| OS target | macOS 15+ | Latest SwiftUI + AVFAudio; single-user personal app |
| Language | Swift 6 (strict concurrency) | Actors for the audio + job layers |
| UI | SwiftUI, with AppKit (`NSViewRepresentable`) for the timeline canvas | SwiftUI for chrome/panels; custom drawing for waveforms/clips needs AppKit/Canvas/Metal for perf |
| Audio engine | `AVAudioEngine` core graph + **AudioKit** helpers | AudioKit (built on AVAudioEngine) gives players/mixers/taps/effects fast; drop to raw AVAudioEngine where needed |
| Waveforms | Read `AVAudioFile` → downsample to peak cache → draw | Cache peaks per asset on import |
| Persistence | **SwiftData** model + a `.daw` document **package** (folder) holding audio assets | Document-based app (`DocumentGroup`); assets live beside the model so projects are portable |
| Networking | `URLSession` async/await | Music.ai direct; Suno via local sidecar |
| Secrets | Keychain | Music.ai API key, Suno cookie |
| Concurrency | Structured concurrency; `actor JobManager`, `actor AudioGraph` | Keep the audio render thread clean |

**The one hard part to respect up front:** macOS app sandbox + user-selected files → use
**security-scoped bookmarks** for any audio imported from outside the project package, and copy imports
into the `.daw` package so projects stay self-contained.

---

## 2. Layered architecture

```
┌──────────────────────────────────────────────────────────────────┐
│ UI (SwiftUI)                                                       │
│  Library · Editor(timeline) · Mixer · Inspector · AI panels        │
└───────────────┬───────────────────────────────┬──────────────────┘
                │                               │
┌───────────────┴──────────────┐   ┌────────────┴───────────────────┐
│ Project/Document model         │   │ Taste Engine                   │
│ (SwiftData) + .daw package     │   │ profile + re-ranker + compiler │
└───────────────┬──────────────┘   └────────────┬───────────────────┘
                │                               │
┌───────────────┴──────────────┐   ┌────────────┴───────────────────┐
│ Audio Engine (actor)           │   │ AI Services layer              │
│ AVAudioEngine graph, transport │   │ GeneratorService (Suno)        │
│ scheduling, offline bounce     │   │ AudioIntelligence (Music.ai)   │
└────────────────────────────────┘   │ JobManager (actor): submit/    │
                                      │ poll/download/import           │
                                      └────────────┬───────────────────┘
                                ┌──────────────────┴─────────────────┐
                                │ Suno sidecar (localhost)  Music.ai │
                                │ + manual-bridge fallback   REST    │
                                └─────────────────────────────────────┘
```

### 2.1 Audio Engine
- Graph: each track = `AVAudioPlayerNode` → track `AVAudioMixerNode` (volume/pan) → optional effect
  nodes → main mixer → output.
- Transport: play/stop/locate, loop region, sample-accurate clip scheduling against a shared timeline
  clock (frames at project sample rate).
- Record: input node → tap → write to asset; arm per track.
- **Export**: `AVAudioEngine` **offline manual-rendering mode** → bounce mixdown to a file (then optional
  Music.ai master pass).
- Wrapped in `actor AudioGraph` so UI mutations are serialized off the render thread.

### 2.2 AI Services layer (protocol-first so paths are swappable)
```swift
protocol GeneratorService {            // Suno
  func generate(_ p: GeneratePrompt) async throws -> [GeneratedClip]
  func extend(asset: AudioAsset, at: TimeInterval, _ p: GeneratePrompt) async throws -> [GeneratedClip]
  func cover(asset: AudioAsset, _ p: GeneratePrompt) async throws -> [GeneratedClip]   // restyle, keep melody
  func stems(asset: AudioAsset) async throws -> [Stem]                                 // if exposed; else Music.ai
}

protocol AudioIntelligenceService {    // Music.ai
  func splitStems(_ a: AudioAsset, kinds: [StemKind]) async throws -> [Stem]
  func analyze(_ a: AudioAsset) async throws -> AnalysisResult   // key/BPM/chords/sections/lyrics/LUFS
  func enhanceVocal(_ a: AudioAsset) async throws -> AudioAsset  // de-reverb + denoise + clarity
  func master(_ a: AudioAsset, target: LoudnessTarget) async throws -> AudioAsset
  func voiceConvert(_ a: AudioAsset, model: VoiceModel) async throws -> AudioAsset
  func isolateVocals(_ a: AudioAsset) async throws -> (vocals: AudioAsset, instrumental: AudioAsset)
}
```
Both back onto `actor JobManager`, which gives every async job one lifecycle: **submit → poll → download
→ import as `AudioAsset` → emit progress**. Manual bridge implements the *same* protocols (writes a
prompt/instructions, watches a drop folder), so the UI never knows which path is live.

### 2.3 Taste Engine — see §6.

---

## 3. Data model (SwiftData)

```
Project(id, name, tempo, timeSig, key, mode, sampleRate, createdAt, updatedAt)
  ├─ tracks: [Track]
  ├─ references: [Reference]
  └─ tasteProfile: TasteProfile

Track(id, name, kind{audio,instrument,aux,master}, order, volume, pan, mute, solo, color, armed)
  ├─ clips: [Clip]
  └─ effectChain: [Effect]

Clip(id, startTime, offset, duration, gain, fadeIn, fadeOut, pitchShift, timeStretch,
     name, sourceTag{recording,import,suno,stem,reference-derived,master}, locked)
  └─ asset: AudioAsset

AudioAsset(id, fileURL, sampleRate, channels, durationSeconds, peaksCacheURL,
           originalFilename, provenance, sha256)
  ├─ stems: [Stem]           // if this asset was split
  └─ analysis: AnalysisResult?

Stem(id, type{vocals,drums,bass,guitar,piano,strings,wind,other}, asset: AudioAsset, parent: AudioAsset)

AnalysisResult(id, key, mode, bpm, beatMap:[Double], downbeats:[Double],
               chords:[(time, label)], sections:[(label,start,end)], lyrics:[(time,text)], lufs)

AIJob(id, provider{suno,musicai,manual}, kind, status{queued,started,succeeded,failed},
      paramsJSON, requestedAt, finishedAt, resultAssetIds:[id], costEstimate, error)

TasteProfile(id, tempoRange, preferredKeys:[String], timbres:[(tag,weight)],
             structuralHabits:JSON, negatives:[String], embedding:[Float]?, updatedAt)

TasteEvent(id, type{keep,reject,edit,promptAccept,promptReword}, subjectId, contextJSON, createdAt)

Persona(id, name, sunoPersonaId, descriptor)      // Suno consistent-voice/style
Reference(id, asset: AudioAsset, analysis: AnalysisResult, note)
```

---

## 4. API contracts

### 4.1 Music.ai (direct, job-based, polled)
- **Auth:** `Authorization: <API_KEY>` header (key in Keychain).
- **Upload:** `POST /api/upload` → signed PUT URL → `PUT` the file → returns a download URL.
- **Create job:** `POST /api/job` `{ name, workflow: "<slug>", params: { inputUrl } }` → `{ id }`.
- **Poll:** `GET /api/job/{id}` → `{ status: QUEUED|STARTED|SUCCEEDED|FAILED, result: { ...urls } }`.
  Native app has no public webhook endpoint → **poll every 2–5s with backoff**.
- **Workflows we configure in the Music.ai dashboard** (referenced by slug):
  `stem-split-multi`, `analyze-key-bpm-chords`, `sections-detect`, `lyrics-transcribe`,
  `vocal-enhance`, `master`, `voice-convert`, `vocal-isolate`.

### 4.2 Suno (session-wrapper sidecar on `127.0.0.1`)
- Run `gcui-art/suno-api` (or equiv) as a **local sidecar**; it holds `SUNO_COOKIE` (from Keychain).
  App talks to `http://127.0.0.1:<port>`.
- Endpoints: `POST /api/generate` `{prompt, tags, make_instrumental, model_version, wait_audio}`,
  `POST /api/custom_generate` (explicit lyrics/title/tags), `POST /api/extend_audio`,
  `GET /api/get?ids=` (poll), feed/credits.
- **Lifecycle in-app:** the Mac app launches the sidecar as a child `Process` on startup (or expects it
  running), health-checks it, and surfaces status in Settings.
- **Fragility is assumed.** If the wrapper breaks or an op isn't exposed (cover/stems sometimes aren't),
  the adapter transparently falls back to the **manual bridge** (write compiled prompt + open Suno +
  watch a drop folder). Later hardening option: reimplement the cookie flow natively in Swift, or switch
  to a reseller API — no UI change, since both honor `GeneratorService`.

---

## 5. Hero workflows = compositions of shared primitives

Primitives (each is a JobManager op or a local DSP/timeline action):

`P1 record · P2 import · P3 generate · P4 extend · P5 cover/restyle · P6 stems · P7 splitStems ·
P8 analyze · P9 enhance · P10 master · P11 voiceConvert · P12 key/tempo-match · P13 tournament+taste ·
P14 promptCompile · P15 place-on-timeline`

| Workflow | Composition |
|---|---|
| **Hum-to-Track** | P1 → P9(clean seed) → P14 → P3(seed-conditioned) → P13 → P15 |
| **Genre Crossbreed** | P14(blend recipe) → P3 → P13 → P15 |
| **Section Regenerator** | select region → P5/P4 on slice → P12(match key/tempo) → splice + crossfade |
| **Taste Tournament** | P3(N variants) → P13 (keeps/rejects train profile) |
| **Steal the Groove** | P2 → P7 + P8 → import drum stem + chord scaffold → P3 over it → P15 → arrange |
| **Stem Surgery** | P2 → P7 → mute/solo → P3(replacement stem) → P15 → rebalance |
| **Acapella/Instrumental Factory** | P2 → P16 isolateVocals → P15 |
| **Vocal Rescue** | P1 → P9 → P10(vocal bus) → comp |
| **Harmony & Doubles** | lead vocal → P11/P6 → generated stacks → P15 |
| **Topline Co-write** | P3(topline idea) → P1(re-sing it) → P9 |
| **Smart Arranger** | P8(sections) → structural suggestions → P3/P4(fill transitions) |
| **One-Click Master** | mixdown(bounce) → P10 → A/B vs unmastered + reference |
| **Fearless Mashup** | any P2 → P8 → P12 to project key/tempo |
| **Reference Match Meter** | P8(reference) vs bounce → compare key/tempo/energy/spectral |

Designing these as compositions means we build the **15 primitives once** and every workflow becomes a
thin recipe (a `Template` that pre-wires tracks + a guided step list). New workflows are cheap.

---

## 6. Taste Engine (the differentiator)

- **Inputs (TasteEvents):** every keep/reject in a tournament, every clip kept vs. deleted, every prompt
  accepted vs. reworded, and **every manual edit made after a generation** (an edit = a correction signal).
- **Profile (v1, deterministic):** preferred tempo band, keys/modes, weighted timbre tags, structural
  habits, explicit negatives. Stored as `TasteProfile`.
- **Three jobs:**
  1. **Bias generation** — `promptCompile` (P14) silently appends the learned fingerprint to every Suno
     prompt.
  2. **Re-rank variants** — order generated options by predicted "you-ness" before you listen.
  3. **Explain** — "ranked this first: warmer + slower, matching your last 12 keeps."
- **Evolution:** v1 = JSON profile + weighted re-ranker. v2 = on-device **Core ML** embeddings of
  audio + choices for a learned ranker. Always local; the value compounds with use.

---

## 7. Screens

1. **Library / Home** — projects grid; New Project; **templates** = the hero workflows (Hum-to-Track,
   Steal-the-Groove, Vocal Rescue…) that pre-wire tracks + a guided step list.
2. **Editor** — transport bar (play/stop/record/loop, tempo, key, master meter, **cost meter**); left
   track headers (name, mute/solo, vol/pan, arm, color); center **timeline canvas** (waveform clips,
   bar/beat grid, snap, drag/trim/split, fades); right **Inspector** (contextual clip/track props + AI
   actions).
3. **AI Generate panel** — Moodboard (adjectives, reference drop, project BPM/key) → editable compiled
   prompt → Generate N → **variant tray** → drag to track or open Tournament.
4. **Taste Tournament** — A/B/X listening, keep/reject, logs TasteEvents, shows "why ranked."
5. **Clip context menu** — Split to Stems / Analyze / Enhance Vocal / Master / Voice Convert / Isolate →
   spawns AIJob with progress → results drop as new tracks/clips.
6. **Mixer** — channel strips + master; master/enhance AI actions live on strips.
7. **Reference panel** — imported references + analysis; **Reference Match Meter** vs current bounce.
8. **Settings** — Keychain keys, Suno cookie + sidecar status/health, Music.ai workflow slugs, cost caps.

---

## 8. Build phases

- **Phase 0 — this spec.** ✅
- **Phase 1 — DAW bones.** Xcode document-based SwiftUI app; AVAudioEngine multi-track playback of
  imported audio; waveform rendering + peak cache; transport; mute/solo/vol/pan; clip drag/trim/split;
  **offline bounce export**. No AI yet.
- **Phase 2 — Music.ai integration.** AI Services + JobManager + Settings(keys). Wire the **most reliable
  API first**: Split-to-Stems + Analyze in the clip context menu, results onto tracks.
- **Phase 3 — Suno.** Sidecar launch + health; Generate panel + variant tray; Extend/Cover; manual-bridge
  fallback.
- **Phase 4 — Taste Engine v1.** Tournament UI, TasteEvent logging, profile, prompt compiler + re-ranker.
- **Phase 5 — Recipes & finish.** Hero-workflow templates, One-Click Master, Reference Match Meter,
  polish, app icon.

---

## 9. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Suno wrapper breaks / ToS / op not exposed | Adapter protocol + **manual-bridge fallback always works**; can swap to reseller/native later with no UI change |
| Native audio (AVAudioEngine) complexity | AudioKit for the 80%; start with playback before recording/effects; offline render is a known pattern |
| Sandbox file access | Security-scoped bookmarks; copy imports into the `.daw` package |
| Per-call AI cost | Cache stems/analysis by asset `sha256`; running cost meter; cost caps in Settings |
| Generic AI output | The Taste Engine is core, not optional — it's what makes output sound like *you* |
| Derivative-works legality (Steal-the-Groove, acapella) | Tag reference-derived material; exclude from "export for release" by default (see VISION §8) |

---

## 10. Immediate next step

Stand up the **Phase 1 Xcode skeleton**: a document-based SwiftUI macOS app that imports an audio file,
shows its waveform on a track, and plays it back through AVAudioEngine with a working transport. That's
the smallest thing that *feels like a DAW*, and everything else hangs off it.
