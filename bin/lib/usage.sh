#!/usr/bin/env bash
# usage.sh — per-lane usage/balance probes + aggregator for the five lanes.
# Sourced by bin/usage and bin/host-runner-health. Mirrors smoke-auth.sh's
# conventions (portable _to timeout, $ROOT, color/log helpers, .env-sourced key).
#
# The gating research (DEVLOG ★ usage feature) found:
#   - DeepSeek : GET /user/balance → the real $ budget (definitive).  [this file]
#   - Claude   : per-call spend via `claude -p --output-format json`.  [run-model.sh]
#   - Codex    : per-call spend via `codex exec --json`.               [run-model.sh]
#   - Gemini/agy + Grok : NO headless usage surface → honest N/A.
# So "spent" is tallied from OUR own run-log ledger (sidecars written by run-model.sh,
# aggregated per conduct run into usage-ledger.jsonl), and the one true "budget left"
# number is DeepSeek's balance. Subscription remaining-quota is interactive-only this round.
#
# Never print DEEPSEEK_API_KEY — read it from env only (like the dispatch in run-model.sh).

# portable timeout via perl alarm (macOS has no coreutils `timeout`)
command -v _to >/dev/null 2>&1 || _to() { local s="$1"; shift; perl -e 'alarm shift; exec @ARGV or exit 127' "$s" "$@"; }

USAGE_LOGDIR="$ROOT/orchestration/logs"
USAGE_LEDGER="$USAGE_LOGDIR/usage-ledger.jsonl"   # per-step records appended by conduct_finalize
USAGE_SNAPSHOT="$USAGE_LOGDIR/usage.json"         # latest aggregated snapshot (gitignored)
USAGE_HEALTH="$USAGE_LOGDIR/health.json"          # auth status, written by host-runner-health

# usage_ledger_append <ts> <job> <sid> <lane> <total_tokens|null> <cost|null>
# Append one per-step record to the ledger (called from conduct_finalize). bash 3.2 safe.
usage_ledger_append() {
  mkdir -p "$USAGE_LOGDIR"
  local ts="$1" job="$2" sid="$3" lane="$4" tok="$5" cost="$6"
  [ -n "$tok" ]  || tok=null
  [ -n "$cost" ] || cost=null
  printf '{"ts":"%s","job":"%s","sid":"%s","lane":"%s","total_tokens":%s,"cost_usd_est":%s}\n' \
    "$ts" "$job" "$sid" "$lane" "$tok" "$cost" >> "$USAGE_LEDGER"
}

# usage_deepseek_balance — print the balance JSON to stdout (or an {error/skip} object).
# Reads DEEPSEEK_API_KEY from env/.env; the key is NEVER echoed.
usage_deepseek_balance() {
  [ -f "$ROOT/.env" ] && { set -a; . "$ROOT/.env"; set +a; }
  if [ -z "${DEEPSEEK_API_KEY:-}" ]; then
    printf '{"status":"skip","note":"no DEEPSEEK_API_KEY"}\n'; return 0
  fi
  local out
  out="$(_to 25 curl -sS https://api.deepseek.com/user/balance \
           -H "Authorization: Bearer $DEEPSEEK_API_KEY" -H 'Accept: application/json' 2>/dev/null)"
  if [ -z "$out" ]; then printf '{"status":"error","note":"no response"}\n'; return 0; fi
  # normalize to a flat object; never echo the key
  printf '%s' "$out" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    bi = (d.get("balance_infos") or [{}])[0]
    print(json.dumps({"status": "ok",
                      "available": d.get("is_available"),
                      "total_balance": bi.get("total_balance"),
                      "currency": bi.get("currency"),
                      "granted_balance": bi.get("granted_balance"),
                      "topped_up_balance": bi.get("topped_up_balance")}))
except Exception as e:
    print(json.dumps({"status": "error", "note": str(e)[:80]}))
' 2>/dev/null || printf '{"status":"error","note":"parse"}\n'
}

# usage_kimi_balance — print Kimi/Moonshot balance JSON (or {skip/error}). CNY.
# Endpoint: <KIMI_BASE_URL>/users/me/balance → {data:{available_balance,...}}. Key never echoed.
usage_kimi_balance() {
  [ -f "$ROOT/.env" ] && { set -a; . "$ROOT/.env"; set +a; }
  if [ -z "${MOONSHOT_API_KEY:-}" ]; then
    printf '{"status":"skip","note":"no MOONSHOT_API_KEY"}\n'; return 0
  fi
  local base="${KIMI_BASE_URL:-https://api.moonshot.ai/v1}" out
  out="$(_to 25 curl -sS "${base%/}/users/me/balance" \
           -H "Authorization: Bearer $MOONSHOT_API_KEY" -H 'Accept: application/json' 2>/dev/null)"
  if [ -z "$out" ]; then printf '{"status":"error","note":"no response"}\n'; return 0; fi
  printf '%s' "$out" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    data = d.get("data") or {}
    bal = data.get("available_balance")
    if isinstance(bal, (int, float)): bal = round(bal, 2)
    print(json.dumps({"status": "ok", "available": bool(d.get("status")),
                      "total_balance": bal, "currency": "CNY"}))
except Exception as e:
    print(json.dumps({"status": "error", "note": str(e)[:80]}))
' 2>/dev/null || printf '{"status":"error","note":"parse"}\n'
}

