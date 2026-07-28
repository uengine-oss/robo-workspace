# Robo Architect Electron release

## User experience

The deliverable is one Windows installer:

`Robo-Architect-Setup-<release-id>.exe`

The target PC needs Docker Desktop. It does not need Git, Node.js, Java,
Python, uv, Neo4j Desktop, or a source checkout. On launch, Electron verifies
the embedded release manifest, scoped service environments, and image archive;
starts the app-owned Compose project; registers the bundled Neo4j connection;
and starts the bundled Architect API on Windows.

An ordinary app exit stops only the local Architect API. Docker services stay
warm for a fast next launch. Neo4j data is stored in a named Docker volume and
is not deleted by an app restart or normal uninstall.

## Build

On the build PC, install Git, Node.js, uv, and Docker Desktop. From a clean,
committed Workspace checkout:

```cmd
robo.cmd release architect-electron
```

The command clones or fast-forward synchronizes missing release repositories,
initializes Architect-pinned submodules, installs missing Node dependencies,
builds the pinned service images, creates an offline image archive, builds the
relocatable Architect Python runtime and co-located frontend, packages the NSIS
installer, and writes:

```text
_releases/<release-id>/
  Robo-Architect-Setup-<release-id>.exe
  runtime-manifest.json
  SHA256SUMS
```

The release command rejects dirty repositories and submodule pointer
mismatches. The manifest records every source commit, exact Docker image ID,
the SHA-256 of the offline image archive, and every scoped environment file
checksum. Runtime startup rejects an archive, local image, or environment
snapshot whose identity does not match that manifest.

## Environment

`robo-workspace/.env` is the single release-time environment source. A fresh
Workspace copies `.env.example`, which already selects the internal GPU stack:

```dotenv
ROBO_LLM_CONFIG=qwen36_sglang_local
ROBO_LLM_API_KEY=<internal-key>
LLM_PROVIDER=openai
LLM_MODEL=frentis-ai-model
OPENAI_BASE_URL=http://ai-server.dream-flow.com:30000/v1
OPENAI_API_KEY=<internal-key>
```

The release command splits this input into least-privilege Analyzer, Catalog,
Data Fabric, Parser, Gateway, and Architect snapshots. Development Neo4j
credentials, source paths, bind ports, and inter-service URLs are not copied;
Electron and Compose own those values.

The internal GPU credential is embedded so the installed product works
immediately. It is not committed or printed, but an installer recipient can
extract it. Treat the installer as an internal artifact and rotate the
credential if it leaves its intended audience.

## Local project ingress and DDL classification

The installed Electron app never passes a Windows absolute project path to a
Linux container. When a user selects one project folder, Electron main reads
ordinary files under that root, preserves their relative paths, skips generated
directories such as `.git`, `node_modules`, `dist`, and `target`, and sends one
multipart request through the app-owned Gateway.

Parser remains the single classification authority:

- non-SQL files are source;
- SQL containing procedure, function, package, trigger, or type declarations
  is source;
- SQL containing table, view, index, or sequence DDL is DDL.

Therefore the installed UI does not require a separate DDL picker. Source and
schema files can live anywhere below the selected project root.

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
    MindsDB
    ANTLR Parser
    API Gateway
```

The Architect API remains on Windows because project filesystem paths,
installed CLIs, IDE integration, and ConPTY are host capabilities. Data
services use Docker so they can be started, upgraded, and diagnosed as one
owned stack.

MindsDB is pinned and bundled in the offline image archive. It is internal to
the app-owned Docker network and persists connector state in its own named
volume. When a user enters `localhost` for a database running on Windows,
Data Fabric rewrites that host to `host.docker.internal`; databases in another
reachable network can use their normal hostname or IP.

## Verified baseline

The 2026-07-28 packaged-environment `shop_mall` test used generated snapshots,
not repository `.env` files:

- all six runtime services reached `healthy`;
- one Electron-equivalent folder ingress uploaded 13 files and Parser
  classified 12 C/H files as source and `shopmall_schema.sql` as one DDL file;
- Parser produced 12 exact AST files covering 12,344 lines, with no recovered,
  partial, unresolved, or failed file;
- Analyzer resolved `qwen36_sglang_local` to the internal `sglang` endpoint and
  `frentis-ai-model`, then completed LLM analysis in 365.1 seconds;
- the internal `BAAI/bge-m3` embedding pass completed for code, 22 tables, and
  153 columns;
- Neo4j contained 4,274 nodes and 11,586 relationships, including 127
  functions, 883 rules, 1,111 examples, and 305 code-to-table effects.

The smoke Compose project and its temporary volumes were removed afterward.
