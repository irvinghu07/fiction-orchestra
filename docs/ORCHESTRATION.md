# ORCHESTRATION.md — The Fiction Conductor

> **Status:** ✅ BUILT (Session 6, 2026-06-01). `bin/conduct` + `bin/lib/conduct.sh` + the `conduct` bridge role
> + plays 1–4 + both OpenClaw entries are live. NSFW off-repo migration + fast-follows 5–8 remain. See §9/§10.
> Backbone = the five first-party CLIs already wired (`claude`, `codex`, `agy`, `grok`, DeepSeek API).
> See `AGENTS.md` for the agent contract, `DESIGN.md` for topology, `DEVLOG.md` for build history.

## 0. The idea in one paragraph

You hand a **conductor** raw material — a half-formed idea, a messy draft, a craft question — and it
*analyzes intent, picks the right specialist models, has them collaborate over the filesystem, and returns a
composed artifact in `drafts/`*. You never re-brief models or copy-paste between them. The conductor is
**Claude Sonnet, running host-side**. The repo is **Simplified-Chinese, SFW-only**; explicit content lives
**off-repo** and is never visible to the moderated models. Composing should feel like conducting an orchestra,
not babysitting five chat windows.

---

## 1. The conductor

- **Model:** Claude **Sonnet** via `claude -p` (model pinned). Sonnet leads the five CLIs on
  instruction-following + reasoning + Chinese 文笔, which is exactly the router/synthesizer job. Opus may be
  pinned for the final synthesis step of high-stakes plays (open question — see §10).
- **Where it runs:** **host-side only.** ToS keeps Claude off the OpenClaw container, and the host is already
  the firewall trust boundary (`bin/host-runner`). The conductor therefore lives next to `run-model`/`context`.
- **Two entry points, one conductor:**
  - `bin/conduct "<request>" [target paths…]` — terminal use.
  - OpenClaw bridge **role `conduct`** — the in-container orchestrator delegates a high-level task to the host
    conductor via `bridge-client conduct "<request>" [targets]`, reusing the proven bridge + `host-runner`.
- **The loop:**
  1. **Read by path** only what's needed — a small codex index + the target file(s). Never slurp the repo.
  2. **Classify intent → select a play** (§5).
  3. **Emit a structured plan** (§6) — the machine-readable list of steps.
  4. The host **dispatches** each step to a specialist CLI.
  5. Specialists **read/write files** (filesystem-first, §2).
  6. The conductor **reads results by path**, **synthesizes**, and writes the final artifact + a short
     rationale to `drafts/`. The human reviews the diff in Nimbalyst and promotes (`bin/plays/promote`).

---

## 2. Filesystem-first dispatch (the hard rule)

**Agents pick up files by path per instruction. The host stops pasting large content into prompts.** This
saves context tokens and improves performance.

- **Agentic CLIs read files themselves.** `claude`, `codex`, `agy`, `grok` all have file/tool access in
  headless mode. A step hands them **paths + an instruction + a scoped working directory** (`--add-dir`/cwd);
  the CLI opens what it needs.
- **DeepSeek is the documented exception.** It is API-only (no filesystem), so it stays a
  **host-assembled-context** model: the host reads the needed SFW files and inlines a *minimal* slice. (This is
  also where the leak guard runs — §3.)
- **Scoped working dirs = context budgeting + sandbox.** Each step declares `reads` (paths, whole-file vs.
  section). The host scopes the agent's cwd to the minimum (e.g., a single chapter dir + the relevant codex
  subdir) so agents neither slurp the repo nor escape it.
- **Every step writes to a file** under a per-job scratch dir `drafts/.conduct/<job>/<step>.md` and returns
  the **path**. The conductor reads those paths to synthesize; big blobs never travel inline.

```
request ──▶ conductor (claude -p, host)
                │  reads: codex index + target paths
                ▼
            plan.json (steps with reads[]/writes)
                │
       ┌────────┼─────────┬───────────┐         (parallel_group 1)
       ▼        ▼         ▼           ▼
    claude    codex     agy         grok         ← each reads paths, writes a file
       └────────┴────┬────┴───────────┘
                     ▼                           (parallel_group 2)
              claude synthesis  ──▶ drafts/<artifact>.md  (+ rationale)
```

