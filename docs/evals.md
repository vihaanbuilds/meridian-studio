# Evals

Phase 1 evals live under `/evals`, one directory per capability, each
with a README stating input, expected result, and pass/fail criteria
— see `evals/eval_project_io/README.md` and `evals/eval_midi/README.md`.
They're currently satisfied by the automated test suite
(`RecordAndPersistIntegrationTests` for project I/O; the `AudioEngine`
unit tests for MIDI). As later phases add audio, mixer, and AI
features, they get their own eval directories per the Phase 0 spec's
eval architecture (Section 11).
