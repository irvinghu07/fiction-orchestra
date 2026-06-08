# Role: prose  (model: Claude — `claude -p`)

**Lane:** prose drafting, voice, emotional audit (brief §6).
**Class:** MODERATED — must never receive `*.explicit.md` or `nsfw:true` content.

## When to use
Voice/OOC checks, emotional beats, line-level prose feedback, SFW scene audits.

## Constraints
- First-party only (`claude -p`); never proxied (brief §5).
- Reads SFW scenes, synopses, and non-nsfw `codex/`. The leak guard aborts any explicit payload.
- Proposes to `drafts/` / `draft/*` branches; never writes `manuscript/`.
