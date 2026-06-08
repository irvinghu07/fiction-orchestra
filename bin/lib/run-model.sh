#!/usr/bin/env bash
# run-model.sh — the single choke point that dispatches a prompt to a model.
# Enforces: (1) NSFW leak guard before any moderated-model call (fail-closed),
# (2) first-party-only invocation (no proxies), (3) the role->CLI mapping.
#
# Usage:  run_model <role> <prompt-file>
# Prints the model's response to stdout. Exits non-zero on leak-guard trip or auth error.
#
# Per-run usage capture (opt-in, ToS-clean): if $USAGE_SINK is set, the dispatcher
# also writes that call's token/cost usage as JSON to $USAGE_SINK. stdout stays the
# model's PROSE (text only) so every downstream reader is unchanged. We get this for
# free from the same first-party commands' JSON output — Claude `--output-format json`,
# `codex exec --json`, and the DeepSeek API `usage` block. agy/grok expose no headless
# usage, so they write an honest N/A stub. (See DEVLOG ★ usage feature.)

# leak_guard <prompt-file> — abort if explicit content would reach a moderated model
_leak_guard() {
  local pf="$1"
  if grep -qF "$NSFW_MARKER" "$pf" 2>/dev/null; then
    die "LEAK GUARD: prompt contains the explicit marker ($NSFW_MARKER) but targets a MODERATED model. Refusing to send. (This protects your Claude/Codex/Gemini/DeepSeek accounts.)"
  fi
  if [ -f "$NSFW_DENYLIST" ] && [ -s "$NSFW_DENYLIST" ]; then
    local term
    while IFS= read -r term; do
      [ -z "$term" ] && continue
      case "$term" in \#*) continue;; esac
      if grep -qiF -- "$term" "$pf" 2>/dev/null; then
        die "LEAK GUARD: prompt matches denylisted term while targeting a MODERATED model. Refusing to send."
      fi
    done < "$NSFW_DENYLIST"
  fi
}

# Guard against accidentally proxying Claude/etc. (brief §5 ToS).
_assert_first_party() {
  case "$1" in
    claude)
      if [ -n "${ANTHROPIC_BASE_URL:-}" ]; then
        die "ToS GUARD: ANTHROPIC_BASE_URL is set — Claude must be first-party only. Unset it."
      fi
      if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
        warn "note: ANTHROPIC_API_KEY is set; ensure claude -p uses first-party Max auth, not a key/proxy."
      fi ;;
  esac
  return 0   # never let this guard's last test abort run_model under set -e
}

# _usage_na <lane> — write an honest "no headless usage" sidecar (agy/grok, or failures).
_usage_na() {
  [ -n "${USAGE_SINK:-}" ] || return 0
  USAGE_LANE="$1" python3 - "$USAGE_SINK" <<'PY' 2>/dev/null || true
import json, os, sys, datetime
sink = sys.argv[1]
rec = {"lane": os.environ.get("USAGE_LANE", "?"), "total_tokens": None,
       "cost_usd_est": None, "note": "N/A — not CLI-exposed",
       "ts": datetime.datetime.now().astimezone().isoformat(timespec="seconds")}
open(sink, "w").write(json.dumps(rec))
PY
}