---

## 3. Firewall — NSFW off-repo, SFW repo (structural, fail-closed)

The old in-repo `*.explicit.md` scheme is **retired**. New model:

- **The git repo is SFW-only.** Explicit prose moves **out of the repo** entirely (a never-tracked sibling,
  e.g. `~/fiction-nsfw/…`).
- **In-repo, an explicit scene is a reference + SFW synopsis — no explicit bytes.** Proposed convention:
  `manuscript/chNN/sNN.sfw.md` carrying the SFW synopsis plus frontmatter `nsfw_ref: <id|relpath>`. The
  **user's own Python assembler** resolves `nsfw_ref` → merges the off-repo NSFW → produces the Nimbalyst
  reading view. Agents read only the synopsis; `nsfw_ref` is an opaque pointer (no content).
- **Safe by construction:** moderated agents get filesystem access to the repo, and the explicit prose
  **isn't there to open** → no accidental blend, no account-ban risk. This is stronger than byte-substitution
  because there's nothing to substitute.
- **Defense-in-depth retained:**
  - each agentic CLI is **sandboxed to its scoped cwd** and cannot escape to the off-repo NSFW path;
  - the **leak guard** (`bin/lib/run-model.sh`) still scans any host-assembled DeepSeek payload and aborts on
    the NSFW marker / denylist;
  - `bin/plays/promote` keeps its tier checks.
- **Grok NSFW lane is separate and user-owned.** Grok writes explicit prose **off-repo** and updates the
  in-repo SFW synopsis/ref. The conductor (moderated) may *request* an NSFW scene but **never sees the output**
  and never routes explicit bytes to a moderated model.

> Net effect: the entire orchestrator operates on SFW content. NSFW is a parallel, user-driven pipeline that
> only ever exchanges *references* and *synopses* with the repo.

---

## 4. Model-strength map (the routing brain)

Grounded in 2026 Chinese-fiction benchmarks (see memory `[[chinese-models-for-fiction]]`). Five-CLI backbone:

| Model (CLI) | Lanes in plays | Chinese-aware notes |
|---|---|---|
| **Claude** Sonnet/Opus (`claude -p`) | **Conductor**; signature/climax prose; voice & emotion; dialogue & character; final synthesis; the *voice/emotion* critic | Best 文笔 + instruction-following of the five, including in Chinese. The default for anything where prose quality matters. |
| **Codex / GPT** (`codex exec`) | Outline, beat-sheet, pacing, subplot logic, plot-hole hunting; the *structure* critic | Strong logic; Chinese literary quality weaker than Claude — use for structure, not prose. |
| **Gemini** (`agy -p`) | Whole-manuscript continuity, timeline, long-context consistency; the *continuity* critic | Long context is the value. **Do not use for Chinese prose** (平稳 / 爆发力不足). |
| **Grok** (`grok -p`) | SFW wild angles & brainstorm; reader-grip "爽点" critic; **separate** NSFW lane | Voice-forward, edgy. ⚠️ Telemetry hang ⇒ ~2–3 min per job (known; budget for it). |
| **DeepSeek** (API) | Cheap SFW **bulk** drafting; 网文 / 古风 / setting first-passes | Excellent Chinese genre logic; "文笔太硬" on tender emotion. **API ⇒ host-assembled context, not filesystem-first.** |

Routing inputs the conductor weighs per step: **task type** (prose vs. structure vs. continuity vs. ideation),
**importance** (signature vs. bulk), **language nuance** (emotional Chinese → Claude; genre Chinese → DeepSeek),
**cost/latency** (§7), and **content tier** (always SFW for moderated models — NSFW is off-limits by §3).

---

## 5. Play catalog

### Priority (first build)

