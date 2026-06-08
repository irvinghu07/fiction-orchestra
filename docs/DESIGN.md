# DESIGN — Multi-Agent Fiction-Writing Orchestra (topology decision)

> **STATUS 2026-06-03 — DECIDED & LIVE: Topology A.** The conductor runs on **arch** (OpenClaw) and calls the
> Mac's `host-mcp` server over an MCP/Tailscale bridge; the 4 first-party CLIs + the NSFW firewall stay on the
> Mac. This document is the original **decision rationale** (kept for the "why"). For **how it runs now and how
> to redeploy**, see **`DEPLOY.md`**. The "fully on Mac, Docker" path (Topology B) is the dormant fallback.

> Companion to `PROJECT_BRIEF.md`. This doc resolves the one thing the brief got wrong:
> it assumed everything runs locally on the Mac. Reality is a **two-machine split**, and
> that split is forced by the §5 ToS constraint. Read this, pick a topology in §6, then we scaffold.

## 1. Ground truth (probed 2026-05-31)

**Mac (`ethanmacbook-pro`, Tailscale `100.94.171.80`)**
- First-party CLIs installed + authed: `claude` (Max), `codex` (ChatGPT), `gemini` (Google). ✅
- `git` ✅. `uv`/`python3`/`node` ✅.
- Docker Desktop installed, **daemon stopped** (context `desktop-linux`).
- `hermes`/`deepseek` not present locally (expected — Grok lives on arch; DeepSeek is API-only).

**arch (`arch`, Tailscale `100.78.251.105`, 4ms from Mac, direct)** — `agents-lab` Docker stack:
- `agent-lab-openclaw` (`ghcr.io/openclaw/openclaw:latest`, healthy, *fresh config*) — only `node`+`git` inside; **no claude/codex/gemini**. Has `DEEPSEEK_API_KEY` + `deepseek-v4-flash` in env.
  - Mounts: `repo-readonly` (ro), `scratch` (rw), openclaw `config`/`auth`/`state`/`logs`, shared `prompts/`.
- `agent-lab-hermes` (`nousresearch/hermes-agent:latest`) — **Grok gateway**, reachable from Mac (HTTP 200).
- `infisical` (secrets manager) + `grafana`/`victoriametrics`/`vmalert` (observability) + `n8n`.

## 2. The forced constraint (why it's two machines)

Per brief §5, **Claude must be first-party only** — never inside a proxy or a remote container holding
laundered subscription auth. The same risk applies to Codex (ChatGPT) and is cleanest for Gemini too.
Therefore:

| Model | Must run on | Mechanism | ToS |
|---|---|---|---|
| **Claude** | Mac (host) | `claude -p` first-party Max auth | ✅ hard requirement |
| **Codex (GPT)** | Mac (host) | `codex exec` first-party ChatGPT | ✅ |
| **Gemini** | Mac (host) | `gemini -p` Google/Code Assist | ✅ |
| **Grok** | arch container | Hermes OAuth (SuperGrok) | ✅ sanctioned |
| **DeepSeek** | anywhere | API key (in container env / Infisical) | ✅ |

**Consequence:** the OpenClaw conductor (a sandboxed container, per your preference — no bare-metal on Mac)
can *natively* drive only Grok + DeepSeek. The three first-party models always execute on the **Mac host**.
So every topology needs a **bridge** from "conductor in a sandbox" → "first-party CLI on the Mac host."

## 3. Repo model (same in every topology)

Single source of truth = **canonical git repo on the Mac**, where Nimbalyst edits it. The brief's
"same files, no copy-paste, agents propose on branches" maps onto git:

```
manuscript/   canonical — ONLY human-accepted prose. Agents NEVER write here.
drafts/       agent scratch: experiments, rewrites, first passes (← maps to arch `scratch` mount)
codex/        story bible — agents READ this every session (← maps to arch `repo-readonly`)
```

Flow: agents read `codex/` + `manuscript/` (read-only) → write into `drafts/` and/or a `draft/*` branch →
you review the diff in Nimbalyst → **you** promote final text into `manuscript/` and commit. Git over
Tailscale is the transport; no file-sync daemon.

## 4. Topology A — **arch conducts, Mac is the first-party seat** (recommended)

Reuse the existing healthy arch stack. Grok+DeepSeek run in-box; the first-party trio runs on the Mac.

