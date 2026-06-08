// Fiction Island cockpit frontend. Consumes the SANITIZED /live/events SSE feed,
// renders the per-lane board, and fires native notifications (via the Rust `notify`
// command) on run-state transitions. Ops buttons invoke Rust commands. No
// instruction/target text is ever present in this feed — sanitized at the source.

const T = window.__TAURI__ || null;
const invoke = T && T.core && T.core.invoke ? T.core.invoke : async () => ({});
const appWindow = T && T.window ? T.window.getCurrentWindow() : null;
const LogicalSize = T && T.window ? T.window.LogicalSize : null;

const DEFAULTS = { host: "http://100.94.171.80:8765", claw: "https://claw.errpthan.com" };
// migrate the previous default OpenClaw URL to the new domain
if (localStorage.getItem("claw") === "http://arch:19001") {
  localStorage.setItem("claw", DEFAULTS.claw);
}
const cfg = {
  host: localStorage.getItem("host") || DEFAULTS.host,
  claw: localStorage.getItem("claw") || DEFAULTS.claw,
};

const $ = (id) => document.getElementById(id);
const GLYPH = { running: "⏳", done: "✓", failed: "✗", timeout: "⏱", pending: "·" };
const trim = (u) => u.replace(/\/+$/, "");

let es = null;
let expanded = false;
const notified = new Set();

function escapeHtml(x) {
  return String(x == null ? "" : x).replace(
    /[&<>"]/g,
    (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c])
  );
}

function setConn(on) {
  const c = $("conn");
  c.className = "conn " + (on ? "on" : "off");
  const b = c.querySelector("b");
  if (b) b.textContent = on ? "live" : "offline";
}

// --- smooth elapsed clocks ---------------------------------------------------
// The server only publishes a frame when the board text changes (~every 2s), so
// raw elapsedSeconds jumps and looks frozen between frames. We anchor each
// running lane to (serverElapsed, receiveTime) and a local 1s ticker counts up
// from there — re-syncing on every server frame. Finished/pending lanes are static.
let current = null;
let lastSig = "";
const anchor = {}; // laneId -> { base, ts }

function elapsedFor(l) {
  if (l.status === "running" && anchor[l.id]) {
    return Math.floor(anchor[l.id].base + (Date.now() - anchor[l.id].ts) / 1000);
  }
  return l.elapsedSeconds || 0;
}

const SHOW_EL = { running: 1, done: 1, failed: 1, timeout: 1 };

// What each lane is actually doing — the conductor's step roles (bin/lib/conduct.sh
// plans). Keyed by step id; unknown ids (e.g. planner-generated) fall back to just
// the model. SFW labels only.
const DESC = {
  angles: "brainstorming bold angles",
  feas: "checking structural feasibility",
  core: "finding the emotional core",
  synth: "synthesizing the final draft",
  voice: "auditing voice & emotion",
  struct: "checking structure & pacing",
  cont: "checking continuity vs the manuscript",
  grip: "testing reader-grip (爽点)",
  draft: "drafting the scene",
};

// Proper-cased model names + a class for the chip's accent colour.
const MODELNAME = {
  grok: "Grok", codex: "Codex", claude: "Claude", agy: "Gemini", gemini: "Gemini",
  deepseek: "DeepSeek", kimi: "Kimi", glm: "GLM", probe: "Probe", opus: "Opus", sonnet: "Sonnet",
};
const modelName = (m) => MODELNAME[m] || (m ? m[0].toUpperCase() + m.slice(1) : "");
const modelClass = (m) => "m-" + String(m || "").replace(/[^a-z0-9]/gi, "").toLowerCase();

function laneCard(l) {
  const g = GLYPH[l.status] || "·";
  const el = SHOW_EL[l.status] ? `${elapsedFor(l)}s` : "";
  const desc = DESC[l.id] || "";
  const chip = l.model
    ? `<span class="chip ${modelClass(l.model)}">${escapeHtml(modelName(l.model))}</span>`
    : "";
  return (
    `<div class="lane ${escapeHtml(l.status)}" data-id="${escapeHtml(l.id)}">` +
    `<span class="g">${g}</span>` +
    `<div class="meta">` +
    `<div class="top"><span class="id">${escapeHtml(l.id)}</span>${chip}</div>` +
    (desc ? `<div class="desc">${escapeHtml(desc)}</div>` : "") +
    `</div>` +
    `<span class="el">${el}</span></div>`
  );
}