# _stage_sfw_workspace — build an SFW-ONLY mirror of the story tree for a MODERATED, filesystem-
# agentic CLI to run inside (agy, claude, codex — all read workspace files on their own; verified
# for agy & claude via a decoy `secret.md` probe). context.sh only firewalls the PROMPT, not the
# model's autonomous reads, so in the raw repo such a model could open manuscript/*.explicit.md
# directly → moderated-model leak (account-ban risk). Run it in a mirror where explicit/nsfw files
# are PHYSICALLY ABSENT instead. Sets $_SFW_SBX to the dir; returns non-zero (fail-closed) if any
# explicit/nsfw content survives, so the caller refuses to launch. Grok is EXEMPT (unmoderated —
# explicit is its job); kimi/deepseek don't need it (HTTP API, no filesystem). (DEVLOG S14/S15.)
_stage_sfw_workspace() {
  _SFW_SBX=""
  local sbx; sbx="$(mktemp -d "${TMPDIR:-/tmp}/sfw-sbx.XXXXXX")" || { warn "sfw sandbox: mktemp failed"; return 1; }
  cp -p "$ROOT/AGENTS.md" "$sbx/" 2>/dev/null || true
  [ -f "$ROOT/CLAUDE.md" ] && cp -p "$ROOT/CLAUDE.md" "$sbx/" 2>/dev/null
  [ -d "$ROOT/codex" ] && cp -Rp "$ROOT/codex" "$sbx/codex"
  [ -d "$ROOT/manuscript" ] && cp -Rp "$ROOT/manuscript" "$sbx/manuscript"
  # Strip symlinks FIRST: an innocently-named link could point at explicit content
  # outside the mirror and be followed by an agentic CLI; name-based strips below
  # match the link name, not its target, and `-type f` scans skip links entirely.
  find "$sbx" -type l -delete 2>/dev/null
  # Strip every explicit-by-filename file, then every nsfw-tagged-by-content codex/scene file.
  find "$sbx" -iname '*.explicit.md' -delete 2>/dev/null
  local f
  while IFS= read -r f; do file_is_nsfw_tagged "$f" && rm -f "$f"; done \
    < <(find "$sbx" -type f -name '*.md' 2>/dev/null)
  # FAIL-CLOSED firewall assertions — a moderated model's workspace must be provably clean.
  if find "$sbx" -type l 2>/dev/null | grep -q .; then
    rm -rf "$sbx"; warn "FIREWALL: symlink survived into sfw sandbox"; return 2
  fi
  if find "$sbx" \( -iname '*.explicit.md' -o -iname '*nsfw*' \) 2>/dev/null | grep -q .; then
    rm -rf "$sbx"; warn "FIREWALL: explicit/nsfw file survived into sfw sandbox"; return 2
  fi
  while IFS= read -r f; do
    file_is_nsfw_tagged "$f" && { rm -rf "$sbx"; warn "FIREWALL: nsfw-tagged file survived into sfw sandbox"; return 2; }
  done < <(find "$sbx" -type f -name '*.md' 2>/dev/null)
  _SFW_SBX="$sbx"; return 0
}

# Grok is a coding AGENT even in headless `-p` mode: on a non-trivial prompt it spends
# its turns on tool/plan actions and frequently never emits an answer (stopReason=Cancelled,
# empty stdout) — the Session-9 "Grok returned empty" bug. Overriding the system prompt
# strips that agent identity so Grok answers directly in ONE turn (stopReason=EndTurn).
# Kept neutral so it serves every Grok role (brainstorm / inspire / reader-grip / NSFW) and
# adds NO moderation. Pairs with --no-plan --no-subagents and the telemetry-off env.
GROK_SYSTEM_OVERRIDE="You are a creative-writing collaborator and editor, one specialist in a larger writers' room. You have no tools and cannot run commands, search the web, or read files — everything you need is already in the user's message. Respond directly and only in prose: do not plan, do not call tools, do not offer to take actions. Just give your answer."

# Grounding system prompt for the 中文 prose lane (Kimi). Counters Kimi's known tendency to
# fabricate canon: bind it tightly to the provided 设定集 (codex/synopsis), output prose only.
ZH_GROUNDING="你是简体中文小说创作合作者，写作组中的一名专家。严格遵循用户提供的设定集（codex/synopsis），不得杜撰任何设定、人物或情节事实；缺乏依据时请明确指出，不要编造。只输出散文正文，保持作者既有的语气与风格。"

