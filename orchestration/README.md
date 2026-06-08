# orchestration/ — OpenClaw conductor

> **Current runtime (2026-06-03): MCP bridge.** The conductor is reached as an MCP tool — the Mac runs
> `host-mcp/` (Go MCP server) and OpenClaw on **arch** calls it. **See `docs/DEPLOY.md` for bring-up/redeploy.**
> The file-drop bridge below (`host-runner` + `bridge/` + `docker-compose.yml` + `bridge-client.sh`) is the
> **dormant fallback** path, kept intact but not the live route.

Layer 1 (the `bin/plays/` workflows) works standalone. Layer 2 adds OpenClaw for multi-role orchestration; the
host is the firewall trust boundary — explicit prose never enters the container.

## What's here
- `host-mcp/` — **LIVE.** Go MCP server (the conductor bridge to arch) + the `/live` progress dashboard.
- `launchd/` — plist templates for the Mac services (host-mcp, host-runner, healthcheck).
- `roles/*.md` — the role definitions (model + firewall class) per brief §6.
- `nsfw-denylist.txt` — optional second tripwire for the leak guard (file-provenance is primary).
- `docker-compose.yml` — **FALLBACK.** OpenClaw container scaffold (file-drop path; superseded by host-mcp).
- `bridge-client.sh` — **FALLBACK.** In-container client for the file-drop bridge.
- `bridge/` *(runtime, git-ignored)* — file-drop fallback: `inbox/` jobs in, `outbox/` results out.

## The file-drop bridge contract (FALLBACK — superseded by the MCP path)
OpenClaw drops a job in `bridge/inbox/<id>.json`:
```json
{ "role": "audit", "instruction": "…", "targets": ["manuscript/ch01/s01.md"] }
```
Run the host side (host has the first-party CLIs):
```bash
bin/host-runner            # watch loop;  or  bin/host-runner --once
```
The host assembles **firewalled** context (synopsis substituted for explicit on moderated roles),
runs the right model, and writes `bridge/outbox/<id>.txt`. Verified: a moderated role pointed at an
explicit target receives only the synopsis.

## Layer 2 bring-up (remaining — interactive)
1. Put your OpenClaw config/auth under `orchestration/openclaw/{config,auth}` (or reuse the agents-lab one).
2. Set the container's run command in `docker-compose.yml` (`command:`), then `docker compose up -d`.
3. Configure OpenClaw's role sub-agents to **emit bridge jobs** for first-party roles (Claude/agy/Codex)
   and to call Grok/DeepSeek directly; keep `bin/host-runner` running on the host.
4. Validate: a `discuss-outline` roundtable that assembles ≥2 models, and confirm the container has no
   read path to `*.explicit.md`.