1. **Idea → collaborate** — *"Here's a raw idea."*
   Conductor analyzes the idea + pulls relevant codex → fans out: **Grok** (wild angles) ∥ **Codex** (structural
   feasibility) ∥ **Claude** (voice/emotional core) → **Claude** synthesizes a proposal → `drafts/`.
2. **Adversarial review** — *"Audit this temp draft."*
   Independent critics with **distinct lenses**, in parallel: **Claude** (voice/emotion/character consistency) •
   **Codex** (structure/pacing/plot holes) • **Gemini** (continuity vs. the whole manuscript) • **Grok**
   (reader-grip / "爽点" / does it grip a 网文 reader). → dedupe + rank findings → `drafts/<name>.review.md`.
3. **Scene drafting (routed)** — importance-aware: signature/climax/emotional → **Claude**; bulk/genre/setting
   → **DeepSeek**. → `drafts/`.
4. **Continuity + voice audits** — on-demand single-lens passes: **Gemini** continuity, **Claude** voice/emotion.

### Fast-follows (designed now, built later)

5. **Outline / structure** — **Codex** on `codex/outline.md`: beat-sheet, pacing, subplot threading.
6. **Roundtable debate** — a craft question ("should X die here?") → N perspectives → **Claude** synthesis.
7. **Revision loop** — draft → critique → revise → verify, multi-round, sequenced.
8. **Worldbuilding / codex expansion** — build out `codex/` entries (**Claude** prose + **Codex** systematics).
9. **NSFW generation** — *separate, user-owned* (**Grok**, off-repo + in-repo synopsis/ref). The conductor only
   exposes a documented request interface; explicit output never enters the repo or a moderated model.

---

## 6. Conductor plan format (machine-readable hand-off)

The conductor emits JSON the host executes:

```json
{
  "play": "adversarial-review",
  "targets": ["drafts/ch03-rewrite.md"],
  "steps": [
    {"id":"voice",  "model":"claude","role":"audit",    "parallel_group":1,
     "reads":["drafts/ch03-rewrite.md","codex/characters/"],
     "writes":"drafts/.conduct/<job>/voice.md",  "instruction":"Critique voice, emotional truth, character consistency. Cite codex."},
    {"id":"struct", "model":"codex","role":"structure",  "parallel_group":1,
     "reads":["drafts/ch03-rewrite.md","codex/outline.md"],
     "writes":"drafts/.conduct/<job>/struct.md", "instruction":"Find structure/pacing/plot-hole issues vs the outline."},
    {"id":"cont",   "model":"agy","role":"continuity",   "parallel_group":1,
     "reads":["drafts/ch03-rewrite.md","manuscript/"],
     "writes":"drafts/.conduct/<job>/cont.md",   "instruction":"Contradictions vs the whole manuscript + timeline."},
    {"id":"synth",  "model":"claude","role":"prose",     "parallel_group":2,
     "reads":["drafts/.conduct/<job>/voice.md","drafts/.conduct/<job>/struct.md","drafts/.conduct/<job>/cont.md"],
     "writes":"drafts/ch03-rewrite.review.md",   "instruction":"Dedupe + rank all findings by severity; one action list."}
  ]
}
```

- `parallel_group` — same number ⇒ run concurrently; higher numbers depend on earlier groups' output files.
- Every step is filesystem-first (`reads`/`writes` are paths). DeepSeek steps instead get host-assembled context.
- `role` reuses the existing `resolve_model`/firewall vocabulary so the host dispatcher and leak guard apply unchanged.

---

## 7. Cost / latency policy

- **Cheap for bulk, premium for signature.** DeepSeek does first-pass/bulk; Claude does signature scenes +
  every synthesis step.
- **Parallel where independent, sequential where rate-limited.** Adversarial critics run concurrently;
  subscription lead roles (Claude/Codex/Grok) stay sequential within a group to respect rate limits.
- **Grok is slow (~2–3 min/job)** due to its telemetry hang — treat Grok steps as background and never block
  the human on them (kick off, collect later).

---

## 8. Recorded finding — Chinese-native models (future upgrade, NOT built now)

Benchmarks consistently show Chinese-native models lead **Simplified-Chinese** prose, beyond the five-CLI
backbone:

