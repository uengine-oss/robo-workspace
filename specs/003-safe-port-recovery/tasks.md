# Tasks

- [x] T001 Persist exact launcher and listener process identities.
- [x] T002 Stop a surviving owned listener without trusting PID alone.
- [x] T003 Preserve compatibility with state written by the previous version.
- [x] T004 Add explicit `-ForcePorts` recovery for selected profile ports.
- [x] T005 Show PID and recovery guidance for occupied ports.
- [x] T006 Add isolated process-ownership regression tests.
- [x] T007 Update README and verify the running user stack was not interrupted.
- [x] T008 Suppress the benign child-PID race after `taskkill /T`, while still
  failing if a verified process actually remains alive.
- [x] T009 Add and isolate-test one-command shutdown with `down all`.
- [x] T010 Add a complete local browser stack with `up all`.
- [x] T011 Fail before startup on invalid Neo4j credentials and use deep Catalog readiness.

## Evidence (2026-07-14)

- `tests/process-ownership.ps1` passed with four isolated listeners: exact
  orphan ownership, legacy launcher ownership, mismatched start-time rejection,
  explicit forced cleanup of an unrecorded profile-port listener, and a
  launcher/listener tree where terminating the launcher also terminates the
  separately recorded listener.
- PowerShell parsing, `git diff --check`, help switch parsing, and live status
  checks passed.
- The active Architect stack retained the same six recorded launcher/listener
  identities throughout testing; no production profile command was stopped or
  restarted.
- `down all` removed the prior Electron/Web states without duplicate child-PID
  errors. `up all -SkipBuild` then started nine services under one
  `all-state.json`; Analyzer UI 3000, Architect UI 5173, Gateway 9000, direct
  Catalog, Gateway-routed Catalog, and Architect-proxied Catalog all returned
  HTTP 200.
