# Gosan — Working Vision

> *Gosan*: the minstrel poet-musicians of Parthian/Persian folklore who carried songs by ear and made
> them their own — the spirit of this tool's "your taste, their horsepower."


> A GarageBand-style DAW whose superpower isn't more knobs — it's a **taste engine**.
> Suno generates raw musical ideas, Moises/Music.ai dissects and finishes audio, and you
> stay the producer: the one with the ears, making the editorial calls. The tool's job is
> to translate *your taste* into musical direction so you never have to learn the jargon.

Working title ideas: **Timbre**, **Loom**, **Crossfade**, **Palette**, **Tastemaker**. (Pick later.)

---

## 1. The core idea

You make music that "sounds new" by instinct, not by theory. The bottleneck isn't ideas —
it's the *production grammar* between an idea in your head and a finished track. AI tools
(Suno, Moises) collapse that grammar, but used alone they produce **generic** output:
they don't know *you*.

This DAW closes that gap with three layers:

| Layer | Who does it | What it owns |
|---|---|---|
| **Generator** | Suno | Make new audio from a prompt/seed: full tracks, parts, restyles, extensions |
| **Surgeon / Analyst / Finisher** | Moises · Music.ai | Split stems, detect key/BPM/chords, clean & enhance, master, voice-convert |
| **Canvas + Taste** | You + the DAW | Arrange, comp, layer your own recordings, A/B, curate, decide |

The **human touch** is not a vibe word here — it's three concrete, defensible jobs only you do:
1. **The seed** — your hum, your chord idea, your reference picks, your performance.
2. **The curation** — choosing which of N AI variants survives (this is where your taste imprints).
3. **The arrangement** — how the pieces are sequenced, layered, and edited into a whole.

Everything else, the machines can carry.

---

## 2. What your current tools actually expose (the honest version)

### Suno
- **No official self-serve API** (June 2026). Beta-only to partners. Three ways to integrate:
  - **(a) Third-party reseller API** (`sunoapi.org`, PiAPI, AIMLAPI, apiframe, …) — clean REST,
    ~$0.014–0.111/song, separate billing from your consumer subscription. Most viable for automation.
  - **(b) Unofficial session wrapper** (e.g. `gcui-art/suno-api`) — drives your own logged-in
    account via cookie. Free-ish but against ToS and fragile; fine for a personal spike, not to depend on.
  - **(c) Manual bridge** — the DAW writes the prompt, you paste into the Suno app, drag the result back.
    Zero API, works with exactly the subscription you already have.
- Real capabilities: **Generate** (vocal or instrumental, style-tagged), **Extend**, **Cover/Restyle**
  (keep melody, change everything else), **Stems** (up to 12 on Pro/Premier), **Personas** (consistent
  voice/style across songs), audio upload + continue.

### Moises / Music.ai
- **Moises** = the consumer app you have. **Music.ai** = the developer API behind it (same company),
  job-based async: `POST /job` with a workflow slug → `QUEUED → STARTED → SUCCEEDED` → result file URLs.
  Has a free tier for testing. This is the clean automation path.
- Real capabilities: **stem separation** (vocals, drums, bass, guitar, piano, strings, wind, other),
  **vocal isolation**, **key/chord/BPM detection**, **beat & downbeat maps**, **section detection**
  (intro/verse/chorus), **lyric transcription**, **AI mastering**, **vocal enhance / de-reverb / denoise**,
  **pitch shift**, **time stretch**, **voice conversion** (sing in another timbre), **stem generation**
  (make a part from a riff).

### The strategy that falls out of this: **Manual bridge first, API automation later**
Because Suno has no clean API, we do **not** gate progress on it. Every hero workflow below ships first
as a *guided manual recipe* (DAW prepares the input + instructions, you round-trip through the consumer
apps, DAW ingests the result), then we automate the round-trip with the reseller + Music.ai APIs once the
UX is proven. This means **we can start delivering value with the exact tools you have today.**

---

## 3. The Advanced Use-Case Catalog

