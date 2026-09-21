# Two-App Architecture: Meridian Studio + Companion App — Design

Date: 2026-09-20
Status: Approved

## 1. Scope

This spec formalizes a decision reached outside this document's own
history: Meridian Studio's musician-facing DAW and a second,
rehab/therapy-facing companion app will ship as **two separate app
targets sharing only their data model and real-time I/O layers**, never
sharing UI code in either direction.

This document covers the architectural split in full detail — it is
the thing this spec exists to lock in — and the companion app's product
framing in roadmap-level detail only, the same way the Phase 0 spec
(`2026-09-16-meridian-studio-design.md`) covered Phase 1 in full and
Phases 2–10 as a light-detail roadmap. The companion app's own full
design (exact session model, exact metrics, exact UI flows) gets its
own dedicated brainstorming → spec → plan cycle before any of it is
implemented, per this project's standing "each phase gets its own pass"
rule. Nothing in this document authorizes starting that implementation
yet.

## 2. Why Two Apps, Not One App With Two Modes

The alternative — one app, a "musician mode" and a "patient mode" —
was rejected. Two independent app targets is the more expensive-looking
choice on paper (two `Info.plist`s, two app icons, two things to build
and ship) but it's the one that actually delivers "clean separation":

- The DAW's complexity (piano roll, multi-track, manual quantize
  strength, drag/resize gestures) can never leak into the
  accessibility-first companion surface, because the companion app's
  UI code cannot import it — there is no code path by which it could.
- The companion app's constraints (large single-switch-friendly
  controls, hardcoded near-1.0 quantization, no exposed editing) can
  never force a compromise onto the musician-facing UI, for the same
  reason in reverse.
- A regression or crash in one app's UI layer cannot be introduced by
  a change to the other app's UI layer — they don't compile together
  in the sense of one depending on the other, only in the sense of
  sharing two packages beneath both.
- Each app can evolve, ship, and even be distributed on its own
  schedule (e.g. one on the Mac App Store, one distributed directly to
  a clinic) without coordinating releases.

The cost is real and accepted: some duplication of app-shell
boilerplate (an `App` entry point, a settings/about screen, menu
commands) that a single app with two modes would share. This is judged
worth it because the two audiences' UI requirements are different
enough — not just different screens, but different *interaction
paradigms* (drag-and-drop precision editing vs. switch-control
scanning) — that sharing UI code would mean designing every shared view
for the lower common denominator of both, which is worse for both
audiences than building each UI once, well, for its own audience.

## 3. Shared Foundation — the Only Shared Surface

Two existing Swift packages, **unchanged by this split**, are the
entire shared surface between the two apps:

- **`ProjectModel`** — `Project`, `Track`, `TrackKind`, `MIDIRegion`,
  `AudioRegion`, `NoteEvent`, `Quantizer`, `ProjectDocument`,
  `ProjectStore`. Already stated as a hard architectural rule in
  `docs/architecture.md`: "No SwiftUI import." This rule is exactly
  what makes the split possible without restructuring anything that
  exists today — the package was already audience-agnostic by
  construction, years before a second audience existed.
- **`AudioEngine`** — `PlaybackEngine`, `AudioRecorder`,
  `AudioLevelMeter`, `CoreMIDIInput`, `MIDIRecorder`,
  `PlaybackScheduler`, `MIDIMessageParser`, `MIDIEventQueue`. Same
  property: real-time I/O logic with no UI dependency, already proven
  reusable by the fact that `MeridianStudioApp` is its only consumer
  today and nothing in it assumes that.

**The contract going forward:** neither package may grow a concept
that only makes sense for one app's audience. If the companion app
ever needs something that feels like it belongs in `ProjectModel` or
`AudioEngine` (a new field on `Track`, a new recording mode), that's a
signal to stop and ask whether it's actually a shared-foundation
concern or a companion-app-only concern that should live entirely in
the companion app's own target instead, reading the shared types
through their existing public API. Section 6.3 below is a concrete
example of resolving exactly that question in favor of "keep it out of
the shared packages."

