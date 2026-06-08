import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";
import { saveMediaBuffer } from "openclaw/plugin-sdk/media-store";

// /image → host-mcp `image` tool on the Mac (gpt-image or xAI grok-2-image).
//
// Why route through host-mcp instead of calling the image APIs here: the keys
// (OPENAI_API_KEY / XAI_API_KEY) must never leave the Mac trust boundary, and the
// NSFW-capable grok generator must run behind the host firewall — not on the shared
// arch container. So this plugin is THIN: it forwards the prompt to host-mcp (Bearer,
// same transport as /conduct), receives base64 image content, and relays it to the
// originating QQ chat as a `base64://` OneBot image segment (the openclaw container has
// no shared volume with NapCat, so a file path won't cross — base64 always works).
//
// Registered as a NATIVE plugin slash command (see conduct/src/index.ts for the
// root-cause on why skill-based slash commands don't dispatch on this build).

const DEFAULT_URL = "http://100.94.171.80:8765/mcp"; // Mac tailnet host-mcp
const JOB_TIMEOUT_MS = 180_000; // image gen is fast (10-60s); cap generously

type ImageCfg = {
  hostMcpUrl?: string;
  hostMcpToken?: string;
  defaultProvider?: string;
  napcatHttpUrl?: string;
  napcatToken?: string;
};

// ─── host-mcp transport (mirrors conduct) ──────────────────────────────────
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

// ─── arg parsing ───────────────────────────────────────────────────────────
export type ImageArgs = { prompt: string; provider?: string; n?: number; size?: string };

// `/image [--provider gpt|grok] [--n 2] [--size 1536x1024] <prompt…>`
// Flags may appear anywhere; the remaining text (quotes stripped) is the prompt.
export function parseImageArgs(raw: string): ImageArgs {
  let provider: string | undefined;
  let n: number | undefined;
  let size: string | undefined;
  let s = raw;
  s = s.replace(/--provider\s+(gpt|grok|openai)\b/i, (_m, p) => {
    provider = String(p).toLowerCase();
    return "";
  });
  s = s.replace(/--n\s+(\d+)\b/i, (_m, x) => {
    n = Number(x);
    return "";
  });
  s = s.replace(/--size\s+(\S+)/i, (_m, x) => {
    size = String(x);
    return "";
  });
  let prompt = s.trim();
  const pairs: Array<[string, string]> = [['"', '"'], ["'", "'"], ["“", "”"]];
  for (const [a, b] of pairs) {
    if (prompt.length >= 2 && prompt.startsWith(a) && prompt.endsWith(b)) {
      prompt = prompt.slice(1, -1).trim();
      break;
    }
  }
  return { prompt, provider, n, size };
}

type GenImage = { data: string; mime: string; url?: string };

// Pull MCP image-content blocks out of the host-mcp tools/call result. An image
// block carries base64 `data` and/or a hosted `url` (xAI grok returns a url).
function extractImages(rpc: any): { images: GenImage[]; errorText: string } {
  const content: any[] = Array.isArray(rpc?.result?.content) ? rpc.result.content : [];
  const images: GenImage[] = [];
  const texts: string[] = [];
  for (const c of content) {
    if (c?.type === "image" && ((typeof c.data === "string" && c.data) || (typeof c.url === "string" && c.url))) {
      images.push({
        data: typeof c.data === "string" ? c.data : "",
        mime: typeof c.mimeType === "string" ? c.mimeType : "image/png",
        url: typeof c.url === "string" && c.url ? c.url : undefined,
      });
    } else if (c?.type === "text" && typeof c.text === "string") {
      texts.push(c.text);
    }
  }
  return { images, errorText: texts.join("\n").trim() };
}

// ─── NapCat egress (base64 image segment) ──────────────────────────────────
type NapcatTarget = { endpoint: string; body: Record<string, number> };
type Napcat = { httpUrl: string; token: string };

function parseOnebotTarget(from: string): NapcatTarget | null {
  const m = /^(?:onebot:)?(private|group):(\d+)$/.exec(from || "");
  if (!m) return null;
  return m[1] === "group"
    ? { endpoint: "send_group_msg", body: { group_id: Number(m[2]) } }
    : { endpoint: "send_private_msg", body: { user_id: Number(m[2]) } };
}

function resolveNapcat(ctx: any, cfg: ImageCfg): Napcat | null {
  const ob = ctx?.config?.channels?.onebot ?? {};
  const httpUrl = String(cfg.napcatHttpUrl || ob.httpUrl || "http://127.0.0.1:3010").replace(/\/+$/, "");
  const token = String(cfg.napcatToken || ob.accessToken || "");
  if (!token) return null;
  return { httpUrl, token };
}

// Persist generated images to the gateway media store and return their paths. This
// is the canonical render path for the OpenClaw panel/webchat/CLI/native surfaces —
// the same `saveMediaBuffer` → mediaUrl mechanism the built-in /context map image uses.
// Build renderable media paths for the OpenClaw control-ui (browser webchat). Per
// control-ui.md: the browser's img-src CSP allows only same-origin / data: / blob: —
// remote http(s) image urls are BLOCKED, and the reply resolver drops data: urls. The
// only thing that renders is a MANAGED MEDIA reference, which the gateway serves back as
// a same-origin authenticated url. So persist every image (downloading grok's hosted url
// for its bytes) via saveMediaBuffer and return the managed path; the resolver turns it
// into the served url (do NOT set sensitiveMedia/trustedLocalMedia — those skip it).
async function toPanelMediaUrls(images: GenImage[]): Promise<string[]> {
  const out: string[] = [];
  for (const img of images) {
    try {
      let buf: Buffer;
      let mime = img.mime || "image/png";
      if (img.data) {
        buf = Buffer.from(img.data, "base64");
      } else if (img.url) {
        const r = await fetch(img.url);
        if (!r.ok) {
          console.error(`[image] fetch url HTTP ${r.status}`);
          continue;
        }
        const ct = r.headers.get("content-type");
        if (ct) mime = ct.split(";")[0].trim();
        buf = Buffer.from(await r.arrayBuffer());
      } else {
        continue;
      }
      const saved = await saveMediaBuffer(buf, mime, "image-gen");
      if (saved?.path) out.push(saved.path);
    } catch (err) {
      console.error(`[image] media persist failed: ${String(err).slice(0, 200)}`);
    }
  }
  return out;
}

