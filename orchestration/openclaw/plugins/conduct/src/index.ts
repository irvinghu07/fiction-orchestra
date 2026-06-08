import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";

// /conduct → host Orchestration Conductor, the DETERMINISTIC (LLM-bypass) path.
//
// Registered as a NATIVE plugin slash command (api.registerCommand), NOT a skill
// `command-dispatch: tool`. On OpenClaw 2026.5.22, skill-based slash commands are
// silently forwarded to the in-container model unless a model alias is configured
// — get-reply's skill-command loader is gated on `hasConfiguredModelAliases`
// (rawAliases.length > 0), and the resulting empty array short-circuits the
// dispatch path. A native plugin command registers at startup and dispatches
// deterministically regardless of aliases. Full root-cause + research log:
// drafts/openclaw-command-dispatch.md.
//
// The handler forwards the raw arg string to the Mac host-mcp `conduct` tool over
// HTTP (Bearer). The host parses + firewalls the request (parseRawInvocation).
// Live per-lane progress shows in the Mac "Island" cockpit via host /live/events.

const DEFAULT_URL = "http://100.94.171.80:8765/mcp"; // Mac tailnet host-mcp
const DEFAULT_LIVE_URL = "http://100.94.171.80:8765/live/events"; // host-mcp SANITIZED progress SSE
const JOB_TIMEOUT_MS = 1_800_000; // matches the conductor's own job cap (Grok ~2-3m + synth)

type ConductCfg = {
  hostMcpUrl?: string;
  hostMcpToken?: string;
  // Live-progress relay (B): all optional — fall back to channels.onebot.* + defaults.
  napcatHttpUrl?: string;
  napcatToken?: string;
  liveEventsUrl?: string;
};

// Extract the JSON-RPC result/error from an MCP Streamable-HTTP (SSE) response.
// host-mcp answers tools/call as zero+ `: keepalive` lines and `data: <json>`
// frames; the last result-bearing frame carries {result|error}. Falls back to
// parsing the whole body as plain JSON if it isn't SSE. Exported for tests.
export function parseRpcFromSse(body: string): any | null {
  let last: any = null;
  for (const line of body.split(/\r?\n/)) {
    const s = line.replace(/^\s+/, "");
    if (!s.startsWith("data:")) continue;
    const payload = s.slice(5).trim();
    if (!payload || payload === "[DONE]") continue;
    try {
      const obj = JSON.parse(payload);
      if (obj && (obj.result !== undefined || obj.error !== undefined)) last = obj;
    } catch {
      /* ignore non-JSON data lines */
    }
  }
  if (last) return last;
  try {
    return JSON.parse(body);
  } catch {
    return null;
  }
}

// Call a host-mcp tool over HTTP and return its JSON-RPC response (result|error).
// Token/url are passed in (sourced from plugin config) — never read from the
// process environment (OpenClaw's installer flags env-read-next-to-network-send
// as credential harvesting). Exported for transport tests (e.g. vs `slowtick`).
export async function callHostTool(
  name: string,
  args: Record<string, unknown>,
  opts: { url?: string; token?: string; signal?: AbortSignal } = {},
): Promise<any> {
  const url = opts.url || DEFAULT_URL;
  const token = opts.token ?? "";
  const res = await fetch(url, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Accept: "application/json, text/event-stream",
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name, arguments: args } }),
    signal: opts.signal,
  });
  const body = await res.text();
  if (!res.ok) {
    return { error: { message: `host-mcp HTTP ${res.status}: ${body.slice(0, 400)}` } };
  }
  return parseRpcFromSse(body) ?? { error: { message: `unparseable host-mcp response: ${body.slice(0, 400)}` } };
}

// Forward a raw "/conduct" arg string to host-mcp and return the composed text.
// Exported so the handler stays thin and the logic is unit-testable.
export async function runConduct(raw: string, cfg: { hostMcpUrl?: string; hostMcpToken?: string }): Promise<string> {
  const url = cfg.hostMcpUrl || DEFAULT_URL;
  const token = cfg.hostMcpToken || "";
  const ac = new AbortController();
  const timer = setTimeout(() => ac.abort(), JOB_TIMEOUT_MS);
  try {
    const rpc = await callHostTool("conduct", { raw }, { url, token, signal: ac.signal });
    if (rpc?.error) return `conduct error: ${rpc.error.message ?? JSON.stringify(rpc.error)}`;
    const content = Array.isArray(rpc?.result?.content) ? rpc.result.content : [];
    const out = content.map((c: any) => (c && typeof c.text === "string" ? c.text : "")).join("\n").trim();
    if (rpc?.result?.isError) return out || "conduct reported an error with no detail.";
    return out || "(conductor returned no text)";
  } catch (err) {
    const aborted = (err as any)?.name === "AbortError";
    return aborted
      ? `conduct timed out after ${Math.round(JOB_TIMEOUT_MS / 1000)}s (is host-mcp reachable on the tailnet?)`
      : `conduct failed: ${String(err)}`;
  } finally {
    clearTimeout(timer);
  }
}