Five themes, ~16 workflows. Each lists *the itch*, *the pipeline*, and *where your touch lives*.

### Theme A — Ideation (Suno-led)

**A1 · Hum-to-Track ("Seed")** ⭐ hero candidate
*Itch:* you have a melody in your head and nowhere to put it.
*Pipeline:* record a hum/beatbox/one-finger-piano → Moises *enhance + isolate* the seed → DAW sends it
as Suno's melodic seed with your vibe tags → Suno returns full arrangements → you keep stems you like.
*Your touch:* the original hum (yours forever) + which arrangement survives.

**A2 · Genre Crossbreed**
*Itch:* "I want Bon Iver's texture over UK-garage drums."
*Pipeline:* moodboard → prompt compiler builds the Suno style string → generate blends → A/B in the DAW,
keep the stems that nail it, discard the rest.
*Your touch:* the blend recipe is *your* aesthetic fingerprint.

**A3 · Section Regenerator**
*Itch:* the chorus is weak but the verses are gold.
*Pipeline:* select the chorus region → regenerate *only* that section (Suno cover/extend on the slice) →
DAW splices + auto-crossfades back in, key/tempo-matched.
*Your touch:* you decide what's weak and approve the replacement.

**A4 · Infinite Variations → Taste Tournament** ⭐ the differentiator
*Itch:* you can't describe what you want, but you know it when you hear it.
*Pipeline:* generate N variants of a part → DAW runs an A/B/X "tournament" → your keeps/rejects train a
**Taste Profile** (§4) that biases every future generation toward *you*.
*Your touch:* literally the entire point — your ear becomes the model's reward function.

### Theme B — Deconstruction & Sampling (Moises-led)

**B1 · Steal the Groove** ⭐ hero candidate *(personal/learning use; see guardrails §8)*
*Itch:* you love how a reference *feels* and want to build something new in that spirit.
*Pipeline:* drop a reference → Moises *split stems + detect key/BPM/chords + beat map* → DAW imports the
drum stem as a groove template and the chord chart as a scaffold → Suno generates fresh instrumentation
over it → you arrange something that's yours.
*Your touch:* you choose the reference and what to keep vs. reinvent.

**B2 · Stem Surgery**
*Itch:* a track is 90% there but one element ruins it.
*Pipeline:* import → split to stems → mute/solo → replace the offending stem with a Suno-generated one →
rebalance.
*Your touch:* you diagnose the problem element.

**B3 · Acapella & Instrumental Factory**
*Itch:* you want clean vocals or a clean instrumental for mashups/karaoke/remix.
*Pipeline:* one click → Moises vocal isolation / instrumental extraction → dropped onto its own track.

### Theme C — Vocal Production (Moises + Suno)

**C1 · Vocal Rescue**
*Itch:* great take, bad room/mic.
*Pipeline:* record → Moises *de-reverb + denoise + enhance* → vocal-bus AI master → comp best takes.
*Your touch:* it's *your* performance; AI only fixes the room.

**C2 · Harmony & Doubles Generator**
*Itch:* you want stacked harmonies but can't sing all the parts.
*Pipeline:* lead vocal → Moises voice-conversion/stem-gen → generated thirds/fifths/octaves & doubles →
you ride the levels.

**C3 · Topline Co-write**
*Itch:* you need a melody/lyric spark, sung in *your* voice.
*Pipeline:* Suno drafts a topline idea → you re-sing it yourself (your performance) → Moises enhances.
*Your touch:* AI is the co-writer; the voice on the record is you.

### Theme D — Arrangement & Finishing (DAW + both)

**D1 · Smart Arranger**
*Itch:* "the energy sags in the middle."
*Pipeline:* Moises section detection marks intro/verse/chorus → DAW suggests structural edits (cut V2,
double the last chorus) and asks Suno to fill transitions/risers.

**D2 · One-Click Master**
*Pipeline:* final mix → Moises AI mastering → A/B against unmastered *and* against a reference track,
with a loudness target. Your ears make the call.