run_model() {
  local role="$1" pf="$2" model rc=0
  [ -f "$pf" ] || die "run_model: prompt file not found: $pf"
  model="$(resolve_model "$role")"
  _assert_first_party "$model"

  if is_moderated_model "$model"; then
    _leak_guard "$pf"
  fi

  local prompt; prompt="$(cat "$pf")"
  info "→ dispatching to $(role_label "$role")  [model: $model]"

  case "$model" in
    claude)
      # CLAUDE_MODEL lets the conductor pin sonnet (planning) / opus (synthesis);
      # unset → claude -p uses its default. First-party Max auth either way.
      # --output-format json yields {result, usage, total_cost_usd}; we print .result
      # (the prose) and side-write usage. The CLI output is staged to a temp file so
      # rc reflects the CLI (not the parser) and the parser's program heredoc doesn't
      # collide with stdin.
      # FIREWALL (DEVLOG S15): claude -p reads its workspace files autonomously (verified — a decoy
      # secret.md leaks with permission_denials:[]), so run it in the SFW-only mirror, never the raw
      # repo (which holds *.explicit.md). Fail-closed if the sandbox can't be proven clean.
      _stage_sfw_workspace || die "FIREWALL: refusing to launch claude — could not guarantee an explicit-free workspace (see warning above)."
      local csbx="$_SFW_SBX"
      local ctmp; ctmp="$(mktemp)"
      if [ -n "${CLAUDE_MODEL:-}" ]; then
        ( cd "$csbx" && printf '%s' "$prompt" | claude -p --output-format json --model "$CLAUDE_MODEL" ) > "$ctmp"; rc=$?
      else
        ( cd "$csbx" && printf '%s' "$prompt" | claude -p --output-format json ) > "$ctmp"; rc=$?
      fi
      _emit_claude_json "$ctmp"; rm -f "$ctmp"; rm -rf "$csbx" ;;
    agy)
      # agy print mode has NO --model flag: it resolves the model from the persisted
      # label in ~/.gemini/antigravity-cli/settings.json ("model": "Gemini 3.1 Pro (High)"),
      # written by the TUI /model. With that key ABSENT it silently defaults to Gemini 3.5
      # Flash (Medium) — the old "agy is Flash-locked" misread. We capture agy's own log and
      # surface the model it ACTUALLY ran, so a post-`agy update` label drift (→ silent Flash
      # fallback) can't corrupt a continuity pass unnoticed. (See DEVLOG Session 13.)
      # AGY_EXPECT_MODEL pins the expected label (default tier-agnostic "Gemini 3.1 Pro",
      # so a High/Medium/Low tier change won't false-alarm but a Flash downgrade will).
      #
      # FIREWALL (DEVLOG S14): agy reads its workspace files autonomously, so run it in an
      # SFW-only mirror — never the raw repo (which holds *.explicit.md). Fail-closed: if the
      # sandbox can't be proven clean, refuse to launch the moderated model.
      _stage_sfw_workspace || die "FIREWALL: refusing to launch agy — could not guarantee an explicit-free workspace (see warning above)."
      local asbx="$_SFW_SBX"
      local alog="$asbx/.agy.log"
      ( cd "$asbx" && agy -p "$prompt" --log-file "$alog" ); rc=$?
      local agy_model
      agy_model="$(grep -F 'Propagating selected model override to backend' "$alog" 2>/dev/null \
                   | tail -1 | sed -E 's/.*label="([^"]*)".*/\1/')"
      if [ -n "$agy_model" ]; then
        info "  agy resolved model: $agy_model"
        local agy_expect="${AGY_EXPECT_MODEL:-Gemini 3.1 Pro}"
        case "$agy_model" in
          *"$agy_expect"*) : ;;
          *) warn "AGY MODEL DRIFT: expected '$agy_expect' but agy ran '$agy_model' — continuity result may be degraded. Re-pin via TUI /model or ~/.gemini/antigravity-cli/settings.json \"model\"; set AGY_EXPECT_MODEL to override." ;;
        esac
      else
        warn "agy: could not determine resolved model from its log (format change?) — proceeding UNVERIFIED."
      fi
      rm -rf "$asbx"
      _usage_na agy ;;
    codex)
      # codex exec --json streams JSONL: agent_message item(s) carry the prose,
      # the final turn.completed carries usage. Reconstruct text + side-write usage.
      # FIREWALL (DEVLOG S15): codex exec is an agentic coding CLI — it reads workspace files by
      # design. Run it in the SFW-only mirror, not the raw repo (*.explicit.md). --skip-git-repo-check
      # is required because the sandbox is a fresh tmpdir, not a trusted git workspace (codex refuses
      # untrusted dirs otherwise). Empirical decoy-probe was auth-blocked (codex login expired); this
      # sandbox is precautionary — re-confirm with a secret.md probe once `codex login` is refreshed.
      _stage_sfw_workspace || die "FIREWALL: refusing to launch codex — could not guarantee an explicit-free workspace (see warning above)."
      local xsbx="$_SFW_SBX"
      local xtmp; xtmp="$(mktemp)"
      ( cd "$xsbx" && printf '%s' "$prompt" | codex exec --json --skip-git-repo-check - ) > "$xtmp"; rc=$?
      _emit_codex_json "$xtmp"; rm -f "$xtmp"; rm -rf "$xsbx" ;;
    grok)
      # Telemetry-off env kills the ~2-3min Google-Cloud trace-upload hang on exit
      # (verified present in the 0.2.14 binary); --no-auto-update kills the update stall.
      # --output-format json → one object {text, thought, stopReason,…}; we print .text
      # (the answer). --system-prompt-override forces a single-turn prose answer (see above).
      # Stage to a temp file so rc reflects the CLI, not the parser.
      local gtmp; gtmp="$(mktemp)"
      GROK_TELEMETRY_ENABLED=false GROK_TELEMETRY_TRACE_UPLOAD=false DISABLE_TELEMETRY=1 \
      GROK_DISABLE_UPDATE_CHECK=1 \
      grok --no-auto-update -p "$prompt" --output-format json --disable-web-search \
           --no-plan --no-subagents --max-turns 4 \
           --system-prompt-override "$GROK_SYSTEM_OVERRIDE" </dev/null > "$gtmp"; rc=$?
      _emit_grok_json "$gtmp"; rm -f "$gtmp"
      _usage_na grok ;;
    deepseek)
      # Routed through the STREAMING _openai_chat (DeepSeek is OpenAI-compatible) — same fix as Kimi,
      # so a large/slow localization can't trip a blocking-read timeout. Model default pinned to
      # deepseek-v4-pro: the legacy `deepseek-chat` alias now silently resolves to the weaker
      # deepseek-v4-flash (verified via /models + a probe, DEVLOG S30). Set DEEPSEEK_MODEL=deepseek-v4-flash
      # for the cheap/fast bulk register. (_deepseek below is superseded — kept for rollback.)
      OAC_PRICE_IN="${DEEPSEEK_PRICE_IN:-}" OAC_PRICE_OUT="${DEEPSEEK_PRICE_OUT:-}" \
        _openai_chat deepseek "${DEEPSEEK_BASE_URL:-https://api.deepseek.com}" \
          "${DEEPSEEK_MODEL:-deepseek-v4-pro}" DEEPSEEK_API_KEY "$prompt"; rc=$? ;;
    kimi)
      # Kimi K2.6 (Moonshot) — 简体中文 signature prose. OpenAI-compatible API, MODERATED lane:
      # the leak guard above already ran (kimi != grok), so explicit content never reaches it.
      # ZH_GROUNDING counters Kimi's tendency to fabricate canon. Auto context-cache → the stable
      # bible prefix bills cheap (Stage 1.5); sidecar captures it as cache_read_tokens.
      # Source .env HERE so KIMI_BASE_URL/KIMI_MODEL/KIMI_TEMP are resolved before the call —
      # Moonshot has separate .ai (intl) / .cn (Chinese) endpoints whose keys are NOT interchangeable,
      # so the base-URL override must take effect (default .ai; set KIMI_BASE_URL=…moonshot.cn/v1 for a CN key).
      [ -f "$ROOT/.env" ] && { set -a; . "$ROOT/.env"; set +a; }
      # kimi-k2.6 is a thinking model that REJECTS any temperature != 1 ("only 1 is allowed for
      # this model"), so default to OMITTING temperature (empty → _openai_chat skips the field).
      # Override KIMI_TEMP only for a non-thinking Kimi model that accepts a range.
      # Cost in CNY (¥/M tokens) for kimi-k2.6 on the .cn platform: cache-hit ¥1.10, input ¥6.50,
      # output ¥27.00 (override via KIMI_PRICE_*). Lets bin/usage show real post-cache spend.
      OAC_SYSTEM="$ZH_GROUNDING" OAC_TEMP="${KIMI_TEMP:-}" \
      OAC_PRICE_CACHE="${KIMI_PRICE_CACHE:-1.10}" OAC_PRICE_IN="${KIMI_PRICE_IN:-6.50}" OAC_PRICE_OUT="${KIMI_PRICE_OUT:-27.00}" \
        _openai_chat kimi "${KIMI_BASE_URL:-https://api.moonshot.ai/v1}" \
          "${KIMI_MODEL:-kimi-k2.6}" MOONSHOT_API_KEY "$prompt"; rc=$? ;;
    *) die "run_model: no dispatcher for model '$model'" ;;
  esac
  return "$rc"
}

