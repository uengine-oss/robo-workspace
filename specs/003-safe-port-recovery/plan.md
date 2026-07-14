# Plan

1. Separate launcher and listener timestamps in the persisted state contract.
2. Centralize PID/start-time identity validation and use it for status/stop.
3. Add explicit profile-port cleanup for recovery from manually opened servers.
4. Improve port-conflict diagnostics and document the safe/forced distinction.
5. Exercise owned, mismatched, and forced cleanup paths with isolated listeners.
6. Compose Analyzer and Architect browser services into one `all` profile and
   verify real UI, Gateway, and Catalog-backed endpoints.
