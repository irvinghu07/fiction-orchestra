---
name: conduct
description: Hand a request to the host-side Orchestration Conductor; returns a composed draft. Bypasses the in-container LLM.
user-invocable: true
disable-model-invocation: true
command-dispatch: tool
command-tool: conduct_run
command-arg-mode: raw
---

# /conduct

Send a request straight to the **host-side Orchestration Conductor** (Claude — Sonnet plans, Opus
synthesizes). The conductor classifies intent, runs the right specialist models in parallel over the
filesystem, and writes a composed draft to `drafts/`. The in-container model is **not** involved — this
command routes directly to the `conduct_run` tool, which forwards the raw request to the Mac host-mcp
`conduct` tool over the tailnet (HTTP). The host parses + firewalls it.

**Usage**

```
/conduct "<request>" [repo-relative-target ...]
```

**Examples**

```
/conduct "Develop this idea: Mara discovers the foundry is alive" 
/conduct "Review this draft from every angle" drafts/ch03-rewrite.md
/conduct "Continuity pass" manuscript/ch01/s01.md
```

Conductor jobs run several models (including slow Grok, ~2–3 min), so they take longer than a single
call; `conduct_run` uses a long (~30 min) timeout. **You can watch it work** in the Mac "Island" cockpit
(or the host `/live` dashboard) — per-lane planning / running / done with timings — and the final draft
arrives prefixed with a summary of what each model contributed and whether any step failed.
