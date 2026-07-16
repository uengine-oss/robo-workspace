# Reservation-safe fixed ports

## Goal

Run the complete local browser stack alongside Docker/WSL without terminating
Windows networking services or racing Windows excluded-port reservations.

## Contract

- Analyzer uses 15502, Catalog uses 15503, the Analyzer federation remote uses
  15001, and Architect web uses 15173.
- Workspace passes the Analyzer and Catalog URLs to Gateway and passes the
  Analyzer MCP and federation URLs to Architect.
- `up all`, health checks, status output, and documentation use the same fixed
  ports.
- Docker profile container ports remain unchanged.

## Failure scenarios

- A real listener on a fixed port remains an explicit conflict and may only be
  terminated with `-ForcePorts`.
- Windows networking services, Docker, WSL, and Neo4j are never stopped to
  recover application ports.
