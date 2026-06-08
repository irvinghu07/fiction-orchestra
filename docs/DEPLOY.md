# DEPLOY.md — what runs where, and how to bring it back

> **The single source of truth for the live runtime + disaster recovery.** If something breaks, start here.
> Architecture rationale lives in `DESIGN.md`; session history in `DEVLOG.md`. Last verified: 2026-06-03.

## 0. The shape in one paragraph

The **conductor** is a local Mac program (`bin/conduct`: Sonnet plans → specialist lanes → Opus synthesizes).
It's exposed to the outside world by **`host-mcp`**, a tiny Go MCP server on the Mac. **OpenClaw runs on the
`arch` box** and is registered as that server's client, so from the OpenClaw panel you call one `conduct` tool
and the work runs on the Mac. The **4 first-party CLIs** (`claude`, `codex`, `agy`, `grok`) and the **NSFW
firewall** never leave the Mac. A live progress board is served at `http://<mac-tailnet-ip>:8765/live`, and a
**sanitized structured feed** at `/live/events` powers the **Mac "Island" cockpit** (`orchestration/island`).

```
arch: agent-lab-openclaw (OpenClaw) ──MCP/Streamable-HTTP over Tailscale──▶ Mac: host-mcp :8765
                                                                              └─ bin/conduct ─▶ claude/codex/agy/grok (+ DeepSeek/Kimi API)
                                                                              └─ /live          (raw board dashboard; title shows instruction — operator's screen only)
                                                                              └─ /live/events   (SANITIZED JSON SSE: play+lane state, NO instruction/targets) ─▶ Island cockpit
```

**Endpoints** (tailnet-bound): `/mcp` (Bearer-auth, the conduct tool) · `/healthz` · `/live` + `/live/stream`
(raw board) · `/live/events` + `/live/events/latest` (sanitized structured run state, unauthenticated +
`Access-Control-Allow-Origin: *` for the cockpit webview — safe: SFW + tailnet-only).

## 1. What runs where

### Mac (the first-party seat + trust boundary)
| Piece | What | Managed by |
|---|---|---|
| `ai.openclaw.fiction-host-mcp` | **LIVE** Go MCP server, binds the Tailscale IP `:8765`, serves `/live` | launchd (`bin/host-runnerctl`) |
| `ai.openclaw.fiction-healthcheck` | hourly first-party CLI auth probe | launchd |
| `ai.openclaw.fiction-host-runner` | **FALLBACK** file-drop bridge runner (dormant) | launchd |
| `bin/host-mcp` | compiled Go binary (git-ignored; auto-built by `bin/host-mcp-run`) | built from `orchestration/host-mcp/main.go` |
| `Fiction Island.app` | **cockpit** — live board + notifications + ops (Tailscale/OpenClaw/doctor/host-mcp restart). Consumes `/live/events`; monitors host-mcp, doesn't replace it | `orchestration/island` (`cargo tauri build`); optional launch-at-login plist |
| 4 CLIs | `claude`, `codex`, `agy`, `grok` — first-party, interactive auth | you (browser/OAuth) |
| `.env` | secrets/config (see §4) | you (not in git) |

### arch (the conductor's UI host)
| Piece | What |
|---|---|
| `agent-lab-openclaw` | the existing shared OpenClaw container (NOT fiction-specific) |
| `fiction-host` MCP reg | one entry in its `openclaw.json` pointing at `http://<mac-tailnet-ip>:8765/mcp` (Bearer token) |

**That is arch's *entire* fiction footprint** — no repo clone, no `codex/`, no separate `.env`.

## 2. Redeploy the Mac side (from scratch)

```bash
# 0. Prereqs: Go (for the host-mcp build), Tailscale up, the 4 CLIs installed.
git clone <origin>  ~/fiction && cd ~/fiction       # origin = errpthan.com:2222
cp /path/to/backup/.env .env                         # or recreate per §4

# 1. Authenticate the 4 first-party CLIs (interactive, browser/OAuth):
claude auth login ; codex login ; agy ; grok login   # then verify:
bash bin/smoke-auth.sh --health                       # expect: claude/codex/grok/agy PASS

# 2. Install + start the launchd services (renders plists, builds host-mcp, binds the tailnet IP):
bin/host-runnerctl install
bin/host-runnerctl status                             # all three agents loaded

# 3. Verify the MCP server is live + firewall-correct:
lsof -nP -iTCP:8765 -sTCP:LISTEN                      # bound to the 100.x tailnet IP, NOT 0.0.0.0
curl -s http://$(tailscale ip -4 | head -1):8765/healthz   # -> ok
```

## 3. Redeploy the arch side

