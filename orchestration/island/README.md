# Fiction Island — the Mac cockpit 🛰️

A small always-on-top Tauri companion that shows the conductor's **live writers'-room board**,
fires **native notifications** on run transitions, and gives one-click **operator ops**
(Tailscale, OpenClaw, `fiction-doctor`, host-mcp restart).

It **monitors** `host-mcp`; it does not replace it. `host-mcp` stays the headless Go trust
boundary that arch's OpenClaw calls over the tailnet. The cockpit only consumes the
**sanitized** `/live/events` feed — no instruction/target text ever reaches it (firewall-safe
by construction; see `docs/DEVLOG.md` Session 21 and the firewall gate in `host-mcp`).

## What it shows
- **Pill** (always visible): status dot (idle/running/done/failed), play name, lane count, live/offline.
- **Board** (expand via ▾): one card per sub-agent — `id · model · status · elapsed`.
- **Ops panel**: Tailscale up/down + bring-up, open OpenClaw Control UI, run `fiction-doctor`,
  restart `host-mcp`.
- **Notifications**: started / done / failed / timed-out — once per run-state, sanitized.

## Build
```sh
cd orchestration/island/src-tauri
cargo tauri build          # → target/release/bundle/macos/Fiction Island.app (+ dmg)
```
Dev (live-reload, opens a window):
```sh
cargo tauri dev
```

## Configure
The host-mcp URL and OpenClaw URL are set in the app's **Settings** (gear/▾ → Settings),
persisted in localStorage. Defaults:
- host-mcp: `http://100.94.171.80:8765` (the Mac's tailnet IP)
- OpenClaw: `https://claw.errpthan.com`

## Launch at login
Drag **Fiction Island.app** into **System Settings → General → Login Items**, _or_ install the
LaunchAgent:
```sh
cp orchestration/island/ai.openclaw.fiction-island.plist ~/Library/LaunchAgents/
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/ai.openclaw.fiction-island.plist
```
(Edit the plist's app path first if you installed the .app somewhere other than `/Applications`.)

## Notes
- A GUI app posts notifications reliably (no launchd `Background`-agent gating that a Go-side
  `osascript` path would have hit).
- The cockpit infers `host-mcp` liveness from the SSE connection; the **Restart** button runs
  `launchctl kickstart -k gui/<uid>/ai.openclaw.fiction-host-mcp`.
- Tailscale/doctor shell-outs use a hardened PATH (a Finder-launched app inherits a minimal one).
