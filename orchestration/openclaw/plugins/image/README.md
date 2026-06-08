# image-plugin — `/image` for OpenClaw

Registers an `/image` slash command that routes **directly** to the Mac `host-mcp` `image` tool (no
in-container LLM), generates an image with **gpt-image** (moderated) or **xAI grok-2-image** (NSFW-capable),
and relays the result to the originating QQ chat as a `base64://` OneBot image segment.

This is the **deterministic** image surface. The **agent-native** surface is separate: the in-container
`main` agent already has the `imagegen` skill (gpt-image, key-free) — "draw me X" in normal chat uses that.

## Why route through host-mcp (trust boundary)

The image API keys (`OPENAI_API_KEY` / `XAI_API_KEY`) live **only on the Mac** (`.env`, sourced by
`bin/host-mcp-run`). The NSFW-capable grok generator runs **behind the Mac firewall**, never on the shared
arch container. This plugin is thin: forward the prompt to host-mcp over the tailnet (Bearer, same transport
as `/conduct`), receive base64 image content, POST it to NapCat.

Egress is `base64://` (not a file path) because the openclaw container shares **no volume** with NapCat —
a path would not cross. base64 always works in a OneBot `image` segment.

## Usage (from the gated QQ chat)

```
/image a foggy harbor at dawn, watercolor
/image --provider grok a neon-lit alley in the rain
/image --provider gpt --size 1536x1024 --n 2 a cabin in a pine forest
```

- `--provider gpt|grok` — default `gpt` (override with plugin config `defaultProvider`).
- `--n 1-4` — number of images (default 1).
- `--size WxH` — gpt only (e.g. `1024x1024`, `1536x1024`, `1024x1536`, `auto`); grok ignores it.

## Build + install (inside the arch container)

The conduct plugin's discipline applies (read-only `/home/node`, npm cache → scratch). With the repo's
`bin/register-arch-image` helper, or manually:

```bash
# stage src + manifest into the container scratch, build with the version-exact toolchain, install
docker exec -w /workspace/scratch/image-plugin agent-lab-openclaw sh -lc '
  export HOME=/workspace/scratch npm_config_cache=/workspace/scratch/.npm &&
  npm install --include=dev && npm run build &&
  rm -rf node_modules &&
  openclaw plugins install /workspace/scratch/image-plugin --force &&
  openclaw plugins enable image-plugin
'
docker restart agent-lab-openclaw   # DISRUPTIVE to the shared lab — do when a blip is OK
```

## Config (kept out of git)

Reuses `channels.onebot.{httpUrl,accessToken}` for egress and the conduct plugin's host-mcp endpoint. The
host-mcp token is the only required secret; set per-key (token via stdin):

```bash
openclaw config set plugins.entries.image-plugin.config.hostMcpUrl http://100.94.171.80:8765/mcp
printf '%s' "$HOST_MCP_TOKEN" | openclaw config set plugins.entries.image-plugin.config.hostMcpToken --stdin
# optional: openclaw config set plugins.entries.image-plugin.config.defaultProvider grok
```

On the **Mac** `.env` (sourced by host-mcp): `OPENAI_API_KEY=` and/or `XAI_API_KEY=` (+ optional
`OPENAI_IMAGE_MODEL`, `XAI_IMAGE_MODEL`, `OPENAI_BASE_URL`, `XAI_BASE_URL`).

## Firewall posture

The prompt is forwarded to the provider **verbatim** and is never logged on the host (only provider + count
+ length). grok is NSFW-capable and intended for the human's own prompts; gpt is moderated and rejects
explicit content. Claude/Codex/Gemini must never author prompts for this tool.