// Rebuild card DOM only when the structure (ids + statuses) changes, so CSS
// animations aren't restarted every clock tick.
function renderStructure(s) {
  const state = s.state || "idle";
  $("dot").className = "dot " + state;
  $("state").textContent = state;
  $("state").className = "badge " + state;
  $("app").className = "app" + (state === "running" || state === "starting" ? " running" : "");
  $("play").textContent = s.play || "—";

  const lanes = Array.isArray(s.lanes) ? s.lanes : [];
  const total = lanes.length;
  const done = lanes.filter((l) => l.status === "done").length;
  $("lanecount").textContent = total ? `· ${done}/${total} done` : "";

  let w = total ? (done / total) * 100 : 0;
  if ((state === "running" || state === "starting") && w < 4) w = 4; // visible sliver while working
  $("barfill").style.width = w + "%";

  const sig = state + "|" + lanes.map((l) => l.id + ":" + l.status).join(",");
  if (sig !== lastSig) {
    lastSig = sig;
    $("lanes").innerHTML = total
      ? lanes.map(laneCard).join("")
      : '<div class="empty">no active run</div>';
  }

  const a = $("artifact");
  if (state === "done" && s.artifactRel) {
    a.hidden = false;
    $("artpath").textContent = s.artifactRel;
    a.removeAttribute("href"); // informational only — don't navigate the webview
  } else {
    a.hidden = true;
  }
}