// ─── B: live-progress relay → QQ ───────────────────────────────────────────
// While a /conduct run is in flight (1–5 min), narrate stage transitions to the
// originating QQ chat so the operator isn't staring at a silent wait. SOURCE is
// host-mcp's SANITIZED /live/events SSE (play + per-lane id/model/status only —
// never instruction/targets/draft text). EGRESS is NapCat's OneBot HTTP API. The
// relay is fire-and-forget and never throws into the handler: any fault → silent,
// the final draft still lands via the normal command reply.

// model → display name (mirrors bin/lib/common.sh resolve_model/role_label).
const MODEL_FRIENDLY: Record<string, string> = {
  claude: "Claude",
  deepseek: "DeepSeek",
  grok: "Grok",
  kimi: "Kimi",
  codex: "Codex/GPT",
  agy: "Gemini",
  gemini: "Gemini",
};
function friendly(model: string): string {
  return MODEL_FRIENDLY[(model || "").toLowerCase()] ?? (model || "a model");
}
function laneVerb(id: string): string {
  const s = (id || "").toLowerCase();
  if (/draft|write|prose|scene/.test(s)) return "drafting";
  if (/review|audit|continuity|check|grip/.test(s)) return "reviewing";
  return "composing";
}

type NapcatTarget = { endpoint: string; body: Record<string, number> };
type Napcat = { httpUrl: string; token: string };

// "onebot:private:12345" | "onebot:group:678" → the OneBot send action + ids.
// Mirrors openclaw-onebot outbound.js parseTarget.
function parseOnebotTarget(from: string): NapcatTarget | null {
  const m = /^(?:onebot:)?(private|group):(\d+)$/.exec(from || "");
  if (!m) return null;
  return m[1] === "group"
    ? { endpoint: "send_group_msg", body: { group_id: Number(m[2]) } }
    : { endpoint: "send_private_msg", body: { user_id: Number(m[2]) } };
}

// Resolve NapCat creds: explicit plugin config → the already-configured onebot
// channel → localhost default. Token NEVER from process.env (installer flags
// env-read-next-to-fetch as credential harvesting); only ctx.config / pluginConfig.
function resolveNapcat(ctx: any, cfg: ConductCfg): Napcat | null {
  const ob = ctx?.config?.channels?.onebot ?? {};
  const httpUrl = String(cfg.napcatHttpUrl || ob.httpUrl || "http://127.0.0.1:3010").replace(/\/+$/, "");
  const token = String(cfg.napcatToken || ob.accessToken || "");
  if (!token) return null; // never send unauthenticated
  return { httpUrl, token };
}

