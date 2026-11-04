#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
docker compose exec -T api python -m server.manage backup "/backups/daily-$(date -u +%Y%m%dT%H%M%S).sqlite"
# Keep the newest 30 daily copies; pre-deployment copies are retained separately.
docker compose exec -T api python -c 'from pathlib import Path; files=sorted(Path("/backups").glob("daily-*.sqlite")); [p.unlink() for p in files[:-30]]'
