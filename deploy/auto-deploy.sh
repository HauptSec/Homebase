#!/usr/bin/env bash
set -Eeuo pipefail
main() {
  cd "$(dirname "${BASH_SOURCE[0]}")/.."
  umask 077
  exec 9>.git/homebase-deploy.lock
  flock -n 9 || return 0
  export GIT_TERMINAL_PROMPT=0
  git fetch --quiet origin main
  local target deployed
  target=$(git rev-parse origin/main)
  deployed=$(cat .git/homebase-deployed 2>/dev/null || true)
  [[ "$target" != "$deployed" || "${1:-}" == --force ]] || return 0
  if ! curl --fail --silent --show-error --max-time 30 "https://api.github.com/repos/HauptSec/Homebase/actions/workflows/ci.yml/runs?head_sha=${target}&event=push&per_page=1" |
    python3 -c 'import json,sys; r=json.load(sys.stdin).get("workflow_runs",[]); sys.exit(0 if r and r[0]["head_sha"]==sys.argv[1] and r[0]["conclusion"]=="success" else 1)' "$target"; then
    echo 'Waiting for successful CI; current deployment remains running.'
    return 0
  fi
  git reset --quiet --hard "$target"
  mkdir -p secrets
  chmod 700 secrets
  if [[ ! -e secrets/apns.p8 ]]; then touch secrets/apns.p8; chmod 644 secrets/apns.p8; fi
  docker compose config --quiet
  docker compose build api
  if [[ -n "$(docker compose ps --status running -q api)" ]]; then
    docker compose exec -T api python -m server.manage backup "/backups/predeploy-$(date -u +%Y%m%dT%H%M%S).sqlite"
  fi
  docker compose up -d --no-build --wait --wait-timeout 180 api
  printf '%s\n' "$target" > .git/homebase-deployed.tmp
  mv .git/homebase-deployed.tmp .git/homebase-deployed
  echo "Homebase healthy at $target"
}
main "$@"