```bash
# Prereq: agent-lab-openclaw is running on arch; the Mac is reachable on the tailnet.
bin/register-arch-mcp                                 # reads HOST_MCP_TOKEN from .env, registers 'fiction-host'
ssh arch 'docker restart agent-lab-openclaw'          # required: it caches the MCP connection
ssh arch 'docker exec agent-lab-openclaw openclaw mcp list'   # -> fiction-host
```
Then from the OpenClaw panel: call the `conduct` tool (or `/conduct`) → it runs on the Mac.

## 4. `.env` (required keys — no values in git)

```
HOST_MCP_TOKEN          # bearer for the MCP server <-> arch (openssl rand -hex 24); rotate => re-run §3
OPENCLAW_GATEWAY_TOKEN  # OpenClaw gateway token
DEEPSEEK_API_KEY        # DeepSeek (bulk / continuity API lane)
DEEPSEEK_BASE_URL
DEEPSEEK_MODEL
MOONSHOT_API_KEY        # Kimi (中文 prose lane)
KIMI_BASE_URL
```
**Token rotation:** edit `HOST_MCP_TOKEN` in `.env` → `launchctl kickstart -k gui/$(id -u)/ai.openclaw.fiction-host-mcp`
→ `bin/register-arch-mcp` → restart the arch container (§3).

## 5. Health check

```bash
bin/fiction-doctor        # checks both sides end-to-end: launchd, :8765 bind, /healthz, /live, arch MCP reg
```

## 6. Rollback — bring up the dormant file-drop fallback

Only if the MCP path is broken and you need the conductor in the panel urgently. The file-drop path
(`orchestration/docker-compose.yml`, `bin/host-runner`, `orchestration/bridge-client.sh`, the `/conduct`
plugin under `orchestration/openclaw/plugins/conduct/`) is kept intact for this.

1. Mac: `docker compose -f orchestration/docker-compose.yml up -d` (gateway → `localhost:19001`); ensure
   `bin/host-runner` is running (it's already a launchd agent).
2. Apply the container config patches (LEGACY, but valid for a fresh container):
   `orchestration/openclaw-deepseek-patch.json` + `orchestration/openclaw-conduct-patch.json` (see each file's
   `_comment` for the exact `docker exec … config patch` command), then `docker restart`.
3. Drive `/conduct` from `localhost:19001`. This path had live in-panel progress (the plugin's `ctx.onUpdate`).

## 7. Known constraints

- **In-panel live progress is not available on the MCP path** (OpenClaw 2026.5.22 drops tool `onUpdate` for
  direct dispatch — see `DEVLOG.md` S20 + `docs/build-notes/inpanel-progress-research.md`). Use `/live` instead.
- **Mac sleep** pauses in-flight runs; they resume on wake.
- **Docker Desktop on the Mac is kept installed but its daemon is stopped** (the fallback container needs it;
  the live MCP path does not).

## 8. QQ front-end (NapCat → OpenClaw) — optional second inbound surface

Reach the **whole** OpenClaw agent from QQ (general Q&A + task delegation + `/conduct`). Lives entirely on
**arch**; the Mac side is untouched. Full runbook + security notes: `orchestration/napcat/README.md`.

| Piece | What | Where |
|---|---|---|
| `napcat` container | OneBot-11 bridge driving NTQQ (a **burner** QQ) | arch, Docker (`orchestration/napcat/compose.yml`) |
| `openclaw-onebot` plugin | channel plugin in `agent-lab-openclaw`; WS-client → NapCat | arch (`bin/register-arch-onebot`) |
| `channels.onebot.*` | `wsUrl ws://127.0.0.1:3001`, `httpUrl http://127.0.0.1:3010` (host 3010→container 3000; Grafana owns arch :3000), `accessToken`, `allowFrom:["private:<your-qq>"]` | arch openclaw config |

- **Ports** bound to arch `127.0.0.1` only (openclaw is `network_mode:host`, reaches them there). Never
  published; WebUI `:6099` via SSH tunnel.
- **`.env` keys** (Mac repo, for `bin/register-arch-onebot`): `NAPCAT_ACCESS_TOKEN` (must match NapCat's
  OneBot token), `ALLOW_QQ` (your personal QQ id → the allowlist gate).
- **Constraints/risk:** burner-account-only (Tencent risk-control bans personal accounts fast); the channel
  plugin restart is disruptive to the shared lab (gated behind `bin/register-arch-onebot --restart`); replies
  carry full content back to QQ (your gated burner). The arch agent doesn't mount the repo, so it can't read
  `manuscript/`/`codex/` directly — only the firewalled `conduct` MCP tool.
