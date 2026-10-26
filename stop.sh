#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
docker compose down
echo 'LongCat containers stopped; model files and job videos remain under ./data.'