// Send an image to QQ. PREFER a hosted url: this NapCat build sends url images fine
// but times out on inline `base64://` (NTEvent sendMsg/onMsgInfoListUpdate). base64 is
// only the fallback for providers that return no url (e.g. gpt-image).
async function sendNapcatImage(napcat: Napcat, target: NapcatTarget, img: GenImage): Promise<boolean> {
  const file = img.url ? img.url : `base64://${img.data}`;
  try {
    const res = await fetch(`${napcat.httpUrl}/${target.endpoint}`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${napcat.token}` },
      body: JSON.stringify({ ...target.body, message: [{ type: "image", data: { file } }] }),
    });
    if (!res.ok) {
      console.error(`[image] napcat send HTTP ${res.status}`);
      return false;
    }
    const j: any = await res.json().catch(() => null);
    if (j && typeof j.retcode === "number" && j.retcode !== 0) {
      console.error(`[image] napcat retcode ${j.retcode}`);
      return false;
    }
    return true;
  } catch (err) {
    console.error(`[image] napcat send failed: ${String(err).slice(0, 200)}`);
    return false;
  }
}

// ─── core ──────────────────────────────────────────────────────────────────
export async function runImage(
  args: ImageArgs,
  cfg: ImageCfg,
): Promise<{ images: GenImage[]; text: string }> {
  const url = cfg.hostMcpUrl || DEFAULT_URL;
  const token = cfg.hostMcpToken || "";
  const provider = args.provider || cfg.defaultProvider || "gpt";
  const ac = new AbortController();
  const timer = setTimeout(() => ac.abort(), JOB_TIMEOUT_MS);
  try {
    const toolArgs: Record<string, unknown> = { prompt: args.prompt, provider };
    if (args.n) toolArgs.n = args.n;
    if (args.size) toolArgs.size = args.size;
    const rpc = await callHostTool("image", toolArgs, { url, token, signal: ac.signal });
    if (rpc?.error) return { images: [], text: `image error: ${rpc.error.message ?? JSON.stringify(rpc.error)}` };
    const { images, errorText } = extractImages(rpc);
    if (rpc?.result?.isError) return { images: [], text: errorText || "image tool reported an error." };
    if (images.length === 0) return { images: [], text: errorText || "(no image returned)" };
    return { images, text: "" };
  } catch (err) {
    const aborted = (err as any)?.name === "AbortError";
    return {
      images: [],
      text: aborted
        ? `image timed out after ${Math.round(JOB_TIMEOUT_MS / 1000)}s (is host-mcp reachable on the tailnet?)`
        : `image failed: ${String(err)}`,
    };
  } finally {
    clearTimeout(timer);
  }
}

export default definePluginEntry({
  id: "image-plugin",
  name: "Image",
  description: "Generate an image via the Mac host-mcp image tool (gpt/grok) and relay it to the chat.",
  register(api: any) {
    api.registerCommand({
      name: "image",
      description:
        'Generate an image on the Mac host (gpt-image or xAI grok). Usage: /image [--provider gpt|grok] [--n 1] [--size 1024x1024] "<prompt>"',
      acceptsArgs: true,
      handler: async (ctx: any) => {
        const raw = String(ctx?.args ?? "").trim();
        if (!raw) return { text: 'Usage: /image [--provider gpt|grok] [--n 1] [--size 1024x1024] "<prompt>"' };
        const cfg = (api?.pluginConfig ?? {}) as ImageCfg;
        const args = parseImageArgs(raw);
        if (!args.prompt) return { text: "image: empty prompt." };

        const { images, text } = await runImage(args, cfg);
        if (images.length === 0) return { text: text || "image generation failed." };

        // QQ (onebot): the openclaw container shares no volume with NapCat, so a media
        // file path won't cross — push the image directly as a base64 OneBot segment.
        if (ctx?.channel === "onebot") {
          const target = parseOnebotTarget(String(ctx?.from ?? ""));
          const napcat = resolveNapcat(ctx, cfg);
          if (target && napcat) {
            let sent = 0;
            for (const img of images) {
              if (await sendNapcatImage(napcat, target, img)) sent++;
            }
            if (sent > 0) return { text: sent === images.length ? "" : `Sent ${sent}/${images.length} images.` };
            return { text: "Generated the image but couldn't deliver it to QQ (check NapCat / token)." };
          }
        }

        // Every other surface (OpenClaw control-ui/webchat/CLI): pass a fetchable url (grok's
        // hosted url) or a managed media path. Do NOT set sensitiveMedia/trustedLocalMedia —
        // those skip the resolver that the control-ui needs to fetch/serve the image.
        const provider = args.provider || cfg.defaultProvider || "image";
        const mediaUrls = await toPanelMediaUrls(images);
        if (mediaUrls.length > 0) {
          const caption = `🎨 ${provider}`;
          return mediaUrls.length === 1
            ? { text: caption, mediaUrl: mediaUrls[0] }
            : { text: caption, mediaUrls };
        }
        return { text: `🎨 generated ${images.length} image(s) but couldn't attach them.` };
      },
    });
  },
});