const cssEsc = (x) => String(x).replace(/["\\]/g, "\\$&");

function renderClocks() {
  if (!current) return;
  (current.lanes || []).forEach((l) => {
    if (l.status !== "running") return;
    const card = document.querySelector(`.lane[data-id="${cssEsc(l.id)}"]`);
    const e = card && card.querySelector(".el");
    if (e) e.textContent = `${elapsedFor(l)}s`;
  });
}

// isSnapshot=true for the connect/reconnect replay (server `snapshot` event): render
// it and record its key so we never ping, but don't treat it as a live transition.
// Live `message` events (isSnapshot=false) are notify-eligible.
function onState(s, isSnapshot) {
  current = s;
  const now = Date.now();
  (s.lanes || []).forEach((l) => {
    if (l.status === "running") anchor[l.id] = { base: l.elapsedSeconds || 0, ts: now };
    else delete anchor[l.id];
  });
  renderStructure(s);
  renderClocks();
  if (isSnapshot) notified.add(`${s.runId}:${s.state}`); // baseline — record, don't notify
  else maybeNotify(s);
}

setInterval(renderClocks, 1000);

// Fire ONE native notification per (runId, state) transition. Baseline snapshots
// (connect/reconnect replay) are recorded by onState() before we reach here, so a
// reconnect — even one landing on a run that finished while we were away — never pings.
function maybeNotify(s) {
  const key = `${s.runId}:${s.state}`;
  if (notified.has(key)) return;
  notified.add(key);

  const play = s.play || "(ad-hoc)";
  const n = (s.lanes || []).length;
  let title, body;
  switch (s.state) {
    case "running":
      title = "🎼 conduct started";
      body = `${play}${n ? ` · ${n} lanes` : ""}`;
      break;
    case "done":
      title = "✓ conduct done";
      body = `${play} · ${n} lanes${s.artifactRel ? ` → ${s.artifactRel}` : ""}`;
      break;
    case "failed":
      title = "✗ conduct failed";
      body = `${play} · see dashboard`;
      break;
    case "timeout":
      title = "⏳ conduct timed out";
      body = `${play} · 30m limit`;
      break;
    default:
      return; // idle / starting — no banner
  }
  invoke("notify", { title, body }).catch(() => {});
}

function connect() {
  if (es) es.close();
  setConn(false);
  es = new EventSource(trim(cfg.host) + "/live/events");
  es.onopen = () => {
    setConn(true);
    $("hm").textContent = "live";
    $("hm").className = "val up";
  };
  es.onerror = () => {
    setConn(false);
    $("hm").textContent = "down";
    $("hm").className = "val down";
  };
  const parse = (e) => {
    if (!e.data) return null;
    try {
      return JSON.parse(e.data);
    } catch {
      return null;
    }
  };
  // Live transitions (default `message` event) → notify-eligible.
  es.onmessage = (e) => {
    const s = parse(e);
    if (s) onState(s, false);
  };
  // Connect/reconnect replay (named `snapshot` event) → render, never notify.
  es.addEventListener("snapshot", (e) => {
    const s = parse(e);
    if (s) onState(s, true);
  });
}

async function setExpanded(v) {
  expanded = v;
  $("panel").hidden = !v;
  $("chev").textContent = v ? "▴" : "▾";
  if (appWindow && LogicalSize) {
    try {
      await appWindow.setSize(new LogicalSize(360, v ? 588 : 96));
    } catch {}
  }
}

async function refreshTailscale() {
  try {
    const r = await invoke("tailscale_status");
    const el = $("ts");
    if (r && r.up) {
      el.textContent = "up · " + r.ip;
      el.className = "val up";
    } else {
      el.textContent = "down";
      el.className = "val down";
    }
  } catch {
    $("ts").textContent = "error";
  }
}

function wireOps() {
  // The ENTIRE header is the expand/collapse toggle (dot · APHRODITE · badge · chevron).
  // One handler — clicks on the chevron/badge bubble up here, so it toggles exactly once.
  document.querySelector("header")?.addEventListener("click", () => setExpanded(!expanded));

  $("tsup").addEventListener("click", async () => {
    const out = $("out");
    out.hidden = false;
    out.textContent = "tailscale up…";
    $("ts").textContent = "bringing up…";
    try {
      const r = await invoke("tailscale_up");
      const body = (r.stdout || "") + (r.stderr ? "\n" + r.stderr : "");
      // `tailscale up` is a no-op (exit 0, no output) when already connected — say so
      // explicitly, otherwise the button looks like it did nothing.
      out.textContent =
        r.code === 0 && !body.trim()
          ? "✓ already up — nothing to do"
          : `tailscale up [exit ${r.code}]\n${body}`;
    } catch (e) {
      out.textContent = "error: " + e;
    }
    refreshTailscale();
  });

  $("openclaw").addEventListener("click", () =>
    invoke("open_url", { url: cfg.claw }).catch(() => {})
  );

  $("doctor").addEventListener("click", async () => {
    const out = $("out");
    out.hidden = false;
    out.textContent = "running fiction-doctor…";
    try {
      const r = await invoke("run_doctor");
      out.textContent =
        (r.stdout || "") + (r.stderr ? "\n" + r.stderr : "") + `\n[exit ${r.code}]`;
    } catch (e) {
      out.textContent = "error: " + e;
    }
  });

  $("hmrestart").addEventListener("click", async () => {
    const out = $("out");
    out.hidden = false;
    out.textContent = "restarting host-mcp…";
    try {
      const r = await invoke("hostmcp_restart");
      out.textContent = `host-mcp kickstart [exit ${r.code}]\n` + (r.stderr || "");
      setTimeout(connect, 1500); // re-establish the SSE after the bounce
    } catch (e) {
      out.textContent = "error: " + e;
    }
  });

  $("cfgHost").value = cfg.host;
  $("cfgClaw").value = cfg.claw;
  $("cfgSave").addEventListener("click", () => {
    cfg.host = $("cfgHost").value.trim() || DEFAULTS.host;
    cfg.claw = $("cfgClaw").value.trim() || DEFAULTS.claw;
    localStorage.setItem("host", cfg.host);
    localStorage.setItem("claw", cfg.claw);
    connect();
  });
}

wireOps();
connect();
refreshTailscale();
setInterval(refreshTailscale, 30000);

// Distraction control: when focused, expand + show clearly; when not, collapse to
// the frosted status pill (CSS `body.unfocused`) so it recedes while you work in
// Chrome/OpenClaw. Default (and on focus) is NON-minimized — the full board.
function applyFocus(focused) {
  document.body.classList.toggle("unfocused", !focused);
  // Collapse when you leave (less distraction); expanding is MANUAL (click the
  // wordmark or chevron). Auto-expanding on focus would fight the click-to-toggle
  // (focus fires first, then the click would immediately collapse it again).
  if (!focused) setExpanded(false);
}
setExpanded(true); // default state: non-minimized
// Two focus signals — the native Tauri event AND DOM focus/blur. The native event
// can be flaky on a borderless always-on-top window, so the DOM events (which fire
// when the webview gains/loses key status) make the minimize-on-unfocus reliable.
if (appWindow && appWindow.onFocusChanged) {
  appWindow.onFocusChanged(({ payload: focused }) => applyFocus(focused));
}
window.addEventListener("focus", () => applyFocus(true));
window.addEventListener("blur", () => applyFocus(false));
// reflect the launch focus state without forcing a minimize (keeps default expanded)
document.body.classList.toggle("unfocused", !document.hasFocus());