- **Kimi** (Moonshot) K2.6 — **highest-rated Chinese prose in 2026** (lowest "AI味"/slop) **and** 256K–2M
  context. Could own **both** Chinese prose-polish **and** long-context continuity (displacing Gemini, whose
  Chinese prose is weak).
- **GLM** (智谱) — best **character consistency** over long works (~3% drift at 200k+ chars vs. Kimi ~12%);
  strong instruction-following (GLM 5.1 IFEval 92).
- **Qwen** (通义千问) — strong **网文** plot/pacing & localization; cheap; sometimes templated.
- **DeepSeek** (already in stack) — top Chinese cost/quality for genre/setting; the wedge already proving the
  API-integration pattern these would reuse.

**Adoption path (when chosen):** mirror the DeepSeek API client in `bin/lib/run-model.sh`, add roles to
`resolve_model`, extend the model-strength map. The likely first add is **Kimi** (biggest single-add payoff:
Chinese prose + huge context). Deferred per user decision — backbone stays the five first-party CLIs for now.

---

## 9. What gets built next session — ✅ BUILT (Session 6, 2026-06-01)

- ✅ `bin/conduct` — the host-side conductor (request → plan → dispatch → synthesize → `drafts/`).
  Flags: `--play`, `--dry-run`, `--status`, `--timeout`. Engine in `bin/lib/conduct.sh`.
- ✅ Dispatch as **tracked background jobs** with a poll loop: per-step status files, per-step timeouts
  (Grok 420s), kill-on-timeout, a live status table, `--status` inspector. No silent hang/fail.
  Firewall via the proven `assemble_context`/`run_model` path (synopsis-substituted, leak-guarded) — see §3.
- ✅ The `conduct` bridge role (`bin/host-runner` special-cases it → `bin/conduct`) + `bridge-client` entry.
- ✅ Plays **1–4** (`idea`, `adversarial-review`, `scene-draft`, `continuity`, `voice`) as `--play` templates
  + the Sonnet planner that auto-classifies into them.
- ✅ OpenClaw front door: **① relay** (workspace `AGENTS.md` — DeepSeek forwards `conduct` verbatim) **and
  ② `/conduct` skill** (the `conduct-plugin` under `orchestration/openclaw/plugins/conduct/`, talks to the
  file bridge in-process via `node:fs`, loads in the gateway).
- ⏸ NSFW **off-repo migration** (`*.sfw.md` + `nsfw_ref`) — still deferred (needs the user's Python assembler).
- ⏸ Fast-follows 5–8.

## 10. Open questions — RESOLVED (Session 6)

1. **`nsfw_ref` schema** — ⏸ still deferred (migration out of scope; the firewall stays the in-repo
   synopsis-substitution model, which `bin/conduct` reuses unchanged).
2. **Synthesis model** — ✅ **Sonnet plans, Opus synthesizes** (`CONDUCT_PLAN_MODEL=sonnet`,
   `CONDUCT_SYNTH_MODEL=opus`; pinned via `CLAUDE_MODEL` in `run-model.sh`).
3. **Per-CLI sandbox flags** — ✅ **mooted by staging.** Each step builds firewalled context via
   `assemble_context` (synopsis-substituted for moderated roles) and dispatches through `run_model`'s leak
   guard — no reliance on per-CLI cwd/deny flags. (True path-based FS-first reading remains a future
   optimization; the firewall is enforced host-side regardless.)
4. **Conductor context index** — ✅ `conduct_index` lists `codex/ manuscript/ drafts/` filenames (names only)
   into the planner prompt. No generated index file needed.
5. **Grok latency** — ✅ **background + collect for every step**, with a per-step timeout (Grok gets 420s) and
   a live status table; nothing blocks indefinitely or fails silently. Grok is tagged "(slow ~2–3min)".

> Rejected: exposing the conductor as an OpenClaw model-picker provider (③). It would require an
> OpenAI-compatible HTTP shim in front of Claude, which `DESIGN.md` §7 forbids. The file bridge keeps it
> ToS-clean.