# usage_snapshot_json [since_days] — assemble + print the full lane snapshot JSON.
# Combines: our ledger tally (spent + cached), DeepSeek + Kimi live balances, auth status.
usage_snapshot_json() {
  local since="${1:-0}" bal kbal
  bal="$(usage_deepseek_balance)"
  kbal="$(usage_kimi_balance)"
  USAGE_LEDGER="$USAGE_LEDGER" USAGE_HEALTH="$USAGE_HEALTH" USAGE_SINCE="$since" KIMI_BAL="$kbal" \
  python3 - "$bal" <<'PY'
import json, os, sys, datetime

balance = {}
try:
    balance = json.loads(sys.argv[1])
except Exception:
    balance = {"status": "error"}
kbalance = {}
try:
    kbalance = json.loads(os.environ.get("KIMI_BAL", "") or "{}")
except Exception:
    kbalance = {"status": "error"}

# --- tally "spent" per lane from our run-log ledger ---
spent = {}   # lane -> {tokens, cost, calls}
ledger = os.environ.get("USAGE_LEDGER", "")
since_days = float(os.environ.get("USAGE_SINCE", "0") or 0)
cutoff = None
if since_days > 0:
    cutoff = datetime.datetime.now().astimezone() - datetime.timedelta(days=since_days)
if ledger and os.path.exists(ledger):
    for line in open(ledger):
        line = line.strip()
        if not line:
            continue
        try:
            r = json.loads(line)
        except Exception:
            continue
        if cutoff is not None:
            try:
                if datetime.datetime.fromisoformat(r["ts"]) < cutoff:
                    continue
            except Exception:
                pass
        lane = r.get("lane", "?")
        s = spent.setdefault(lane, {"tokens": 0, "cached": 0, "cost": 0.0, "calls": 0, "has_cost": False})
        t = r.get("total_tokens")
        if isinstance(t, (int, float)):
            s["tokens"] += t
        cr = r.get("cached_tokens")
        if isinstance(cr, (int, float)):
            s["cached"] += cr
        c = r.get("cost_usd_est")
        if isinstance(c, (int, float)):
            s["cost"] += c
            s["has_cost"] = True
        s["calls"] += 1

# --- auth status per lane from health.json (if present) ---
auth = {}
hp = os.environ.get("USAGE_HEALTH", "")
if hp and os.path.exists(hp):
    try:
        auth = (json.load(open(hp)) or {}).get("results", {}) or {}
    except Exception:
        auth = {}

# lane -> (label, plan, remaining-note)
LANES = [
    ("claude",   "Claude",   "max",        "remaining: interactive /usage only"),
    ("codex",    "Codex",    "ChatGPT",    "remaining: spend-only this round"),
    ("agy",      "Gemini",   "google",     "N/A — not CLI-exposed"),
    ("grok",     "Grok",     "SuperGrok",  "N/A — SuperGrok not CLI-exposed"),
    ("deepseek", "DeepSeek", "API",        "budget = live balance"),
    ("kimi",     "Kimi",     "API",        "budget = live balance (CNY); cost ¥ est"),
]

lanes_out = {}
for key, label, plan, note in LANES:
    s = spent.get(key, {})
    row = {
        "label": label,
        "plan": plan,
        "spent_tokens": (s.get("tokens") if s else None),
        "cached_tokens": (s.get("cached") if s else None),
        "spent_usd_est": (round(s["cost"], 4) if s and s.get("has_cost") else None),
        "calls": (s.get("calls") if s else 0),
        "budget_left": None,
        "currency": None,
        "status": auth.get(key, "?"),
        "note": note,
    }
    if key == "deepseek":
        if balance.get("status") == "ok":
            row["budget_left"] = balance.get("total_balance")
            row["currency"] = balance.get("currency")
            row["status"] = "ok" if balance.get("available") else "unavailable"
        elif balance.get("status") == "skip":
            row["status"] = "skip"
            row["note"] = balance.get("note", note)
        else:
            row["status"] = "error"
    elif key == "kimi":
        if kbalance.get("status") == "ok":
            row["budget_left"] = kbalance.get("total_balance")
            row["currency"] = kbalance.get("currency")
            row["status"] = "ok" if kbalance.get("available") else "unavailable"
        elif kbalance.get("status") == "skip":
            row["status"] = "skip"
            row["note"] = kbalance.get("note", note)
        else:
            row["status"] = "error"
    lanes_out[key] = row

print(json.dumps({
    "ts": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
    "since_days": since_days,
    "lanes": lanes_out,
}, indent=2))
PY
}

# usage_write_snapshot [since_days] — refresh the cached snapshot file. Prints the path.
usage_write_snapshot() {
  mkdir -p "$USAGE_LOGDIR"
  usage_snapshot_json "${1:-0}" > "$USAGE_SNAPSHOT" 2>/dev/null
  printf '%s\n' "$USAGE_SNAPSHOT"
}