Neither app may import the other's target. This is enforced by
`Package.swift` simply never listing that dependency (Section 4) —
there's no separate lint or CI check needed, since SwiftPM won't let a
target import a product it doesn't depend on.

## 4. Repository & Package Structure

One repository, one `Package.swift`, three product-facing targets
instead of one:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeridianStudio",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ProjectModel", targets: ["ProjectModel"]),
        .library(name: "AudioEngine", targets: ["AudioEngine"]),
        .executable(name: "MeridianStudioApp", targets: ["MeridianStudioApp"]),
        .executable(name: "MeridianCompanionApp", targets: ["MeridianCompanionApp"])
    ],
    targets: [
        .target(name: "ProjectModel"),
        .target(name: "AudioEngine", dependencies: ["ProjectModel"]),
        .executableTarget(name: "MeridianStudioApp", dependencies: ["ProjectModel", "AudioEngine"]),
        .executableTarget(name: "MeridianCompanionApp", dependencies: ["ProjectModel", "AudioEngine"]),
        .testTarget(name: "ProjectModelTests", dependencies: ["ProjectModel"]),
        .testTarget(name: "AudioEngineTests", dependencies: ["AudioEngine", "ProjectModel"]),
        .testTarget(name: "MeridianCompanionAppTests", dependencies: ["MeridianCompanionApp", "ProjectModel"])
    ]
)
```

Note what's absent: `MeridianCompanionApp` depends on `ProjectModel`
and `AudioEngine` only — the exact same dependency list
`MeridianStudioApp` has, never on `MeridianStudioApp` itself.
`MeridianCompanionAppTests` explicitly lists `ProjectModel` alongside
`MeridianCompanionApp` for the same reason `AudioEngineTests` already
lists `ProjectModel` alongside `AudioEngine` — SwiftPM only lets a
target `import` a module it directly depends on, not one available
merely transitively through another target. Repo layout:

```
Sources/
  MeridianStudioApp/     # existing, unaffected
  MeridianCompanionApp/  # new — its own AppState-equivalent, its own views
  ProjectModel/          # shared, unaffected
  AudioEngine/           # shared, unaffected
Tests/
  ProjectModelTests/
  AudioEngineTests/
  MeridianCompanionAppTests/   # new
