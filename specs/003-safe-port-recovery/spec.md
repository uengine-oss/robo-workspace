# Safe port recovery

## Goal

Make `down` and `restart` reliably stop every process that Robo Workspace
started, including a surviving listener whose launcher process has exited, and
provide one explicit recovery option for profile ports opened outside the
current Workspace state.

## Contracts

- State records the launcher and actual TCP listener as separate process
  identities. Each identity contains both PID and process start time.
- `down` and normal `restart` terminate only identities proven by that state.
- `down all` terminates owned processes recorded by every Workspace profile and
  removes all four profile state files in one command.
- `up all` starts the standalone Analyzer UI, embedded Analyzer remote,
  Architect API/UI, and shared backend services as one local browser stack.
- The `all` profile excludes Electron and reports both browser URLs.
- `down all -ForcePorts` additionally cleans declared service ports across all
  profiles while continuing to exclude Neo4j.
- Existing state written by the previous Workspace version remains readable;
  its exact launcher identity is honored, while an unverified orphan listener
  requires explicit forced port cleanup.
- `restart <profile> -ForcePorts` additionally terminates current listeners on
  the selected profile's declared service ports before startup.
- Forced cleanup never includes Neo4j or ports outside the selected profile.
- Port conflicts report the owning PID and an actionable recovery command.
- Doctor verifies Neo4j credentials, and Catalog readiness performs a real
  Neo4j-backed request instead of accepting a shallow process-only health check.
- `up|down|restart <profile> -Service <id>` changes only that recorded service
  and preserves every other running service in the profile state.
- Existing frontend and Electron artifacts are reused by default. `-Build`
  explicitly refreshes them, while a missing required artifact is built
  automatically.
- Workspace launch derives Architect's `ANALYZER_NEO4J_DATABASE` from the
  Analyzer-owned `ROBO_NEO4J_DATABASE`, so both always address the same single
  graph database without modifying repository-local `.env` files.
- All four Workspace `ROBO_NEO4J_*` values override inherited `ROBO_NEO4J_*`
  and `NEO4J_*` values for integrated child processes. Service-specific,
  non-Neo4j environment remains repository-owned.
- Doctor and selected-service startup display the effective shared database and
  its Workspace source without printing credentials.
- Full and selected-service startup reject a missing Workspace `.env` or any
  empty shared Neo4j field before replacing an existing service process.
- Workspace values are only the server fallback. Electron's per-request
  `X-Neo4j-*` connection override remains higher priority and is not rewritten
  or persisted by Workspace.

## Failure and boundary scenarios

- PID reuse must not cause an unrelated process to be terminated.
- A dead launcher with a live recorded listener must still be cleaned.
- A listener with a mismatched start time must not be treated as owned.
- Normal `down` must not terminate an unrecorded listener.
- Forced cleanup must terminate an unrecorded listener on a profile port and
  fail visibly if the port remains occupied.
- Tests must use isolated temporary state and ports and must not stop the user's
  currently running Architect stack.
- A selected-service restart must replace only its verified process identity;
  selected-service down must leave no empty state file.
- A conflicting pre-existing `ANALYZER_NEO4J_DATABASE` must not override the
  Workspace Analyzer database during a Workspace launch.
- Conflicting inherited URI, user, password, and database values must all be
  replaced together; partial mixing is forbidden.
- Missing central configuration must fail visibly instead of falling back to
  inherited shell or repository-local Neo4j values.
- Strict server defaults must not suppress Electron request-scoped connection
  selection; requests without headers return to the Workspace fallback.
