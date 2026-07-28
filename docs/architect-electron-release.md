# Robo Architect Electron release

## User experience

The deliverable is one Windows installer:

`Robo-Architect-Setup-<release-id>.exe`

The target PC needs Docker Desktop. It does not need Git, Node.js, Java,
Python, uv, Neo4j Desktop, or a source checkout. On launch, Electron verifies
the embedded release manifest and image archive, starts the app-owned Compose
project, registers the bundled Neo4j connection, and starts the bundled
Architect API on Windows.

An ordinary app exit stops only the local Architect API. Docker services stay
warm for a fast next launch. Neo4j data is stored in a named Docker volume and
is not deleted by an app restart or normal uninstall.

## Build

From a clean, committed Workspace and clean Architect-pinned submodules:

```cmd
robo.cmd release architect-electron
```

The command builds the pinned service images, creates an offline image archive,
builds the relocatable Architect Python runtime and co-located frontend,
packages the NSIS installer, and writes:

```text
_releases/<release-id>/
  Robo-Architect-Setup-<release-id>.exe
  runtime-manifest.json
  SHA256SUMS
```

The release command rejects dirty repositories and submodule pointer
mismatches. The manifest records every source commit, exact Docker image ID,
and the SHA-256 of the offline image archive. Runtime startup rejects an
archive or local image whose identity does not match that manifest.

## Runtime topology

```text
Robo Architect.exe
  Electron + Vue frontend
  bundled CPython + Architect FastAPI (Windows host)
  Docker Compose
    Neo4j
    Analyzer
    Catalog
    Data Fabric
    ANTLR Parser
    API Gateway
```

The Architect API remains on Windows because project filesystem paths,
installed CLIs, IDE integration, and ConPTY are host capabilities. Data
services use Docker so they can be started, upgraded, and diagnosed as one
owned stack.
