# Eval: Project I/O

**Input:** A project with one MIDI track containing a region of two
notes (created via `MIDIRecorder` from synthetic MIDI events).

**Action:** Save the project to a `.mstudio` bundle, then reopen it.

**Expected result:** The reopened `Project` is equal to the original
(same tempo, time signature, tracks, regions, and note data).

**Pass/fail criteria:** Exact equality (`Project: Equatable`) — no
tolerance, since this is lossless JSON round-tripping, not lossy audio.

**Automated by:** `Tests/MIDIEngineTests/RecordAndPersistIntegrationTests.swift`.
