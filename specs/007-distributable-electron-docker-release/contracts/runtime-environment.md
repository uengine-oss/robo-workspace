# Runtime environment contract

## Source

`robo-workspace/.env` is the only release-time environment source. Ignored
`.env` files inside service repositories are development inputs and MUST NOT
change a release.

## Required internal GPU values

- `ROBO_LLM_CONFIG`
- `ROBO_LLM_API_KEY`
- `LLM_PROVIDER`
- `LLM_MODEL`
- `OPENAI_BASE_URL`
- `OPENAI_API_KEY`

The committed `.env.example` selects `qwen36_sglang_local`,
`frentis-ai-model`, and the internal OpenAI-compatible SGLang endpoint.

## Service scopes

| Snapshot | Accepted keys |
|---|---|
| `config/analyzer.env` | `ROBO_LLM_*`, `ROBO_EMBED_*`, `ROBO_SEARCH_*`, `ROBO_CACHE_*`, `ROBO_AGENT_*`, `ROBO_BUDGET_*`, `ROBO_PIPELINE_*`, `ROBO_CATALOG_*`, `ROBO_RUNTIME_*`, `ROBO_RUN_OUTPUT_DIR`, `ROBO_SEM_*`, `ROBO_GLOSSARY_*` |
| `config/catalog.env` | `LLM_*`, `OPENAI_API_KEY`, `EMBEDDING_*`, `FK_*`, `METADATA_*`, `CATALOG_*` |
| `config/fabric.env` | `MINDSDB_*` except URL/host/port topology, `OPENAI_API_KEY`, `DATA_FABRIC_*` |
| `config/parser.env` | `PARSER_*`, `JAVA_*` |
| `config/gateway.env` | `GATEWAY_*`, `SPRING_*` |
| bundled Architect `.env` | `LLM_*`, `OPENAI_*`, `ANTHROPIC_*`, `GOOGLE_*`, `CHANGE_PROPAGATION_*`, `GENERATION_*`, `INGESTION_*` |

## Runtime overrides

The following are deployment topology, not copied configuration:

- all `ROBO_NEO4J_*` and `NEO4J_*`
- `ROBO_DATA_DIR`
- service bind ports and inter-service URLs
- `MINDSDB_URL`, `MINDSDB_HOST`, and `MINDSDB_API_PORT`
- Electron-generated Neo4j password

Compose/Electron supplies these values after loading snapshots, so a developer
path or database password can never leak into the packaged topology.

## Integrity and disclosure

The manifest records SHA-256 for every snapshot, but never its contents.
Electron rejects missing or modified snapshots before Compose startup. Snapshot
values are never logged. Because the installer necessarily contains the
internal API credential needed for immediate use, this installer is an
internal-distribution artifact and the credential is extractable by its
recipient.