# _emit_claude_json <json-file> — file: `claude --output-format json` output;
# stdout: the .result prose; side effect: if $USAGE_SINK set, write usage/cost JSON there.
_emit_claude_json() {
  USAGE_SINK="${USAGE_SINK:-}" python3 - "$1" <<'PY'
import json, os, sys, datetime
try:
    raw = open(sys.argv[1]).read()
except Exception:
    raw = ""
try:
    d = json.loads(raw)
except Exception:
    sys.stdout.write(raw)   # parse failure → pass through so errors stay visible
    sys.exit(0)
sys.stdout.write(str(d.get("result", "")))
sink = os.environ.get("USAGE_SINK")
if sink:
    u = d.get("usage", {}) or {}
    inp = u.get("input_tokens") or 0
    out = u.get("output_tokens") or 0
    cr  = u.get("cache_read_input_tokens") or 0
    cc  = u.get("cache_creation_input_tokens") or 0
    rec = {"lane": "claude", "input_tokens": inp, "output_tokens": out,
           "cache_read_tokens": cr, "cache_creation_tokens": cc,
           "total_tokens": inp + out + cr + cc,
           "cost_usd_est": d.get("total_cost_usd"),
           "ts": datetime.datetime.now().astimezone().isoformat(timespec="seconds")}
    try:
        open(sink, "w").write(json.dumps(rec))
    except Exception:
        pass
PY
}

