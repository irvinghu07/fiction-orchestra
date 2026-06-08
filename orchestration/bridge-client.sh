#!/usr/bin/env sh
# ⚠️ FALLBACK PATH (not the live route as of 2026-06-03). Part of the file-drop bridge, superseded by the MCP
#    server (bin/host-mcp). Kept for rollback only. See DEPLOY.md §rollback.
# bridge-client.sh — runs INSIDE the OpenClaw container. Delegates a model call to the
# host's first-party CLIs via the mounted bridge dir. Host side: bin/host-runner.
# The host enforces the NSFW firewall, so the container never handles explicit prose for
# a moderated role.
#
# Usage: bridge-client <role> <instruction> [repo-relative-target ...]
#   roles: conduct  prose|audit  continuity  structure  brainstorm|inspire|nsfw  bulk
#   conduct = the Orchestration Conductor (host Sonnet→Opus): one request, many models, one artifact.
set -eu
BRIDGE="${BRIDGE_DIR:-/workspace/bridge}"
TIMEOUT="${BRIDGE_TIMEOUT:-180}"
[ "$#" -ge 2 ] || { echo "usage: bridge-client <role> <instruction> [target ...]" >&2; exit 2; }
ROLE="$1"; INSTR="$2"; shift 2
# the conductor orchestrates several models (incl. slow Grok ~2-3min) — give it a long default.
if [ "$ROLE" = conduct ] && [ -z "${BRIDGE_TIMEOUT:-}" ]; then TIMEOUT=1800; fi
mkdir -p "$BRIDGE/inbox" "$BRIDGE/outbox"
ID="job-$(date +%s)-$$"
export JOB="$BRIDGE/inbox/$ID.json"
# write JSON safely + atomically (tmp then rename) so host-runner never reads a partial file
node -e 'const fs=require("fs");const a=process.argv.slice(1);const[role,instr,...t]=a;const tmp=process.env.JOB+".tmp";fs.writeFileSync(tmp,JSON.stringify({role,instruction:instr,targets:t}));fs.renameSync(tmp,process.env.JOB)' "$ROLE" "$INSTR" "$@"
# poll outbox
i=0
while [ "$i" -lt "$TIMEOUT" ]; do
  if [ -f "$BRIDGE/outbox/$ID.txt" ]; then cat "$BRIDGE/outbox/$ID.txt"; exit 0; fi
  if [ -f "$BRIDGE/outbox/$ID.err" ]; then echo "BRIDGE ERROR:" >&2; cat "$BRIDGE/outbox/$ID.err" >&2; exit 1; fi
  sleep 1; i=$((i+1))
done
echo "bridge-client: timed out after ${TIMEOUT}s (is bin/host-runner running on the host?)" >&2
exit 1
