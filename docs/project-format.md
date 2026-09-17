# Project File Format

A Meridian Studio project is a directory bundle with a `.mstudio`
extension, e.g. `MySong.mstudio/`:

    MySong.mstudio/
      project.json   # schemaVersion, sampleRate, tempo, timeSignature, tracks[]
      midi/          # reserved for future per-region MIDI files (unused in
                      # Phase 1 — note events are embedded directly in project.json)

`project.json` always has a top-level `schemaVersion` integer.
`ProjectStore.load(from:)` rejects any version other than
`Project.currentSchemaVersion` (currently `1`) with
`ProjectStoreError.unsupportedSchemaVersion`, so a real migration
function has somewhere to hook in once a second schema version exists.

Known Phase 1 limitation: the `.mstudio` extension is not registered
as a macOS document type (no Info.plist/UTType), so Finder shows it as
a plain folder rather than a package icon. Deferred until proper
app-bundle packaging lands in a later phase.