```

This is a pure addition — no existing file moves, no existing target's
dependency list changes. `MeridianStudioApp` is not touched by this
split at all.

## 5. Meridian Studio (Existing App) — No Change

Explicitly stated so it's not ambiguous: Meridian Studio keeps
evolving exactly as it has been. Phase 3 (audio recording, now merged)
continues into whatever comes after it (Phase 4's mixer, per the Phase
0 roadmap) on its own track, independent of anything in this document.
This spec adds a sibling, not a redesign.

## 6. The Companion App — Product Framing (Roadmap-Level Detail)

Working name: **"Meridian Companion"** — a placeholder, not a final
product name. Everything in this section is the framing needed to
scope the *architecture* correctly; it is not implementation-ready and
should not be treated as a plan. The companion app's own brainstorming
session, before its first implementation plan, is where session flows,
exact metrics, and exact screens get nailed down.

### 6.1 Target users & use case

Broadest-benefit framing, deliberately not narrowed to one diagnosis:
the app turns a short daily "press keys" or "record a take" activity
into trackable data useful across more than one therapeutic context —
fine-motor rehabilitation (e.g. post-stroke or post-injury hand/finger
practice, where *timing consistency* is the signal that matters) and
engagement-oriented music therapy (e.g. cognitive or emotional
contexts, where *session frequency/duration/activity level* is the
signal that matters). The app does not diagnose, does not claim
clinical validity for any specific condition, and does not need to pick
one population to be useful — it surfaces both kinds of trend from the
same underlying recorded data and lets whichever one is relevant to a
given patient's care be the one that gets looked at.

### 6.2 Interaction model

- **Unsupervised, at-home, single-patient use.** No clinician-facing
  live control surface in this app (see 6.5 for how a clinician
  participates instead).
- **Accessibility-first**, built around macOS Switch Control (scanning
  input for users who cannot use a mouse/trackpad/keyboard
  conventionally), not just VoiceOver — large hit targets, `.focusable()`
  elements with a scanning-friendly order, minimal steps between
  launch and "a session is recording."
- **No editing surface at all.** No piano roll, no track list, no
  drag/resize, no manual quantize-strength dial. `Quantizer` is still
  used (recorded timing is still worth cleaning up for the trend data
  in 6.4), but its `strength` parameter is hardcoded near `1.0` and
  never exposed in the UI.
- **One session = one recording.** A single large "Start/Stop Session"
  control begins and ends one `MIDIRegion` or `AudioRegion` capture,
  reusing `MIDIRecorder`/`AudioRecorder` exactly as `MeridianStudioApp`
  already does — no new recording logic, only a much smaller UI wrapped
  around the same `AudioEngine` calls.

### 6.3 Session model — deliberately kept out of `ProjectModel`

"Progress/trend visualization" requires knowing *when* each session
happened, not just its position within one timeline. Neither
`MIDIRegion` nor `AudioRegion` carries a wall-clock timestamp today —
only `startBeat`/`lengthBeats`, which describe position within a
single take, not calendar time across many takes.

Two ways to get calendar time were considered:

1. Add a `recordedAt: Date` field to the region types in `ProjectModel`.
2. Give each session its own `.mstudio` project bundle, and let the
   *file system* — not the shared data model — carry the calendar-time
   information (the bundle's filename and/or creation date).

**Option 2 is the direction**, precisely because Option 1 would put a
therapy-specific concept (a field only the companion app's trend
computation would ever read) into the one package both apps share,
violating the contract in Section 3. Under Option 2: each session is
saved as its own project bundle (e.g.
`Meridian Companion/Sessions/2026-09-20-143000.mstudio`), using
`ProjectStore.save` completely unmodified. The companion app's own
code — never `ProjectModel`'s — is responsible for managing that
session-bundle directory, and for turning a bundle's filename/creation
date into "this is session N, recorded on this date" for trend
purposes. `ProjectModel` and `AudioEngine` end this design with zero
new lines of code.

### 6.4 Progress/trend computation

Lives entirely inside `MeridianCompanionApp`'s own target, as a plain
consumer of `ProjectModel`'s existing public API (`ProjectStore.load`,
`Track.regions`/`.audioRegions`, `NoteEvent`) — not a new capability
added to the shared packages. Candidate metrics (to be finalized in the
companion app's own spec, not here):

- **Engagement trend**: session count, duration, and note/activity
  density over time — read directly from each session bundle's region
  data, plotted per calendar day/week.
- **Timing-consistency trend**: variance of inter-note timing within a
  session (a proxy for motor control), computed from `NoteEvent.startBeat`
  values already present in every recorded `MIDIRegion` — no new
  recording-time instrumentation needed.

Both are descriptive only. Neither is framed as a diagnosis or a
clinical score.

### 6.5 Clinician review — local export, not remote sync

The agreed usage pattern is "patient records at home, clinician
reviews remotely/async" — but this milestone-level framing deliberately
does **not** include building any cloud sync, live transmission, or
hosted backend. That's real, regulated-data-adjacent infrastructure
that shouldn't be built before Section 6.6's question is answered. The
scoped-down version that satisfies "async remote review" without that
infrastructure: the companion app generates a local, shareable
progress-summary export (format TBD in its own spec — plausibly a
simple text/PDF summary, reusing the trend data from 6.4), which the
patient or a caregiver sends to a clinician through whatever channel
they already use today (email, a patient portal, printing it out). How
that file physically reaches the clinician is explicitly the user's
own responsibility, not a feature this app builds.

### 6.6 Privacy & regulatory stance

Undecided, per the answer this spec was written against — so this spec
defaults to the least-risky assumption rather than guessing:

- Written and framed as a **wellness/practice tool**, not a medical
  device: no clinical claims, no diagnostic language, anywhere in the
  app's copy.
- **Explicit, standing non-goal**: HIPAA-grade data handling,
  FDA software-as-a-medical-device considerations, and any other
  regulatory compliance work are out of scope for this spec and for the
  companion app's first milestone. This must be revisited — by the
  user, with appropriate legal/clinical input, not by an AI-driven
  brainstorming pass — before this app is ever marketed or deployed for
  real clinical use. This line is intentionally conservative: it is
  far cheaper to keep the first milestone's data handling simple (local
  files only, no transmission the app itself performs) than to build
  real compliance machinery against requirements that aren't decided
  yet.

## 7. Non-Goals

**Of this document:**
- Does not produce an implementation plan. That requires the
  companion app's own brainstorming session first.
- Does not finalize the companion app's name, exact session-file
  layout, exact metrics, or exact screens — roadmap-level framing only
  (Section 6).
- Does not resolve the regulatory question (Section 6.6) — explicitly
  deferred.

**Of the companion app's eventual first milestone** (carried forward
from Section 6, restated for visibility):
- No piano roll, no manual note editing, no multi-track UI, no exposed
  quantize-strength control.
- No cloud sync, no remote data transmission built by this app.
- No clinical/diagnostic claims.
- No change to `MeridianStudioApp`'s UI or behavior.
- No new fields or capabilities added to `ProjectModel`/`AudioEngine`
  for this app's sake (Section 6.3's resolution is the general
  pattern to follow if this is ever tempting).

## 8. Testing Approach

Not detailed here beyond the shape: `MeridianCompanionAppTests` follows
the same split this project already uses elsewhere — pure logic (trend
computation over a fixed set of hand-built `Project`/region fixtures)
gets real unit tests; hardware-adjacent and SwiftUI view code follows
the established no-automated-test precedent, verified by build and a
manual accessibility-focused smoke test (including an actual Switch
Control pass, not just VoiceOver, given 6.2's stated priority). Full
test list is the companion app's own spec's job.

## 9. Roadmap Placement

This is a **separate track from the Phase 1–10 numbering** in the
Phase 0 spec, which covers Meridian Studio's own DAW feature evolution
only. The companion app doesn't have a phase number in that sequence —
it's a second product built on the same foundation, not a new DAW
feature. When work on it actually starts, it gets its own
brainstorming → spec → plan cycle, tracked independently of Meridian
Studio's phase progress.

## 10. Assumptions Log

- Working name "Meridian Companion" is a placeholder pending real
  product naming — not to be treated as decided.
- Target use case is intentionally broad (motor-consistency +
  engagement metrics both included) rather than narrowed to one
  diagnosis, per explicit direction.
- Usage pattern is unsupervised at-home patient use with async
  clinician review via manual export, not live clinician-in-the-room
  use and not automated remote sync.
- Regulatory/clinical-deployment status is undecided; this spec and
  the companion app's first milestone proceed under a wellness-tool,
  non-clinical-claim assumption until that's explicitly resolved.
- Same platform/toolchain constraints as Meridian Studio (macOS 14+,
  Swift 6, SwiftPM executable target, no Xcode project required to
  build/run/test).

## 11. Next Steps

1. Add the `MeridianCompanionApp` target to `Package.swift` per Section
   4 (a small, mechanical, low-risk change — a new empty-shell
   executable target, not yet any of Section 6's product logic).
2. Hold a dedicated brainstorming session for the companion app's first
   milestone, following this project's normal spike/bounded/
   architectural classification process, informed by but not bound to
   the roadmap-level framing in Section 6.
3. Do not begin implementing any of Section 6 until that session
   produces its own approved spec.
