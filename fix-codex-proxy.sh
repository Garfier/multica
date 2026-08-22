#!/usr/bin/env bash
# Fix: codex agents on clouddatabase011123145080 cannot reach chatgpt.com
# (daemon restarted 08-09 18:00 without proxy env; direct connection is blocked).
# Injects the tunnel-proxy env (127.0.0.1:8089 -> 47.245.92.199) into the
# custom_env of the 3 agents bound to the local Codex runtime.
#
# MUST be run with a member (human) login, e.g.:
#   multica --profile sam login            # if your default profile is an agent token
#   bash fix-codex-proxy.sh
set -euo pipefail

ENV_FILE="$(cd "$(dirname "$0")" && pwd)/codex-proxy-env.json"
# Resolve the multica binary: explicit override > PATH > local server build
if [ -n "${MULTICA_BIN:-}" ]; then
  MULTICA="$MULTICA_BIN"
elif command -v multica >/dev/null 2>&1; then
  MULTICA="$(command -v multica)"
elif [ -x /data/sam.liux/workspace/multica/server/bin/multica ]; then
  MULTICA=/data/sam.liux/workspace/multica/server/bin/multica
else
  echo "multica binary not found; set MULTICA_BIN=/path/to/multica" >&2
  exit 1
fi
echo "using $MULTICA"

AGENTS=(
  "3b4eee19-aa5d-4bfe-b0f2-23b54df61979" # Codex Developer
  "267b1ebb-53c5-4031-a52d-13343ba46655" # Skill Dev Loop Developer
  "783df014-eae1-4665-838e-3d5250734f9c" # Skill Dev Loop Reviewer Codex
)

for id in "${AGENTS[@]}"; do
  echo "== setting custom_env for $id"
  "$MULTICA" agent env set "$id" --custom-env-file "$ENV_FILE" --output json >/dev/null
  "$MULTICA" agent env get "$id" --output json | jq -r 'keys_unsorted | "   keys: " + join(", ")'
done
echo "done. Re-trigger by commenting on the issue (e.g. DAT-1943)."