# _emit_grok_json <json-file> — file: `grok --output-format json` (one object
# {text, thought, stopReason,…}); stdout: the `.text` answer. Lenient: on a parse failure
# pull the text field by regex, else pass the raw through so errors stay visible. Grok
# exposes no token usage, so usage stays N/A (the caller runs `_usage_na grok`).
_emit_grok_json() {
  python3 - "$1" <<'PY'
import json, sys, re
try:
    raw = open(sys.argv[1]).read()
except Exception:
    raw = ""
try:
    sys.stdout.write(str(json.loads(raw).get("text", "")))
except Exception:
    m = re.search(r'"text"\s*:\s*"((?:[^"\\]|\\.)*)"', raw, re.S)
    if m:
        try: sys.stdout.write(json.loads('"' + m.group(1) + '"'))
        except Exception: sys.stdout.write(raw)
    else:
        sys.stdout.write(raw)
PY
}

# _emit_codex_json <jsonl-file> — file: `codex exec --json` JSONL stream; stdout:
# concatenated agent_message prose; side effect: write turn.completed.usage to $USAGE_SINK.
_emit_codex_json() {
  USAGE_SINK="${USAGE_SINK:-}" python3 - "$1" <<'PY'
import json, os, sys, datetime
texts, usage = [], None
try:
    stream = open(sys.argv[1])
except Exception:
    stream = []
for line in stream:
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
    except Exception:
        continue
    t = d.get("type")
    if t == "item.completed":
        it = d.get("item", {}) or {}
        if it.get("type") == "agent_message" and it.get("text") is not None:
            texts.append(it["text"])
    elif t == "turn.completed":
        usage = d.get("usage") or usage
sys.stdout.write("\n".join(texts))
sink = os.environ.get("USAGE_SINK")
if sink:
    if usage is not None:
        inp = usage.get("input_tokens") or 0
        cin = usage.get("cached_input_tokens") or 0
        out = usage.get("output_tokens") or 0
        rsn = usage.get("reasoning_output_tokens") or 0
        rec = {"lane": "codex", "input_tokens": inp, "cached_input_tokens": cin,
               "output_tokens": out, "reasoning_output_tokens": rsn,
               "total_tokens": inp + out + rsn, "cost_usd_est": None,
               "ts": datetime.datetime.now().astimezone().isoformat(timespec="seconds")}
    else:
        rec = {"lane": "codex", "total_tokens": None, "cost_usd_est": None,
               "note": "no usage in stream"}
    try:
        open(sink, "w").write(json.dumps(rec))
    except Exception:
        pass
PY
}

