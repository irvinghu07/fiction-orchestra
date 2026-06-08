# Role: conduct  (model: Claude — `claude -p`, Sonnet plans / Opus synthesizes)

**Lane:** the Orchestration Conductor (docs/ORCHESTRATION.md). Hand it a raw idea / messy draft /
craft question; it classifies intent, picks the right specialist models, has them collaborate
over the filesystem, and returns a composed artifact in `drafts/`.
**Class:** MODERATED — the conductor and every step it dispatches are firewalled; explicit prose
never reaches it. (NSFW remains a separate, user-owned Grok lane, off-limits to the conductor.)

## When to use
The high-level entry: "develop this idea", "review this draft from all angles", "draft this scene",
"continuity/voice pass". Prefer this over single-role calls when the work wants more than one model.

## How it runs
- Host-side only (`bin/conduct`); the bridge role `conduct` routes a request from the OpenClaw
  container to `bin/conduct` via `bin/host-runner` (file bridge — no proxy, ToS-clean, brief §5).
- Loop: plan (Sonnet) → dispatch specialist steps as tracked background jobs → synthesize (Opus)
  → write `drafts/<artifact>.md` + an audit trail under `drafts/.conduct/<job>/`.
- Plays: `idea` · `adversarial-review` · `scene-draft` · `continuity` · `voice`.

## Constraints
- First-party only (`claude -p`); never proxied. Each step passes through `run_model`'s leak guard.
- Reads SFW scenes, synopses, and non-nsfw `codex/`; an `*.explicit.md` target is synopsis-substituted.
- Proposes to `drafts/` only; never writes `manuscript/`.