**D3 · Key/Tempo Match (Fearless Mashup)**
*Itch:* dragging in any clip and having it just *fit*.
*Pipeline:* anything you import → auto key/BPM detect → auto pitch/time-stretch to project key/tempo.

### Theme E — The Taste Engine (your fingerprint, see §4)

**E1 · Moodboard → Prompt Compiler** — describe a vibe in plain words / drop reference clips / pick
adjectives → compiler emits a precise Suno style string (genre, BPM, key, instrumentation, structure).
*You never need the formal vocabulary.*

**E2 · Taste Profile** — a living model of your preferred tempos, keys, timbres, and "moves," learned from
every keep/reject/edit, that pre-biases prompts and re-ranks variants so output drifts toward *you*.

**E3 · Reference Match Meter** — score the in-progress track against a reference you love (key, tempo,
energy curve, spectral balance) so you can see *how close to the feeling* you are and what to change.

---

## 4. The Taste Engine (the part nobody else has)

This is the answer to *"blend my preferences into these tools, keep my taste and human touch."*

- **Signals it learns from:** every A/B/X choice, every clip you keep vs. delete, every prompt you accept
  vs. reword, every manual edit after a generation (the edit is a correction signal — gold).
- **What it stores:** lightweight per-user vectors + explicit preferences — favored BPM bands, keys/modes,
  timbral descriptors, structural habits, "never do this" negatives.
- **What it does:**
  1. **Biases generation** — silently appends your learned style fingerprint to every Suno prompt.
  2. **Re-ranks variants** — orders the N generated options by predicted "you-ness" before you even listen.
  3. **Explains itself** — "I pushed this warmer and slower because your last 12 keeps trended that way."
- **Why it's defensible:** the value compounds. The more you use it, the less it sounds like Suno-default
  and the more it sounds like a producer who's been studying *your* records for a year.

Start dumb and honest: v1 is a JSON profile + a re-ranker. Embeddings/learning come later.

---

## 5. Architecture & recommended stack

**Recommendation: web-first, Supabase-backed, Tauri-wrapped later.**

```
┌─────────────────────────────────────────────────────────────┐
│  FRONTEND  (TypeScript / React)                              │
│  • Timeline, tracks, clips, transport, mixer                 │
│  • Web Audio API + Tone.js (playback/sequencing)             │
│  • WaveSurfer.js / Peaks.js (waveforms)                      │
│  • Taste Tournament UI, Moodboard, Prompt Compiler           │
│        ▲  (later: wrap in Tauri for a real desktop app +     │
│        │   local file library + optional Rust DSP core)      │
└────────┼─────────────────────────────────────────────────────┘
         │ HTTPS
┌────────┴─────────────────────────────────────────────────────┐
│  BACKEND  (Supabase — you already run this on Parkzy)        │
│  • Postgres: projects, clips, taste profile, job records     │
│  • Storage: audio, stems, masters                            │
│  • Edge Functions: orchestrate async AI jobs + webhooks      │
│  • Auth                                                       │
└───────┬───────────────────────────────┬─────────────────────┘
        │                               │
┌───────┴────────┐             ┌────────┴──────────┐
│  Suno adapter  │             │ Music.ai adapter  │
│  (reseller API │             │ (job-based async, │
│   or manual    │             │  stems/analyze/   │
│   bridge)      │             │  master/enhance)  │
└────────────────┘             └───────────────────┘
```

**Why web-first (not native macOS / Swift+AudioKit):** the core value here is AI-augmented
*arrangement and curation* over HTTP — not low-latency live tracking or VST hosting. Web Audio nails
playback, waveform editing, and stem layering, and gives the **fastest iteration loop** so you actually
get to inject taste early. **Why Supabase:** you already run Supabase + edge functions on Parkzy, so
storage + async job orchestration + webhooks are familiar, not a new thing to learn. **Why Tauri later:**
a real app icon, a local library, offline stems, and a future Rust audio core if we ever want pro-grade
performance — without rewriting the UI.

