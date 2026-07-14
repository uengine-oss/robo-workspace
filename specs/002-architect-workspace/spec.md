# Architect workspace launcher

## Goal

Provide one reproducible Windows entry point for the Architect web stack, the
Architect Electron development stack, and Electron packaging while keeping all
services in independent sibling Git repositories.

## Contracts

- `robo.cmd setup architect-web|architect-electron` clones and installs every
  repository needed by that profile.
- `robo.cmd up architect-web` builds and serves the Analyzer federation remote,
  then starts the five shared services, Architect API, and Architect host UI.
- `robo.cmd up architect-electron` builds the unpacked app, starts the five
  shared services, and starts that actual Electron artifact. Electron owns its
  dynamically allocated Architect API child. `-SkipBuild` reuses the artifact.
- `robo.cmd build architect-electron [unpacked|installer]` produces the requested
  Electron artifact after rebuilding both frontend artifacts and desktop code.
- `down` terminates only process trees recorded in the selected profile state.
- Parser and data-fabric use local ports 8401 and 8404; Gateway receives their
  URLs through environment variables.
- Architect web API uses local port 8501 because 8001 can be Windows-reserved;
  the host and Gateway receive that URL through environment variables.

## Failure and boundary scenarios

- Missing tools, repositories, dependencies, Neo4j, artifacts, or occupied
  ports fail before partial startup where possible.
- A service that exits or fails readiness causes rollback of every process
  already started for that profile.
- Dirty repositories are never overwritten by `sync`.
- Electron readiness is process-based; HTTP services use actual health URLs.
- Packaging is a development package until the Python backend runtime is
  bundled; the built app is verified with `ROBO_BACKEND_DIR` in this checkout.
