# Fiction Orchestra

A local, git-based multi-agent **"writers' room"**: a fleet of LLMs, each assigned a
role, collaborate over the same Markdown files through a human-in-the-loop review loop.
Built to explore multi-model orchestration, the Model Context Protocol (MCP), and
distributed agent infrastructure.

> This is the **orchestration / engineering layer only**. The creative content
> (manuscript, story bible, drafts) is intentionally excluded from this repository.

## Architecture

- A **conductor** runs on a separate Linux box and drives the workflow.
- The chat models stay **first-party on the Mac host** (reached through their native
  CLIs), bridged to the conductor by a custom **MCP server** (`host-mcp`, ~1.2k-LOC Go)
  speaking **MCP Streamable HTTP over Tailscale**.
- **Role-based + content-based routing**: each model handles the lane it is best at.
- Host services are **launchd-managed**, with a Docker fallback path.

| Lane                        | Model          |
|-----------------------------|----------------|
| prose / voice               | Claude (CLI)   |
| whole-document continuity   | Gemini (CLI)   |
| structure / formatting      | Codex (CLI)    |
| brainstorming / alt angles  | Grok (CLI)     |
| cheap bulk / first passes   | DeepSeek (API) |

## Workflow ("plays")

Reusable scripts in `bin/plays/` drive the loop: `audit-scene`, `refine-character`,
`inspire`, `discuss-outline`, `propose`, `promote`. The author writes; a play dispatches
the right agent(s); agents read the relevant context and propose changes in a scratch
branch; the author reviews the diff and promotes accepted work.

## Layout

```
orchestration/  conductor configs, role definitions, host-mcp (Go), launchd templates
bin/            host infra: conductor, MCP server, control scripts
bin/plays/      the writing workflows
docs/           architecture & deployment docs
AGENTS.md       the contract every agent reads first
```

## Setup

See `docs/DEPLOY.md` for what runs where and how to redeploy. Secrets live in a local
`.env` (copy from `.env.example` patterns) and are **never committed**.