The honest tradeoff we're accepting: web audio is weaker for **live monitoring/recording latency** and
has **no native AU/VST plugins**. If, later, live tracking with effects becomes central, that's the
trigger to consider a native or Tauri+Rust audio core. For the workflows above, it isn't central.

---

## 6. Roadmap

**Principle: every milestone ships a manual-bridge version first, then automates it.**

- **M0 · Integration spike (days, no UI).** Prove both pipes end-to-end from scripts:
  (a) Suno reseller API → generate a 30s instrumental from a text prompt → download.
  (b) Music.ai → upload a song → stem-split + key/BPM analysis → download stems.
  *Deliverable: two scripts that work. De-risks the entire project.*
- **M1 · DAW bones.** Web app: timeline, import audio, multi-track playback, waveforms, solo/mute,
  clip move/trim, export mix. The GarageBand skeleton.
- **M2 · Suno in the canvas.** "Generate a part" panel drops audio onto a new track. Section regenerate (A3).
- **M3 · Moises in the canvas.** Right-click a clip → Split to stems / Analyze / Enhance / Master.
- **M4 · Taste Engine v1.** A/B/X tournament (A4), keep/reject logging, Moodboard→Prompt compiler (E1),
  profile that biases prompts (E2).
- **M5 · Hero recipes.** Hum-to-Track (A1), Steal-the-Groove (B1), Vocal Rescue (C1) as guided flows.
- **M6 · Finish & desktop.** Tauri shell, local library, one-click master (D2), reference match (E3).

---

## 7. The very next slice

Build **M0** behind a tiny CLI so you can hear results this week, with zero UI risk:

```
daw seed "warm lo-fi boom-bap, 82 bpm, dusty Rhodes, vinyl crackle"   # → Suno → out/seed.mp3
daw split path/to/song.mp3                                            # → Music.ai → out/stems/*.wav
daw analyze path/to/song.mp3                                          # → key, BPM, chords, sections
```

If you'd rather not pay for the Suno reseller yet, M0's `seed` command instead **prints the compiled
prompt for you to paste into the Suno app** (the manual bridge) and watches a folder for the file you
drag back. Same UX, zero API cost — and it's the exact pattern every hero recipe reuses.

---

## 8. Risks & guardrails (named, not buried)

- **Suno API fragility** — no official API; resellers and session-wrappers can break. *Mitigation:* the
  manual bridge is always a working fallback; the adapter interface hides which path is live.
- **Derivative-works legality** — "Steal the Groove" and acapella extraction are for **personal
  learning/ideation**. Releasing tracks built on someone else's copyrighted stems has real legal exposure.
  The tool will label reference-derived material and keep it out of "export for release" by default.
- **Latency/recording** — web audio isn't built for tight live monitoring. We lean on *import + enhance*
  over *live tracking* until/unless that changes the calculus.
- **Cost creep** — generation and stem jobs cost per-call. Cache aggressively; show a running cost meter.
- **Generic-output trap** — the Taste Engine is the antidote, so it's not a "nice to have," it's core.

---

## 9. Decisions (locked 2026-06-28)

1. **Platform/stack → native macOS** (Swift / SwiftUI / AVAudioEngine + AudioKit). A true
   GarageBand-class app, not web. See `docs/SPEC.md` for the full technical design.
2. **Where to start → a fuller written spec first** (`docs/SPEC.md`), then the Xcode skeleton.
3. **Hero workflows → all of them are first-class capabilities**, built by composing a small set of
   shared primitives (record, import, generate, extend, cover, split, analyze, enhance, master,
   voice-convert, key/tempo-match, taste tournament). No single one is privileged.
4. **Suno access → session-wrapper on Milad's own account**, with the manual bridge as the
   always-available fallback; the adapter interface hides which path is live so we can swap later.

> §5's stack diagram (web-first/Supabase) is **superseded** by the native-macOS design in `docs/SPEC.md`.
> The use-case catalog (§3) and Taste Engine (§4) carry over unchanged.
