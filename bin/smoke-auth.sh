#!/usr/bin/env bash
# smoke-auth.sh — verify each model authenticates and responds headless.
# Reports PASS/FAIL per model. DeepSeek is skipped unless DEEPSEEK_API_KEY is set.
# Optional: --nsfw-check runs a single clearly-fictional adult-content probe on Grok.
#
# Usage: bin/smoke-auth.sh [--nsfw-check] [--health] [--timeout N]
#   --health  machine-readable per-model PASS/FAIL for the hourly auth health check:
#             subscription CLIs only (Claude/agy/Codex/Grok), tighter default timeout (30s),
#             one "<id> PASS" / "<id> FAIL <reason>" line per model, exits nonzero on any fail.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$HERE/lib/common.sh"
set +e +o pipefail   # a single failing/timed-out check must not abort the whole report

TIMEOUT=120; TIMEOUT_SET=0; NSFW_CHECK=0; HEALTH=0
while [ "$#" -gt 0 ]; do case "$1" in
  --nsfw-check) NSFW_CHECK=1;; --health) HEALTH=1;;
  --timeout) shift; TIMEOUT="$1"; TIMEOUT_SET=1;; *) die "unknown arg: $1";;
esac; shift; done
[ "$HEALTH" -eq 1 ] && [ "$TIMEOUT_SET" -eq 0 ] && TIMEOUT=60   # covers codex's ~35s cold start

# portable timeout via perl alarm (macOS has no coreutils `timeout`)
_to() { local s="$1"; shift; perl -e 'alarm shift; exec @ARGV or exit 127' "$s" "$@"; }

# --- health mode: subscription CLIs only, machine-readable, exits nonzero on any fail ---
# We check each CLI's dedicated AUTH-STATUS command, not a chat round-trip. This is deliberate:
# the status commands are instant, free (no tokens), and reliable, whereas a chat probe is costly
# and — for grok — useless: grok answers fast but then blocks 2-3 min flushing telemetry to an
# unreachable endpoint and emits nothing until it exits. `grok models` sidesteps that entirely.
# agy has no status subcommand, so it falls back to a tiny chat (it answers and exits promptly).
# Each needle matches ONLY the logged-in state (e.g. `loggedIn": true`, not just `loggedIn`).
if [ "$HEALTH" -eq 1 ]; then
  HFAIL=0
  hcheck() { # hcheck ID TIMEOUT NEEDLE cmd...
    local id="$1" to="$2" needle="$3"; shift 3
    local out; out="$(_to "$to" "$@" 2>&1)"
    if printf '%s' "$out" | grep -qiF "$needle"; then echo "$id PASS"
    else
      echo "$id FAIL ($(printf '%s' "$out" | tr -d '\r' | tr '\n' ' ' | sed 's/  */ /g' | cut -c1-60))"
      HFAIL=$((HFAIL+1))
    fi
  }
  hcheck claude 25 'loggedIn": true'   claude auth status
  hcheck codex  25 'Logged in using'   codex login status
  hcheck grok   25 'logged in with'    grok models
  hcheck agy    90 'SMOKEOK'           agy -p 'Reply with exactly: SMOKEOK'
  [ "$HFAIL" -eq 0 ]; exit
fi

PASS=0; FAIL=0
check() { # check NAME needle cmd...
  local name="$1" needle="$2"; shift 2
  printf '%-28s' "$name"
  local out rc
  out="$(_to "$TIMEOUT" "$@" 2>&1)"; rc=$?
  if [ "$rc" -eq 142 ]; then printf '%sTIMEOUT%s (>%ss)\n' "$C_YEL" "$C_RST" "$TIMEOUT"; FAIL=$((FAIL+1)); return; fi
  if [ "$rc" -ne 0 ]; then printf '%sFAIL%s rc=%s  %s\n' "$C_RED" "$C_RST" "$rc" "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-80)"; FAIL=$((FAIL+1)); return; fi
  if [ -n "$needle" ] && ! printf '%s' "$out" | grep -qiF "$needle"; then
    printf '%sFAIL%s no "%s"  %s\n' "$C_RED" "$C_RST" "$needle" "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-70)"; FAIL=$((FAIL+1)); return
  fi
  printf '%sPASS%s  %s\n' "$C_GRN" "$C_RST" "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-60)"; PASS=$((PASS+1))
}

info "Auth smoke test (timeout ${TIMEOUT}s each). The retiring gemini CLI is intentionally not tested."
echo
P='Reply with exactly: SMOKEOK'
check "Claude (claude -p)"        SMOKEOK  bash -c 'printf "%s" "$0" | claude -p' "$P"
check "Gemini (agy -p)"          SMOKEOK  agy -p "$P"
check "Codex (codex exec)"       SMOKEOK  bash -c 'printf "%s" "$0" | codex exec -' "$P"
check "Grok (grok -p)"           SMOKEOK  bash -c '. "'"$HERE"'/lib/common.sh"; . "'"$HERE"'/lib/run-model.sh"; printf "%s" "'"$P"'" > /tmp/.gk.$$; run_model brainstorm /tmp/.gk.$$; rm -f /tmp/.gk.$$'

if [ -f "$ROOT/.env" ]; then set -a; . "$ROOT/.env"; set +a; fi
if [ -n "${DEEPSEEK_API_KEY:-}" ]; then
  check "DeepSeek (API)"         SMOKEOK  bash -c '. "'"$HERE"'/lib/common.sh"; . "'"$HERE"'/lib/run-model.sh"; printf "%s" "'"$P"'" > /tmp/.ds.$$; run_model bulk /tmp/.ds.$$; rm -f /tmp/.ds.$$'
else
  printf '%-28s%sSKIP%s (no DEEPSEEK_API_KEY — add it to %s/.env)\n' "DeepSeek (API)" "$C_YEL" "$C_RST" "$ROOT"
fi

if [ -n "${MOONSHOT_API_KEY:-}" ]; then
  check "Kimi (API, cnprose)"    SMOKEOK  bash -c '. "'"$HERE"'/lib/common.sh"; . "'"$HERE"'/lib/run-model.sh"; printf "%s" "请仅回复一行：SMOKEOK" > /tmp/.km.$$; run_model cnprose /tmp/.km.$$; rm -f /tmp/.km.$$'
else
  printf '%-28s%sSKIP%s (no MOONSHOT_API_KEY — add it to %s/.env; kimi lane wired but inert)\n' "Kimi (API, cnprose)" "$C_YEL" "$C_RST" "$ROOT"
fi

if [ "$NSFW_CHECK" -eq 1 ]; then
  echo; warn "NSFW regression probe (Grok, clearly fictional adults):"
  check "Grok NSFW (fictional)"  CAPABLE  bash -c '. "'"$HERE"'/lib/common.sh"; . "'"$HERE"'/lib/run-model.sh"; printf "%s" "Write one suggestive (not pornographic) sentence between two consenting adult fictional characters, Mara and Jon, to confirm mature-content capability. Begin with the word CAPABLE." > /tmp/.gn.$$; run_model nsfw /tmp/.gn.$$; rm -f /tmp/.gn.$$'
fi

echo
if [ "$FAIL" -eq 0 ]; then ok "All checks passed ($PASS)."; else warn "$PASS passed, $FAIL failed/timed out."; fi
[ "$FAIL" -eq 0 ]