# DeepSeek via API (SFW bulk only). SUPERSEDED by the streaming _openai_chat route in run_model's
# deepseek) case (DEVLOG S30); kept for rollback only — no longer called. Reads key from env/.env.
# Prints the reply to stdout and, if $USAGE_SINK set, side-writes the API `usage` block + an optional
# $-cost estimate (set DEEPSEEK_PRICE_IN/OUT, per 1M tokens, to enable it).
_deepseek() {
  local prompt="$1"
  [ -f "$ROOT/.env" ] && set -a && . "$ROOT/.env" && set +a
  : "${DEEPSEEK_API_KEY:?DEEPSEEK_API_KEY not set (add it to $ROOT/.env)}"
  local base="${DEEPSEEK_BASE_URL:-https://api.deepseek.com}"
  local model="${DEEPSEEK_MODEL:-deepseek-v4-pro}"  # deepseek-chat alias → weak v4-flash (S30)
  USAGE_SINK="${USAGE_SINK:-}" \
  DEEPSEEK_PRICE_IN="${DEEPSEEK_PRICE_IN:-}" DEEPSEEK_PRICE_OUT="${DEEPSEEK_PRICE_OUT:-}" \
  python3 - "$base" "$model" "$prompt" <<'PY'
import json, os, sys, datetime, urllib.request
base, model, prompt = sys.argv[1], sys.argv[2], sys.argv[3]
req = urllib.request.Request(
    base.rstrip('/') + '/chat/completions',
    data=json.dumps({"model": model, "messages": [{"role": "user", "content": prompt}]}).encode(),
    headers={"Authorization": "Bearer " + os.environ["DEEPSEEK_API_KEY"], "Content-Type": "application/json"},
)
with urllib.request.urlopen(req, timeout=120) as r:
    resp = json.loads(r.read())
print(resp["choices"][0]["message"]["content"])
sink = os.environ.get("USAGE_SINK")
if sink:
    u = resp.get("usage", {}) or {}
    pin = u.get("prompt_tokens") or 0
    cmp = u.get("completion_tokens") or 0
    # DeepSeek context cache: prompt_cache_hit_tokens = prefix bytes served from disk cache
    # (billed ~98% cheaper). Surfacing this is the Stage-1.5 verification — a stable bible
    # prefix should make this climb from request #2; stuck at 0 ⇒ the prefix isn't byte-stable.
    chit = u.get("prompt_cache_hit_tokens") or 0
    cmiss = u.get("prompt_cache_miss_tokens") or 0
    cost = None
    try:
        pi = os.environ.get("DEEPSEEK_PRICE_IN", "")
        po = os.environ.get("DEEPSEEK_PRICE_OUT", "")
        if pi or po:
            cost = (pin / 1_000_000.0) * float(pi or 0) + (cmp / 1_000_000.0) * float(po or 0)
    except Exception:
        cost = None
    rec = {"lane": "deepseek", "input_tokens": pin, "output_tokens": cmp,
           "cache_read_tokens": chit, "cache_miss_tokens": cmiss,
           "total_tokens": (u.get("total_tokens") or (pin + cmp)),
           "cost_usd_est": cost,
           "ts": datetime.datetime.now().astimezone().isoformat(timespec="seconds")}
    try:
        open(sink, "w").write(json.dumps(rec))
    except Exception:
        pass
PY
}