async function sendNapcatText(napcat: Napcat, target: NapcatTarget, text: string): Promise<void> {
  try {
    await fetch(`${napcat.httpUrl}/${target.endpoint}`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${napcat.token}` },
      body: JSON.stringify({ ...target.body, message: [{ type: "text", data: { text } }] }),
    });
  } catch (err) {
    console.error(`[conduct] napcat send failed: ${String(err).slice(0, 200)}`);
  }
}

// Subscribe to /live/events, diff lane/state transitions, push concise friendly
// lines to QQ. De-duped per (run,lane,status); rate-floored so concurrent lane
// flips coalesce. Ends when `signal` aborts (handler finally) or the stream closes.
async function startProgressRelay(opts: {
  liveEventsUrl: string;
  napcat: Napcat;
  target: NapcatTarget;
  signal: AbortSignal;
}): Promise<void> {
  const { liveEventsUrl, napcat, target, signal } = opts;
  const startMs = Date.now();
  const seen = new Set<string>();
  let pinnedRunId: string | null = null;
  let lastSendMs = 0;
  const RATE_MS = 1500;

  const emit = async (key: string, text: string) => {
    if (seen.has(key)) return;
    seen.add(key);
    const wait = RATE_MS - (Date.now() - lastSendMs);
    if (wait > 0) await new Promise((r) => setTimeout(r, wait));
    lastSendMs = Date.now();
    await sendNapcatText(napcat, target, text);
  };

  const handleFrame = async (s: any) => {
    if (!s || typeof s !== "object") return;
    const runId = String(s.runId ?? "");
    const state = String(s.state ?? "");
    const updatedAt = s.updatedAt ? Date.parse(s.updatedAt) : 0;
    // Pin to the first FRESH run (ignore a stale prior run's tail).
    if (!pinnedRunId) {
      if ((state === "starting" || state === "running") && (!updatedAt || updatedAt >= startMs - 2000)) {
        pinnedRunId = runId || "_";
      } else {
        return;
      }
    }
    if (runId && pinnedRunId !== "_" && runId !== pinnedRunId) return;

    const lanes: any[] = Array.isArray(s.lanes) ? s.lanes : [];
    if (lanes.length === 0 && (state === "starting" || state === "running")) {
      await emit(`${pinnedRunId}:plan`, "🧭 Sonnet is planning…");
    }
    for (const ln of lanes) {
      if (ln?.status !== "running") continue;
      const id = String(ln.id ?? "");
      const key = `${pinnedRunId}:${id}:running`;
      if (seen.has(key)) continue;
      const msg = /synth/i.test(id)
        ? "🎼 Opus is synthesizing…"
        : `✍️ ${friendly(String(ln.model ?? ""))} is ${laneVerb(id)}…`;
      await emit(key, msg);
    }
    if (state === "done") {
      const rel = typeof s.artifactRel === "string" && s.artifactRel ? ` → ${s.artifactRel}` : "";
      await emit(`${pinnedRunId}:done`, `🎼 Draft ready.${rel}`);
    } else if (state === "failed" || state === "timeout") {
      await emit(`${pinnedRunId}:end`, `⚠️ Conductor ${state}.`);
    }
  };

  try {
    const res = await fetch(liveEventsUrl, { signal, headers: { Accept: "text/event-stream" } });
    if (!res.ok || !res.body) return;
    const reader = (res.body as any).getReader();
    const decoder = new TextDecoder();
    let buf = "";
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      buf += decoder.decode(value, { stream: true });
      let idx: number;
      while ((idx = buf.indexOf("\n\n")) >= 0) {
        const block = buf.slice(0, idx);
        buf = buf.slice(idx + 2);
        for (const line of block.split(/\r?\n/)) {
          const t = line.replace(/^\s+/, "");
          if (!t.startsWith("data:")) continue;
          const payload = t.slice(5).trim();
          if (!payload) continue;
          try {
            await handleFrame(JSON.parse(payload));
          } catch {
            /* non-JSON data line — ignore */
          }
        }
      }
    }
  } catch (err) {
    if ((err as any)?.name !== "AbortError") {
      console.error(`[conduct] progress relay error: ${String(err).slice(0, 200)}`);
    }
  }
}

export default definePluginEntry({
  id: "conduct-plugin",
  name: "Conduct",
  description: "Route a request to the host Orchestration Conductor (LLM-bypass; MCP-over-HTTP).",
  // configSchema (hostMcpUrl/hostMcpToken) is declared in openclaw.plugin.json as
  // raw JSON Schema — the SDK's typed configSchema field rejects a plain JSON
  // schema literal, and the manifest schema is what OpenClaw validates config
  // against (proven with `openclaw config set plugins.entries.conduct-plugin…`).
  register(api: any) {
    api.registerCommand({
      name: "conduct",
      description:
        "Hand a request to the host Orchestration Conductor (Sonnet plans, Opus synthesizes); returns a composed draft. Bypasses the in-container model.",
      acceptsArgs: true,
      handler: async (ctx: any) => {
        const raw = String(ctx?.args ?? "").trim();
        if (!raw) return { text: 'Usage: /conduct "<request>" [repo-relative target paths]' };
        const cfg = (api?.pluginConfig ?? {}) as ConductCfg;

        // B: narrate stage transitions to the originating QQ chat while conduct runs.
        // Only for the onebot channel with resolvable creds; otherwise unchanged.
        let relayAc: AbortController | null = null;
        let relay: Promise<void> | null = null;
        if (ctx?.channel === "onebot") {
          const target = parseOnebotTarget(String(ctx?.from ?? ""));
          const napcat = resolveNapcat(ctx, cfg);
          if (target && napcat) {
            relayAc = new AbortController();
            const liveEventsUrl = String(cfg.liveEventsUrl || DEFAULT_LIVE_URL).replace(/\/+$/, "");
            relay = startProgressRelay({ liveEventsUrl, napcat, target, signal: relayAc.signal });
          }
        }

        try {
          return { text: await runConduct(raw, cfg) };
        } finally {
          relayAc?.abort();
          if (relay) await relay.catch(() => {});
        }
      },
    });
  },
});
