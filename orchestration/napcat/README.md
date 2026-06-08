# NapCat — QQ (OneBot 11) front-end for the OpenClaw agent

Reach the whole OpenClaw agent from QQ on your phone: **general Q&A, ad-hoc task delegation, the built-in
commands (`/status`, `/model`, `/new`, …), and the fiction `/conduct` command** — all from one QQ chat,
gated to your account. NapCat (a OneBot-11 bridge driving NTQQ) runs in Docker on **arch**; the
`openclaw-onebot` channel plugin inside `agent-lab-openclaw` connects in and routes inbound QQ text through
OpenClaw's normal pipeline. The Mac trust boundary is untouched — `/conduct` still runs on the Mac behind the
NSFW firewall via the unchanged host-mcp path.

```
 your phone (normal QQ app, SAFE)
   │  plain text → agent  ·  "/conduct …" → fiction conductor
   ▼
 arch ── napcat (Docker, BURNER QQ) ──OneBot 11 WS:3001 / HTTP:3010→3000 (127.0.0.1)──▶ agent-lab-openclaw
                                                                                    ├─ openclaw-onebot channel (allowFrom)
                                                                                    └─ /conduct ─MCP─Tailscale─▶ Mac host-mcp
```

## ⚠️ Read before you touch this
- **BURNER QQ ONLY.** Driving QQ via NapCat is cheat-equivalent to Tencent; accounts get risk-controlled
  (封号) fast — sometimes after a couple of messages, sometimes permanently. **Never** attach your personal
  number. The burner runs the bot; you chat *to* it from your normal, unautomated QQ app (which stays safe).
- **Never expose the ports.** A leaked NapCat port with a weak/empty token has caused tens-of-thousands of
  QQ-group mass-bans. Everything binds to `127.0.0.1` only; reach the WebUI via SSH tunnel. Non-empty access
  token + random WebUI token (never the default `napcat`).
- **Egress:** replies (agent output + composed drafts) go back to your gated burner. The arch agent does not
  mount the repo (only `/workspace/scratch`), so it can't read `manuscript/`/`codex/` directly; the only Mac
  access is the firewalled `conduct` MCP tool.

## Files here
| File | Tracked? | What |
|---|---|---|
| `compose.yml` | yes | NapCat service (digest-pinnable, hardened, loopback-bound) |
| `.env.example` | yes | template for the arch-side `.env` (UID/GID, WebUI + access tokens, account) |
| `config/onebot11.example.json` | yes | the OneBot-11 config shape the plugin expects |
| `.env`, `config/onebot11_*.json`, `ntqq/`, `shared/` | **no** (gitignored) | secrets + QQ session + live config + media |

## Deploy runbook

### Phase 1 — Burner QQ (yours)
Register a **dedicated burner** (not your number). Age + warm it on a phone/residential network first (new
accounts freeze fastest). Note your **personal QQ id** → it becomes `ALLOW_QQ`.

### Phase 2 — NapCat on arch
NapCat reaches arch by **`docker pull`** (not rsync, and NOT a full clone of the fiction repo — that would
drag `manuscript/`/`codex/` onto arch and break the trust boundary). The only files arch needs are this tiny
`compose.yml` + a local `.env`, created in place:
```bash
ssh arch
mkdir -p ~/napcat && cd ~/napcat
docker pull mlikiowa/napcat-docker:v4.18.5      # the digest in compose.yml pins this exact image
# write compose.yml in place (copy it from this repo's orchestration/napcat/compose.yml), then:
cp .env.example .env 2>/dev/null || $EDITOR .env # NAPCAT_UID/GID=1000 (arch user irving), WEBUI_TOKEN, NAPCAT_ACCESS_TOKEN, ACCOUNT
#   WEBUI_TOKEN:        openssl rand -hex 16
#   NAPCAT_ACCESS_TOKEN: openssl rand -hex 24   (must match channels.onebot.accessToken — also put it in the Mac repo .env)
docker compose up -d
docker logs -f napcat                            # watch for the login QR (also in the WebUI)
```
The OneBot network (WS:3001 + HTTP:3000 *inside* the container + token) is set in the **WebUI** — the
authoritative method — so `config/onebot11.example.json` is reference only. NOTE the host HTTP port is mapped
to **3010** (compose) because Grafana owns arch `:3000`; OpenClaw therefore uses `httpUrl http://127.0.0.1:3010`.
First login (from your laptop, tunneled — ideally do the FIRST login from a residential IP, then move the
`ntqq/` session to arch):
```bash
ssh -L 6099:127.0.0.1:6099 arch                  # tunnel the WebUI
#   open http://127.0.0.1:6099/webui  → log in with WEBUI_TOKEN → scan the QR with the BURNER QQ
```
In the WebUI, set the OneBot network to match `config/onebot11.example.json`: a **WebSocket server** on
`:3001` and an **HTTP server** on `:3000` (these are the container-internal ports — leave them at 3000/3001;
the compose remaps HTTP to host 3010), both with `token = NAPCAT_ACCESS_TOKEN`, `messagePostFormat: array`.
Confirm `get_login_info` round-trips.

### Phase 3 — Wire the channel plugin (from the Mac)
Put `NAPCAT_ACCESS_TOKEN` and `ALLOW_QQ=<your personal QQ id>` in the **Mac repo `.env`**, then:
```bash
bin/register-arch-onebot            # install + enable the plugin, set channels.onebot.*, verify (NO restart)
bin/register-arch-onebot --restart  # DISRUPTIVE to the shared lab — run when a brief blip is OK
```

### Phase 4 — Dogfood (from your QQ)
- plain question → agent replies (general path)
- `/conduct "continuity pass" manuscript/ch01/s01.md` → Island board lights, draft returns to QQ (watch the
  Mac host-mcp log for `conduct dispatch=raw`)
- `/status`, `/model` → built-ins
- a non-allowlisted sender is ignored (`allowFrom`)

## Fallback — if `clawhub:` install fails on this OpenClaw build
Build from source into scratch and install the dir, mirroring the conduct-plugin runbook
(`docs/build-notes/openclaw-command-dispatch.md` §5):
```bash
ssh arch 'docker exec agent-lab-openclaw sh -lc "cd /workspace/scratch && \
  npm pack openclaw-onebot && tar xzf openclaw-onebot-*.tgz && cd package && \
  export HOME=/workspace/scratch npm_config_cache=/workspace/scratch/.npm && \
  npm install --include=dev && npm run build && rm -rf node_modules && \
  openclaw plugins install /workspace/scratch/package --force && openclaw plugins enable openclaw-onebot"'
```
If even that fails on version skew, the degraded option is a thin standalone NapCat→host-mcp bridge (conduct
only, loses the general-agent surface) — see the plan / `docs/build-notes/napcat-qq-frontend.proposal.md`.

## Verify / operate
```bash
bin/register-arch-onebot --verify       # plugin runtime + channels list + /conduct on the dispatch surface
ssh arch 'docker logs --tail 50 napcat'
bin/register-arch-onebot --uninstall    # remove the channel plugin
ssh arch 'cd ~/napcat && docker compose down'   # stop NapCat
```