# _openai_chat <lane> <base-url> <model> <key-env-var> <prompt>
#   optional env: OAC_SYSTEM (system message), OAC_TEMP (temperature)
# Generic OpenAI-compatible /chat/completions client for API lanes (currently Kimi; GLM-ready).
# MODERATED lanes only — run_model's leak guard has already run before we get here. Reads the key
# from env/.env by NAME (indirect-expanded, bash-3.2 safe) and never prints it. Side-writes the
# usage sidecar incl. cache_read_tokens (Stage 1.5 accounting) when $USAGE_SINK is set.
_openai_chat() {
  local lane="$1" base="$2" model="$3" keyvar="$4" prompt="$5"
  [ -f "$ROOT/.env" ] && { set -a; . "$ROOT/.env"; set +a; }
  local key="${!keyvar:-}"
  [ -n "$key" ] || die "$keyvar not set (add it to $ROOT/.env) — the $lane lane is wired but needs its API key."
  OAC_KEY="$key" OAC_SYSTEM="${OAC_SYSTEM:-}" OAC_TEMP="${OAC_TEMP:-}" USAGE_SINK="${USAGE_SINK:-}" \
  OAC_READ_TIMEOUT="${OAC_READ_TIMEOUT:-300}" \
  python3 - "$lane" "$base" "$model" "$prompt" <<'PY'
import json, os, sys, datetime, urllib.request, urllib.error
lane, base, model, prompt = sys.argv[1:5]
msgs = []
sysmsg = os.environ.get("OAC_SYSTEM") or ""
if sysmsg:
    msgs.append({"role": "system", "content": sysmsg})
msgs.append({"role": "user", "content": prompt})
# STREAMING (DEVLOG S30): thinking models (kimi-k2.6) spend most of their wall-clock on
# reasoning tokens. A non-streaming POST holds the socket with ZERO bytes for that entire
# window, so a single blocking read trips urllib's per-read timeout (the S29 Kimi failure).
# With stream=true the server emits SSE chunks continuously (reasoning_content + content),
# so each read is tiny and the idle-read timeout (OAC_READ_TIMEOUT) never fires on a healthy
# connection — total generation time becomes unbounded while a truly dead socket still fails.
# We accumulate delta.content ONLY (reasoning_content is the model's private thinking, not prose).
# include_usage makes the vendor emit a trailing usage chunk so the sidecar accounting survives.
body = {"model": model, "messages": msgs, "stream": True,
        "stream_options": {"include_usage": True}}
t = os.environ.get("OAC_TEMP")
if t:
    try:
        body["temperature"] = float(t)
    except Exception:
        pass
try:
    read_to = float(os.environ.get("OAC_READ_TIMEOUT") or 300)
except Exception:
    read_to = 300.0
req = urllib.request.Request(
    base.rstrip('/') + '/chat/completions',
    data=json.dumps(body).encode(),
    headers={"Authorization": "Bearer " + os.environ["OAC_KEY"], "Content-Type": "application/json"},
)
parts, u = [], {}
try:
    with urllib.request.urlopen(req, timeout=read_to) as r:
        for raw in r:                       # iterate by line; timeout is per underlying read
            line = raw.decode("utf-8", "replace").strip()
            if not line or not line.startswith("data:"):
                continue
            payload = line[5:].strip()
            if payload == "[DONE]":
                break
            try:
                d = json.loads(payload)
            except Exception:
                continue
            if d.get("usage"):
                u = d["usage"] or u
            for ch in d.get("choices", []):
                seg = (ch.get("delta") or {}).get("content")
                if seg:
                    parts.append(seg)
except urllib.error.HTTPError as e:           # surface the API error body, then fail the lane
    sys.stderr.write("kimi/openai-chat HTTP %s: %s\n" % (e.code, e.read().decode("utf-8", "replace")[:500]))
    sys.exit(1)
print("".join(parts))
sink = os.environ.get("USAGE_SINK")
if sink:
    pin = u.get("prompt_tokens") or 0
    out = u.get("completion_tokens") or 0
    # auto context-cache hit, however the vendor names it (Moonshot: cached_tokens)
    cr = u.get("cached_tokens")
    if cr is None:
        cr = u.get("prompt_cache_hit_tokens") or 0
    # Cache-aware cost: cached input billed at the cheap cache rate, the rest at the input rate,
    # plus output. Prices (per 1M tokens) come from OAC_PRICE_CACHE/IN/OUT — set per-lane (Kimi in
    # CNY). cost_usd_est is reused as the cost field (currency = whatever the prices are in).
    cost = None
    try:
        pc = os.environ.get("OAC_PRICE_CACHE", ""); pi = os.environ.get("OAC_PRICE_IN", ""); po = os.environ.get("OAC_PRICE_OUT", "")
        if pc or pi or po:
            fresh = pin - cr
            if fresh < 0:
                fresh = 0
            cost = cr / 1_000_000.0 * float(pc or 0) + fresh / 1_000_000.0 * float(pi or 0) + out / 1_000_000.0 * float(po or 0)
    except Exception:
        cost = None
    rec = {"lane": lane, "input_tokens": pin, "output_tokens": out,
           "cache_read_tokens": cr,
           "total_tokens": (u.get("total_tokens") or (pin + out)), "cost_usd_est": cost,
           "ts": datetime.datetime.now().astimezone().isoformat(timespec="seconds")}
    try:
        open(sink, "w").write(json.dumps(rec))
    except Exception:
        pass
PY
}