```
        ┌──────────────── Mac (canonical repo, Nimbalyst) ────────────────┐
        │  claude -p   codex exec   gemini -p     (first-party, host)      │
        │        ▲ local dispatcher routes first-party roles               │
        │  git push/fetch  ▲                                               │
        └──────────────────┼──────────────────────────────────────────────┘
                           │ Tailscale (git + optional task queue)
        ┌──────────────────┼──────── arch (sandbox) ───────────────────────┐
        │  agent-lab-openclaw  ── conducts, assembles, shared memory        │
        │     ├─ Grok role    → agent-lab-hermes (OAuth)                     │
        │     ├─ DeepSeek role→ api.deepseek.com                            │
        │     └─ Claude/Codex/Gemini role → enqueue → Mac runs first-party  │
        │  infisical (secrets) · grafana/vm (metrics)                       │
        └───────────────────────────────────────────────────────────────────┘
```

- **Interactive workflows** (`discuss-outline`, `refine-character`, `inspire`, `audit-scene`): invoked
  **from the Mac**. A small local dispatcher sends Claude/Codex/Gemini roles to local CLIs and Grok/DeepSeek
  roles to arch (HTTP/SSH). **No inbound SSH to the Mac needed.**
- **Autonomous/bulk conductor jobs that need Claude**: openclaw commits a task to a `tasks/*` branch; a
  Mac-side `host-runner` (runs in tmux — **no admin, no sshd**) consumes it, runs the first-party CLI,
  commits results to `draft/*`. Optional; only if you want unattended Claude passes.
- Repo: canonical on Mac → pushed to a clone on arch that openclaw reads via `repo-readonly`.
- **Pros:** reuses built infra (openclaw+hermes+infisical+metrics, one home); Grok must live here anyway;
  no Mac admin toggles; conductor fully sandboxed off the laptop.
- **Cons:** needs the git push/fetch loop + (for autonomous Claude) the host-runner consumer.

## 5. Topology B — **Mac-Docker conducts, host bridge for first-party**

Spin a fresh openclaw container under Mac Docker Desktop; bind-mount the local repo directly.

- **Pros:** repo bind-mount = literal same-files, lowest latency to editor; canonical repo trivially local.
- **Cons:** Docker Desktop must be running on the laptop; **still** can't run the first-party trio in-container
  → needs a host bridge (enable macOS **Remote Login**/sshd [admin], or a host-runner); **still** depends on
  arch for Grok (Tailscale→Hermes); duplicates/orphans the arch openclaw+infisical+metrics stack.

## 5b. DECISION (locked 2026-05-31)

**Fully on Mac, interactive.** A refinement of Topology B that drops the arch dependency entirely:

- **Conductor:** OpenClaw in a **Mac Docker** sandbox (Docker Desktop now running). No bare-metal on the Mac.
- **All four chat models run first-party on the Mac host** — `claude -p`, `codex exec`, `gemini -p`, and
  **`grok`** (Grok CLI, `~/.nvm/.../bin/grok` v0.1.220). The arch Hermes box is **not used**; Grok is
  first-party local, which is even cleaner than Hermes OAuth.
- **DeepSeek:** API key (user-provided).
- **Mode:** **Interactive only** — no host-runner, no unattended passes. The human triggers the four
  workflows; first-party CLIs run on demand.
- **Repo:** canonical on the Mac; agents draft to `drafts/` or `draft/*` branches; human promotes to `manuscript/`.
- **Bridge:** the Mac-Docker conductor reaches the host CLIs via a no-admin host-runner over a shared
  bind-mount (details at Phase 3) — **or** the four workflows run as host-side `bin/` dispatchers and
  OpenClaw is used only for multi-role orchestration. To be finalized when we wire Phase 3.

## 6. Recommendation & open decision

**Recommend Topology A.** Grok is pinned to arch no matter what, the arch sandbox already exists and is
healthy, it keeps the Mac free of new bare-metal *and* new admin toggles, and git-as-bus is exactly the
brief's human-in-the-loop model. Topology B only wins if you specifically want the conductor on the laptop
with a direct bind-mount and are fine running Docker Desktop + a host bridge.

**Still yours to confirm:**
1. Topology **A** (arch conducts) vs **B** (Mac-Docker conducts).
2. Autonomous Claude passes wanted? If yes → we build the `host-runner` consumer. If no → first-party stays
   purely interactive (simpler; you trigger those four workflows from the Mac).
3. Secrets: pull DeepSeek (and any keys) from **Infisical**, or keep them in the container env as-is?

## 7. ToS guardrails (encoded into AGENTS.md regardless of topology)

- Claude/Codex/Gemini **only** via first-party host CLIs. Never inside a container, never via `hermes proxy`
  or any OpenAI-compatible shim.
- Grok **only** via Hermes OAuth. DeepSeek via its own API.
- Subscription (lead reasoning) roles run **sequential** to respect rate limits; DeepSeek/API for **parallel bulk**.
- Post-2026-06-15: `claude -p`/Agent-SDK on subscription draws a separate monthly credit pool → degrade
  gracefully (fall back to DeepSeek/Grok for non-Claude-critical passes) when low.
