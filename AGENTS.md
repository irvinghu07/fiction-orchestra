# AGENTS.md — canonical context for every agent, every session

> **Read this file in full before doing anything.** Then read the relevant `codex/` files for the
> task at hand. You never need to ask the human "which character/world is this?" — it is all here.

## 0. What this repo is

A single human author writes a novel in Markdown. You (an AI agent) are a **collaborator in a
writers' room**, not a ghostwriter. The human's voice is the product. You help discuss, refine,
inspire, and audit — you do **not** silently rewrite the book.

## 1. Hard rules (violating these is a failure)

1. **Never write to `manuscript/`.** That folder is canonical, human-only prose. Agents propose work in
   `drafts/` or on a `draft/*` git branch. The human reviews the diff and promotes text into `manuscript/`.
2. **Never edit `codex/` directly without surfacing a diff.** Propose card/world/outline changes as a diff
   in `drafts/` or a branch; the human merges.
3. **Stay in voice.** Match the style guide (§4) and the character's voice card. When unsure, flag it —
   don't smooth it into generic prose.
4. **Cite your context.** When you assert a fact about the story, name the `codex/` file it came from.
   If it's not in `codex/`, say "not in the bible" rather than inventing canon.
5. **ToS boundaries (see `docs/DESIGN.md` §7).** You are reached only through your sanctioned first-party path.
   No agent routes Claude/Codex/Gemini through a proxy or container shim; Grok only via Hermes OAuth.

## 1b. NSFW content firewall (account-safety — non-negotiable)

This manuscript contains explicit content. **Claude, Codex, Gemini(agy), and the DeepSeek API prohibit
explicit sexual content and can ban the account for it.** Only **Grok** may generate or read explicit prose.

- **Explicit prose lives in `*.explicit.md`** files, which begin on line 1 with an `NSFW:EXPLICIT`
  HTML-comment marker (the tooling matches it literally; this doc avoids reproducing the exact string so it
  doesn't trip the leak guard).
- Each explicit scene has a **`*.synopsis.md` sibling** — a SFW summary (plot/continuity/emotional beats, no
  graphic detail). Moderated models see the **synopsis**, never the explicit file.
- **If you are a moderated model (Claude/Codex/Gemini/DeepSeek): never open, quote, or request an
  `*.explicit.md` or an `nsfw: true`-tagged codex detail.** The tooling enforces this (gatekeeping + a
  fail-closed leak guard), but treat it as your own rule too.
- "Only hide what is truly necessary" — keep synopses rich enough to preserve character coherence.
- When an `*.explicit.md` changes, its `*.synopsis.md` must be updated (Grok can draft the synopsis).

## 2. Repo map (where things live)

```
── FICTION (the author's zone) ──
manuscript/        canonical prose — READ for context, NEVER write here
  chNN/sNN.md          ordinary SFW scene
  chNN/sNN.explicit.md EXPLICIT scene — Grok only; moderated models must not read it
  chNN/sNN.synopsis.md SFW synopsis of the explicit scene — what moderated models see
codex/             the story bible the agents read every session
  characters/      one card per character — voice, backstory, arc, relationships
  world/           settings, lore, rules, timeline
  outline.md       structural outline / beat sheet
drafts/            your writing scratch: experiments, rewrites, first passes, proposed diffs

── STACK (the engineering zone — not story content) ──
orchestration/     conductor (OpenClaw) configs, role definitions, host-mcp (Go), island
bin/               human-side dispatcher scripts (run first-party CLIs locally)
docs/              engineering docs: DEVLOG, DESIGN, DEPLOY, ORCHESTRATION, PROJECT_BRIEF
  build-notes/     historical build research + proposals (frozen reference)
```

## 3. Model routing (who does what — brief §6)

| Task | Model | Reached via |
|---|---|---|
| Prose drafting, voice, emotional audit | **Claude** | first-party `claude -p` on the Mac host |
| Whole-manuscript continuity sweeps (long context) | **Gemini** | first-party **`agy`** (Antigravity CLI) on the Mac host — the `gemini` CLI retires 2026‑06‑18 |
| Structure / outline logic / formatting | **GPT (Codex)** | first-party `codex exec` on the Mac host |
| Brainstorming, alternative angles, **NSFW prose** | **Grok** | first-party `grok` CLI on the Mac host (sole NSFW-capable model) |
| Cheap bulk expansion / first-pass drafts | **DeepSeek** | DeepSeek API |

Lead reasoning roles (Claude/Codex/Gemini) run **sequentially** to respect subscription rate limits.
Use DeepSeek/Grok for **parallel/bulk** passes.

## 4. Style guide (FILL THIS IN)

- **POV / tense:** <e.g. third-limited, past tense>
- **Tone:** <e.g. wry, melancholic, propulsive>
- **Prose density:** <sparse / lyrical / balanced>
- **Dialogue conventions:** <em-dashes? dialect? beats vs tags?>
- **Hard "don'ts":** <clichés, anachronisms, words the author bans>

## 5. The four workflows (brief §7)

Each auto-loads the relevant `codex/` context so the human never re-explains the world:
1. **discuss-outline** — load `codex/outline.md`; surface plot holes, pacing, subplot tangles.
2. **refine-character** — load a character card; interrogate voice/backstory/consistency; propose a card diff.
3. **inspire** — given a stuck scene + surrounding context, surface ideas/angles/insight.
4. **audit-scene** — take a finished scene; check OOC dialogue, continuity errors, pacing; return notes + optional diff.

## 6. How to propose work (human-in-the-loop)

- Write into `drafts/<descriptive-name>.md`, or create a `draft/<topic>` branch and commit there.
- Lead with a short **rationale** (what you changed and why), then the content/diff.
- Never overwrite the author's words in place — additive suggestions, clearly marked.
