# conduct-plugin — `/conduct` for OpenClaw

Registers a `/conduct` slash command that routes **directly** to the `conduct_run` tool (no in-container
LLM), which calls `bridge-client conduct "<request>" [targets]` → the host `bin/host-runner` → `bin/conduct`
(the Orchestration Conductor: Sonnet plans, Opus synthesizes). ToS-clean — Claude runs first-party on the
host; the container only writes a bridge job (file IPC, no shim).

This is OpenClaw entry **②** (the clean LLM-bypass trigger). Entry **①** is the relay documented in the
workspace `AGENTS.md` (DeepSeek forwards a `conduct` request verbatim) and works with no plugin at all.

## Build + install (run inside the container)

The plugin is mounted read-only at `/workspace/plugins/conduct` (see `docker-compose.yml`). Build and
install it with the version-exact toolchain:

```bash
docker exec -w /workspace/plugins/conduct fiction-openclaw sh -lc '
  npm install &&
  npm run plugin:build &&            # tsc -> dist/index.js, then openclaw plugins build
  node /app/openclaw.mjs plugins install --link /workspace/plugins/conduct &&
  node /app/openclaw.mjs plugins enable conduct-plugin
'
docker restart fiction-openclaw
```

Or apply the committed config patch (registers the load path + enables it + the skill) and restart:

```bash
docker exec -i fiction-openclaw node openclaw.mjs config patch --stdin \
  < orchestration/openclaw-conduct-patch.json
docker restart fiction-openclaw
```

## Verify

```bash
docker exec fiction-openclaw node openclaw.mjs plugins list      # conduct-plugin present + enabled
docker exec fiction-openclaw node openclaw.mjs plugins doctor     # no load errors
# then in the Control panel:  /conduct "Continuity pass" manuscript/ch01/s01.md
```

`bin/host-runner` must be running on the host (it is, as a launchd service) for the bridge to round-trip.

## Two things that MUST be true for `/conduct` to register (learned the hard way)

1. **The manifest must not be "stale."** `openclaw plugins validate` fails with *"generated metadata is stale —
   run openclaw plugins build"* if `openclaw.plugin.json` doesn't match the entry (notably the `description`
   must equal the entry's top-level `description`). A stale manifest makes the loader **silently skip the
   `conduct_run` tool**, so the command can't bind. Fix: `openclaw plugins build` and commit the result
   (the committed `openclaw.plugin.json` here is already in sync with `dist/index.js`).
2. **The skill must live in the workspace skills dir**, not only the plugin's `./skills`. The plugin's
   `skills: ["./skills"]` contribution did **not** surface `/conduct` as a user command; copying the skill to
   `<workspace>/skills/conduct/SKILL.md` (i.e. `orchestration/openclaw/config/workspace/skills/conduct/SKILL.md`,
   which mounts to `/home/node/.openclaw/workspace/skills/conduct/`) made it show as **Enabled / eligible** in
   the panel ("Source: openclaw-workspace"). Keep both: the **plugin** provides the `conduct_run` tool; the
   **workspace skill** wires `/conduct → conduct_run` (`command-dispatch: tool`, bypassing the in-container LLM).

## Confirmed working (OpenClaw 2026.5.28)

`/conduct <request> <targets>` in the Control panel dispatches **directly to `conduct_run`, bypassing the
in-container DeepSeek agent** (verified end-to-end: a `job-conduct-*` bridge job + a composed artifact with the
`contributors:` block). The conductor auto-classifies and runs the right models with full per-step attribution.

### ⚠️ Arg field gotcha (cost us a debugging round)
`command-arg-mode: raw` is documented to deliver the raw args in a **`command`** field — that is **wrong** for
2026.5.28. The real payload is `{ "commandText": "<raw args>" }` (no `command`, `commandName`, or `skillName`).
`conduct_run` therefore reads a **priority list** — `commandText` → `commandBody` → `commandArgs` →
`commandInput` → `command` → `args` → `input` — and ignores any value equal to the command name. It also splits
path-like tokens (contain `/` or end in `.md`) into `targets` so **quotes are not required**:
`/conduct Continuity pass manuscript/ch01/s01.md` → request `"Continuity pass"`, target `manuscript/ch01/s01.md`.
The tool writes the exact params it received to `bridge/conduct-last-params.json` for future debugging.
- The SDK import (`openclaw/plugin-sdk/tool-plugin`) resolves at gateway load (and during `plugins build`),
  not from standalone node.
- If the chat rendering of the tool result needs a specific shape, adjust the `execute` return in
  `src/index.ts` + `dist/index.js` (currently `{ ok, output }`).
- The `openclaw agent` CLI connects to the default gateway port (18789); this stack runs the gateway on 19001,
  so the CLI falls back to an embedded agent and is NOT a faithful test of the panel's command-dispatch — test
  `/conduct` in the Control panel, not via `openclaw agent`.
