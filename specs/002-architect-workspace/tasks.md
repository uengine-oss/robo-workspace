# Tasks

- [x] T001 Add `architect-web` and `architect-electron` manifest profiles.
- [x] T002 Install Architect Python, host frontend, and desktop dependencies.
- [x] T003 Build Analyzer remote and co-located Electron frontend from sibling repos.
- [x] T004 Support HTTP and process readiness without global process termination.
- [x] T005 Add unpacked and installer build variants.
- [x] T006 Replace Architect dev/build scripts with workspace wrappers.
- [x] T007 Update workspace and Architect documentation.
- [x] T008 Verify web, Electron, package, failure, rollback, and shutdown scenarios.
- [x] T009 Make repeated `up` idempotent and add one-command `restart`.
- [x] T010 Verify live-state no-op, stale Electron recovery, and explicit restart.

Additional evidence: with five shared services live and Electron exited, `up
architect-electron -SkipBuild` detected one stale service, stopped the recorded
trees, and reopened a visible Electron window. Repeating `up` returned success
without rebuilding or replacing the live process. `restart` composes the same
verified owned-stop and start paths.
- [x] T011 Initialize and diagnose the required `open-pencil` submodule without
  duplicating Analyzer repositories under Architect.

## Evidence (2026-07-14)

- Architect web: eight managed services ready; host, direct API, host proxy,
  federation remote, Gateway health, and Gateway Architect proxy returned 200.
- Browser capture rendered the live Architect Proposals screen.
- Electron: unpacked artifact built, visible `Robo Architect` window captured,
  dynamic backend readiness and application API 200 responses recorded.
- Packaging: unpacked executable and NSIS installer both produced.
- Failure paths: reserved port and missing Electron shim failures were surfaced;
  rollback removed all owned listeners. Final web/Electron shutdown left no
  managed listener, Electron process, or Architect uvicorn child.
- Gateway Maven tests, PowerShell/JSON/Node parse checks, and diff checks passed.
