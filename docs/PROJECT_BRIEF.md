# Project Brief: Local Multi-Agent Fiction-Writing Orchestra

> Paste this into Claude Code as the project charter. It is self-contained — you don't need any prior conversation to act on it. Read it fully, then ask me the questions in §9 before scaffolding.

## 1. Goal

Build a **local, file-based, multi-agent orchestration system for writing a fiction novel.** I write the prose myself in a Markdown editor; a fleet of AI agents — conducted by OpenClaw — help me **discuss the outline, refine character cards, surface inspiration/insight, and audit scenes when I'm stuck or have just finished one.**

Everything operates on the **same Markdown files in one git repo.** The whole point is to eliminate two specific frictions:

- **No copy-paste** between a writing app and an AI chat — the agents read and write the same files I edit.
- **No re-briefing** — agents auto-load a persistent story bible, so none of them ever asks "wait, which character did that?"

I am a CS undergrad / AI postgrad, so a developer-grade, terminal + git workflow is fine. Optimize for control and correctness, not hand-holding.

## 2. Design principles (non-negotiable)

1. **Single source of truth.** The manuscript is Markdown in a git repo. Humans and agents edit the same files. No cloud-locked app holds the canonical copy.
2. **Persistent context.** `AGENTS.md` / story-bible files are auto-loaded by every agent every session.
3. **Human-in-the-loop.** Agents propose edits on git branches/worktrees. I review diffs and accept or reject. The author's voice stays mine — no silent overwrites.
4. **ToS compliance.** See §5. This is a hard constraint, not a preference. Getting it wrong risks account bans.

## 3. Components

| Layer | Tool | Notes |
|---|---|---|
| Conductor | **OpenClaw** | Orchestrator spawns role sub-agents, delegates, assembles results. Use its sub-agent system + shared memory. |
| Model: Claude | **Claude Code** (`claude -p`) | First-party auth via my Claude Max subscription. **Never proxied.** |
| Model: Grok | **Hermes** (OAuth) | SuperGrok OAuth — sanctioned by xAI. Already working on my machine. |
| Model: GPT | **Codex CLI** (`codex exec`) | First-party auth via my ChatGPT subscription. |
| Model: Gemini | **Gemini CLI** (`gemini -p`) | Google account / Code Assist. |
| Model: DeepSeek | **API key** | Cheap bulk worker for high-volume passes. |
| Editor (human seat) | **Nimbalyst** (or VS Code + Markdown Fiction Writer) | WYSIWYG, edits the repo files, inline diff review of agent edits. |
| Version control | **git** | Agents work on branches/worktrees; I merge after diff review. |

## 4. Proposed repo layout

```
novel/
├── manuscript/          # scenes & chapters as .md (e.g. ch01/s01.md)
├── codex/               # the story bible the agents read
│   ├── characters/      # one .md per character (card)
│   ├── world/           # settings, lore, rules
│   └── outline.md       # structural outline / beat sheet
├── AGENTS.md            # canonical context: how agents should behave + pointers into codex/
├── CLAUDE.md            # Claude Code project instructions (can reference AGENTS.md)
├── orchestration/       # OpenClaw configs, role/sub-agent definitions
├── .gitignore
└── README.md
```

## 5. Constraints — the ToS landmine (read carefully)

- **DO NOT route my Claude Pro/Max subscription through any third-party proxy** (Hermes proxy mode, CLIProxyAPI, token-laundering shims, etc.). Anthropic blocked third-party subscription access in January 2026. Claude must be reached **only via first-party Claude Code** (`claude -p`, which uses my Max auth natively).
- **Grok via Hermes OAuth is allowed** — xAI sanctions SuperGrok/X Premium OAuth sign-in for terminal tools. Keep using it.
- **Be cautious with ChatGPT through a proxy.** Prefer first-party Codex CLI sign-in.
- **Mind subscription rate limits** (Claude Pro is roughly 50 messages / 5 hours; other subs have their own quotas). Use sequential subscription passes for the lead reasoning roles; use **DeepSeek/API keys for high-volume parallel workers.**
- **Heads-up for after June 15, 2026:** `claude -p` / Agent SDK usage on subscription plans draws from a separate monthly Agent SDK credit pool, distinct from interactive limits. Design the orchestration so it degrades gracefully if that pool runs low.

## 6. Agent roles (task routing)

- **Prose drafting, voice, emotional audit** → Claude
- **Whole-manuscript continuity sweeps (largest context)** → Gemini
- **Structure / outline logic / formatting** → GPT (Codex)
- **Brainstorming, alternative angles, experimentation** → Grok
- **Cheap bulk expansion / first-pass drafts** → DeepSeek

## 7. The four core workflows I want as commands/skills

1. **discuss-outline** — load `codex/outline.md`, hold a structural conversation (plot holes, pacing, subplots).
2. **refine-character** — load a character card, interrogate voice/backstory/consistency, propose card edits as a diff.
3. **inspire** — surface ideas/insight for a stuck scene, given surrounding context.
4. **audit-scene** — take a finished scene, check for out-of-character dialogue, continuity errors, and pacing; return notes + optional diff.

Each must auto-pull relevant `codex/` context so I never re-explain the world.

## 8. Build plan (suggested order)

1. Scaffold the repo per §4 (folders, `.gitignore`, `README.md`, template `AGENTS.md` + `CLAUDE.md`).
2. Write the `AGENTS.md` story-bible template (character-card schema, world structure, style guide, and instructions telling every agent to read `codex/` before acting).
3. Verify each model works headless on its sanctioned auth: `claude -p`, `codex exec`, `gemini -p`, and grok-via-Hermes. Report which authenticate cleanly.
4. Set up the OpenClaw conductor: define the role sub-agents from §6, bind each to its model per §5, wire the shared-memory/story-bible context.
5. Implement the human-in-the-loop git flow: agents commit proposed edits to branches/worktrees; document how I review diffs in the editor and merge.
6. Implement the four workflows in §7 as OpenClaw skills/commands.
7. Smoke test: run `audit-scene` on one sample scene end-to-end and show me the diff.

## 9. Questions to ask me before scaffolding

1. My OS and hardware (affects editor choice + local model viability).
2. Editor: **Nimbalyst** vs **VS Code + Markdown Fiction Writer** — confirm which, and whether it's installed.
3. Conductor style: **OpenClaw native sub-agents** vs a **custom dispatcher script** I own end-to-end.
4. Which subscriptions are currently active and logged in (Claude Max? ChatGPT? SuperGrok? Gemini/Google? DeepSeek API key?).
5. Is this a brand-new manuscript, or am I importing existing chapters/notes?

Once I answer these, scaffold §4 and proceed through §8. Flag anything in §5 that my setup would violate **before** writing code.
