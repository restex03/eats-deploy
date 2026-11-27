#!/usr/bin/env bash
set -euo pipefail

# Start only development PostgreSQL; run ingestion separately with dotnet run.
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
environment_file="$repository_root/.env"

if [[ ! -f "$environment_file" ]]; then
    echo "Missing $environment_file" >&2
    echo "Copy .env.dev.example to .env and configure it first." >&2
    exit 1
fi

docker compose \
    --project-directory "$repository_root" \
    --file "$repository_root/compose.yaml" \
    --file "$repository_root/compose.dev.yaml" \
    --env-file "$environment_file" \
    up -d postgres
