// fiction-host-mcp — a minimal MCP (Streamable HTTP) server that exposes the
// Mac-host Orchestration Conductor as an MCP tool. It is the trust boundary:
// the OpenClaw conductor (on arch) calls the `conduct` tool over the tailnet;
// this server runs the first-party CLIs LOCALLY on the Mac via bin/conduct,
// which assembles firewalled (SFW) context and returns only SFW results.
//
// Design notes:
//   - Hand-rolled JSON-RPC 2.0 over Streamable HTTP (MCP 2025-06-18). No deps,
//     Go 1.20-safe — so the Mac needs no extra runtime after Docker is removed.
//   - A single MCP endpoint (default /mcp) handles POST (requests/notifications)
//     and GET (a keepalive SSE stream, for client compatibility).
//   - tools/call streams MCP `notifications/progress` over SSE while bin/conduct
//     runs (tailing its CONDUCT_PROGRESS_SINK), then sends the final response.
//   - Bearer-token auth; bind the tailnet IP only (set via -addr in the plist).
package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const protocolVersion = "2025-06-18"

var (
	addr       = flag.String("addr", env("HOST_MCP_ADDR", "127.0.0.1:8765"), "listen address (bind the tailnet IP in production)")
	repoRoot   = flag.String("repo", env("HOST_MCP_REPO", "."), "fiction repo root (holds bin/conduct)")
	endpoint   = flag.String("endpoint", env("HOST_MCP_ENDPOINT", "/mcp"), "MCP endpoint path")
	token      = env("HOST_MCP_TOKEN", "")
	maxJobSecs = 1800
)

func env(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

// ---- JSON-RPC types ----

type rpcReq struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"` // absent ⇒ notification
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

type rpcResp struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Result  interface{}     `json:"result,omitempty"`
	Error   *rpcErr         `json:"error,omitempty"`
}

type rpcErr struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

func newID() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

// ---- live dashboard hub ----
// Broadcasts the conductor's progress frames to browser tabs at /live, so the
// operator can WATCH the writers'-room board tick in real time — independent of
// the MCP client (OpenClaw 2026.5.22 renders no tool progress). The frames are
// the same SFW board text the conductor writes to CONDUCT_PROGRESS_SINK.
type liveHub struct {
	mu     sync.Mutex
	latest string
	subs   map[chan string]struct{}
}

func newLiveHub() *liveHub { return &liveHub{subs: map[chan string]struct{}{}} }

func (h *liveHub) publish(frame string) {
	h.mu.Lock()
	h.latest = frame
	for ch := range h.subs {
		select {
		case ch <- frame:
		default: // slow subscriber — drop this frame for it
		}
	}
	h.mu.Unlock()
}

func (h *liveHub) subscribe() (chan string, string) {
	ch := make(chan string, 16)
	h.mu.Lock()
	h.subs[ch] = struct{}{}
	latest := h.latest
	h.mu.Unlock()
	return ch, latest
}

func (h *liveHub) unsubscribe(ch chan string) {
	h.mu.Lock()
	delete(h.subs, ch)
	close(ch)
	h.mu.Unlock()
}

var live = newLiveHub()

// ---- structured live-events feed (the Mac cockpit's data layer) ----
// A SANITIZED, structured mirror of the current conduct run. Unlike liveHub —
// whose frames carry the `title` (raw instruction + target paths, main.go pub) —
// the events feed carries ONLY SFW structured state: play name, per-lane status,
// run lifecycle, and the artifact rel path. It is NEVER sourced from live.latest;
// it is built from the CLEAN conductor board (conduct.sh progress_frame), which
// holds no instruction/targets/output. This is the safe-to-forward feed.
//
// liveHub already broadcasts strings, so the events hub is just another liveHub
// carrying marshaled-JSON strings — no second hub type needed.
var events = newLiveHub()

type lane struct {
	ID             string `json:"id"`
	Model          string `json:"model"`
	Status         string `json:"status"`
	ElapsedSeconds int    `json:"elapsedSeconds"`
}

type runState struct {
	RunID       string `json:"runId"`
	State       string `json:"state"` // idle|starting|running|done|failed|timeout
	Play        string `json:"play"`
	Lanes       []lane `json:"lanes"`
	ArtifactRel string `json:"artifactRel,omitempty"`
	UpdatedAt   string `json:"updatedAt"`
}

var (
	rsMu    sync.Mutex
	rs      = runState{State: "idle"}
	rsOwner string // runID currently allowed to publish; newest run to claim wins
)

// publishState applies mut to the global run state on behalf of runID, stamps it,
// and broadcasts the JSON to /live/events subscribers. The mutation runs under the
// lock so concurrent ticks/terminal hooks can't interleave a half-updated frame.
//
// Stale-run guard (S21 Finding 2): there is ONE global run state, so two concurrent
// DISTINCT conduct runs would otherwise corrupt each other — a slow older run could
// stamp its terminal "done" over a newer run's board. Ownership is claimed by the
// newest run (claim=true on its "starting" frame); publishes from any other runID
// are dropped while it owns the board. Single-operator deployment makes "newest
// wins" the right call — the run the operator just launched is what they watch.
func publishState(runID string, claim bool, mut func(*runState)) {
	rsMu.Lock()
	if claim || rsOwner == "" {
		rsOwner = runID
	}
	if runID != rsOwner {
		rsMu.Unlock()
		return // a newer run owns the board — drop this stale publish
	}
	mut(&rs)
	rs.UpdatedAt = time.Now().UTC().Format(time.RFC3339)
	b, _ := json.Marshal(rs)
	rsMu.Unlock()
	events.publish(string(b))
}

// parseLanes extracts per-lane state from the CLEAN conductor board. Each lane
// row (conduct.sh progress_frame) is "  <icon> <sid> <model> <status> <el> …";
// the status WORD (not the glyph) is authoritative, so we key on it. Header
// ("🎼 …"), the brief footer ("→ …", "relay: …"), and any non-lane line are
// skipped. This reads no instruction/target/output — the board has none.
func parseLanes(frame string) []lane {
	var lanes []lane
	for _, raw := range strings.Split(frame, "\n") {
		f := strings.Fields(strings.TrimSpace(raw))
		if len(f) < 4 {
			continue
		}
		switch f[3] { // status word
		case "pending", "running", "done", "failed", "timeout":
		default:
			continue
		}
		ln := lane{ID: f[1], Model: f[2], Status: f[3]}
		if len(f) >= 5 {
			ln.ElapsedSeconds = parseElapsed(f[4])
		}
		lanes = append(lanes, ln)
	}
	return lanes
}

// parseHeaderPlay reads the play name from the board header ("🎼 <headline> — <play>").
// Play names are single tokens (idea, adversarial-review, scene-draft, continuity,
// voice); the start-message header ("🎼 starting — the conductor is reading…") is
// prose with spaces, so a space-containing value is rejected as not-a-play.
func parseHeaderPlay(frame string) string {
	for _, raw := range strings.Split(frame, "\n") {
		line := strings.TrimSpace(raw)
		if strings.HasPrefix(line, "🎼") {
			if i := strings.LastIndex(line, " — "); i >= 0 {
				p := strings.TrimSpace(line[i+len(" — "):])
				if p != "" && !strings.Contains(p, " ") {
					return p
				}
			}
			return ""
		}
	}
	return ""
}

// parseElapsed turns "45s" (or "-") into an int second count; anything unparseable → 0.
func parseElapsed(s string) int {
	s = strings.TrimSuffix(s, "s")
	n := 0
	for _, c := range s {
		if c < '0' || c > '9' {
			return 0
		}
		n = n*10 + int(c-'0')
	}
	return n
}

func main() {
	flag.Parse()
	abs, err := filepath.Abs(*repoRoot)
	if err != nil {
		log.Fatalf("repo path: %v", err)
	}
	*repoRoot = abs
	if _, err := os.Stat(filepath.Join(*repoRoot, "bin", "conduct")); err != nil {
		log.Fatalf("bin/conduct not found under repo %s: %v", *repoRoot, err)
	}
	if token == "" {
		log.Printf("WARNING: HOST_MCP_TOKEN is empty — server is UNAUTHENTICATED")
	}
	http.HandleFunc(*endpoint, handleMCP)
	http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, "ok\n") })
	http.HandleFunc("/live", handleLivePage)
	http.HandleFunc("/live/stream", handleLiveStream)
	http.HandleFunc("/live/events", handleLiveEvents)
	http.HandleFunc("/live/events/latest", handleLiveEventsLatest)
	log.Printf("fiction-host-mcp listening on %s%s (repo=%s, protocol=%s)", *addr, *endpoint, *repoRoot, protocolVersion)
	srv := &http.Server{Addr: *addr, Handler: http.DefaultServeMux}
	log.Fatal(srv.ListenAndServe())
}

func authOK(r *http.Request) bool {
	if token == "" {
		return true
	}
	h := r.Header.Get("Authorization")
	return h == "Bearer "+token
}

func handleMCP(w http.ResponseWriter, r *http.Request) {
	if !authOK(r) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	switch r.Method {
	case http.MethodGet:
		// Optional server→client SSE stream. We send only keepalive comments.
		handleGetSSE(w, r)
	case http.MethodDelete:
		// session teardown — we are effectively stateless.
		w.WriteHeader(http.StatusNoContent)
	case http.MethodPost:
		handlePost(w, r)
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func handleGetSSE(w http.ResponseWriter, r *http.Request) {
	fl, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming unsupported", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.WriteHeader(http.StatusOK)
	io.WriteString(w, ": connected\n\n")
	fl.Flush()
	tick := time.NewTicker(15 * time.Second)
	defer tick.Stop()
	for {
		select {
		case <-r.Context().Done():
			return
		case <-tick.C:
			io.WriteString(w, ": keepalive\n\n")
			fl.Flush()
		}
	}
}

// livePageHTML is a tiny self-contained dashboard: it opens an EventSource to
// /live/stream and renders each frame (the conductor's board text) in a <pre>.
// No auth — the server binds the tailnet IP only and frames are SFW board text.
const livePageHTML = `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>fiction · writers' room</title>
<style>
  :root{color-scheme:dark}
  body{margin:0;background:#0d1117;color:#c9d1d9;font:14px/1.5 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
  header{padding:10px 16px;border-bottom:1px solid #21262d;display:flex;align-items:center;gap:10px;position:sticky;top:0;background:#0d1117}
  .dot{width:9px;height:9px;border-radius:50%;background:#f85149;transition:background .3s}
  .dot.on{background:#3fb950}
  h1{font-size:13px;font-weight:600;margin:0;color:#8b949e;letter-spacing:.04em;text-transform:uppercase}
  #status{margin-left:auto;font-size:12px;color:#8b949e}
  pre{margin:0;padding:16px;white-space:pre-wrap;word-break:break-word;font-size:14px;tab-size:2}
  .idle{color:#6e7681}
  footer{padding:8px 16px;color:#6e7681;font-size:11px;border-top:1px solid #21262d}
</style></head><body>
<header><span class="dot" id="dot"></span><h1>🎼 Writers' Room — live</h1><span id="status">connecting…</span></header>
<pre id="board" class="idle">waiting for a conduct run…</pre>
<footer>host-mcp /live · streams the conductor's per-lane board · updates as the stack runs</footer>
<script>
  const board=document.getElementById('board'),dot=document.getElementById('dot'),status=document.getElementById('status');
  let es;
  function connect(){
    es=new EventSource('/live/stream');
    es.onopen=()=>{dot.classList.add('on');status.textContent='live';};
    es.onerror=()=>{dot.classList.remove('on');status.textContent='reconnecting…';};
    es.onmessage=(e)=>{
      if(!e.data){return;}
      const txt=JSON.parse(e.data);
      if(txt===''){board.textContent='waiting for a conduct run…';board.classList.add('idle');return;}
      board.textContent=txt;board.classList.remove('idle');
    };
  }
  connect();
</script></body></html>`

func handleLivePage(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	io.WriteString(w, livePageHTML)
}

func handleLiveStream(w http.ResponseWriter, r *http.Request) {
	fl, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming unsupported", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.WriteHeader(http.StatusOK)

	ch, latest := live.subscribe()
	defer live.unsubscribe(ch)
	send := func(frame string) {
		b, _ := json.Marshal(frame)
		fmt.Fprintf(w, "data: %s\n\n", b)
		fl.Flush()
	}
	send(latest) // current state on connect
	tick := time.NewTicker(15 * time.Second)
	defer tick.Stop()
	for {
		select {
		case <-r.Context().Done():
			return
		case frame, ok := <-ch:
			if !ok {
				return
			}
			send(frame)
		case <-tick.C:
			io.WriteString(w, ": keepalive\n\n")
			fl.Flush()
		}
	}
}

// handleLiveEvents streams the SANITIZED structured run state as SSE JSON — the
// Mac cockpit's feed. Mirrors handleLiveStream's keepalive/replay shape, but the
// payload is already-marshaled JSON sent verbatim (not double-encoded), so the
// client reads e.data as the event object directly.
func handleLiveEvents(w http.ResponseWriter, r *http.Request) {
	fl, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming unsupported", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("Access-Control-Allow-Origin", "*") // cockpit webview is cross-origin; feed is SFW + tailnet-bound
	w.WriteHeader(http.StatusOK)

	ch, latest := events.subscribe()
	defer events.unsubscribe(ch)
	send := func(js string) {
		if js == "" {
			return
		}
		fmt.Fprintf(w, "data: %s\n\n", js)
		fl.Flush()
	}
	if latest == "" { // no run broadcast yet — replay the idle snapshot on connect
		rsMu.Lock()
		b, _ := json.Marshal(rs)
		rsMu.Unlock()
		latest = string(b)
	}
	// S24 #4-I1: the connect/reconnect replay goes out as a NAMED `snapshot` event so
	// the cockpit renders it but does NOT fire a notification. Native EventSource
	// auto-reconnects (sleep/wake, host-mcp bounce) and re-receives this replay; if a
	// run had finished while disconnected, sending it as a default `message` made the
	// client ping a stale "done"/"failed" it never watched. Live transitions below
	// stay default `message` events (notify-eligible).
	if latest != "" {
		fmt.Fprintf(w, "event: snapshot\ndata: %s\n\n", latest)
		fl.Flush()
	}
	tick := time.NewTicker(15 * time.Second)
	defer tick.Stop()
	for {
		select {
		case <-r.Context().Done():
			return
		case js, ok := <-ch:
			if !ok {
				return
			}
			send(js)
		case <-tick.C:
			io.WriteString(w, ": keepalive\n\n")
			fl.Flush()
		}
	}
}

// handleLiveEventsLatest returns the current run state as a one-shot JSON snapshot
// (for late joiners / health polling that don't want an SSE connection).
func handleLiveEventsLatest(w http.ResponseWriter, r *http.Request) {
	rsMu.Lock()
	b, _ := json.Marshal(rs)
	rsMu.Unlock()
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Access-Control-Allow-Origin", "*")
	_, _ = w.Write(b)
}

func handlePost(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
	if err != nil {
		http.Error(w, "read error", http.StatusBadRequest)
		return
	}
	var req rpcReq
	if err := json.Unmarshal(body, &req); err != nil {
		http.Error(w, "parse error", http.StatusBadRequest)
		return
	}
	// Notifications & responses (no id, or a notifications/* method) → 202 Accepted.
	if len(req.ID) == 0 || strings.HasPrefix(req.Method, "notifications/") {
		w.WriteHeader(http.StatusAccepted)
		return
	}

	log.Printf("POST method=%s id=%s ua=%q", req.Method, string(req.ID), r.Header.Get("User-Agent"))
	switch req.Method {
	case "initialize":
		w.Header().Set("Mcp-Session-Id", newID())
		writeJSON(w, &rpcResp{JSONRPC: "2.0", ID: req.ID, Result: map[string]interface{}{
			"protocolVersion": protocolVersion,
			"capabilities":    map[string]interface{}{"tools": map[string]interface{}{}},
			"serverInfo":      map[string]interface{}{"name": "fiction-host-mcp", "version": "0.1.0"},
		}})
	case "ping":
		writeJSON(w, &rpcResp{JSONRPC: "2.0", ID: req.ID, Result: map[string]interface{}{}})
	case "tools/list":
		writeJSON(w, &rpcResp{JSONRPC: "2.0", ID: req.ID, Result: map[string]interface{}{"tools": toolDefs()}})
	case "tools/call":
		handleToolsCall(w, r, &req)
	default:
		writeJSON(w, &rpcResp{JSONRPC: "2.0", ID: req.ID, Error: &rpcErr{Code: -32601, Message: "method not found: " + req.Method}})
	}
}

func writeJSON(w http.ResponseWriter, resp *rpcResp) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(w).Encode(resp)
}

// ---- tools ----

func toolDefs() []map[string]interface{} {
	return []map[string]interface{}{
		{
			"name": "conduct",
			"description": "Route a request to the host Orchestration Conductor (Sonnet plans, " +
				"specialist lanes collaborate, Opus synthesizes) and return the composed draft. " +
				"The host enforces the NSFW firewall — only SFW results return.",
			"inputSchema": map[string]interface{}{
				"type": "object",
				// No hard `required`: a caller may pass structured args (instruction/
				// targets/play) OR a single `raw` invocation string. runConduct enforces
				// "instruction or play or raw" at runtime.
				"properties": map[string]interface{}{
					"instruction": map[string]interface{}{"type": "string", "description": "The request: a craft question, messy draft note, or idea."},
					"targets": map[string]interface{}{"type": "array", "items": map[string]interface{}{"type": "string"},
						"description": "Repo-relative paths (e.g. manuscript/ch01/s01.md). Path STRINGS only — never file contents. The host resolves + firewalls them."},
					"play": map[string]interface{}{"type": "string", "enum": []string{"idea", "adversarial-review", "scene-draft", "continuity", "voice"},
						"description": "Optional: force a play template (skips the planner LLM)."},
					"raw": map[string]interface{}{"type": "string",
						"description": "Alternative to instruction/targets: a single raw invocation string, e.g. `\"Continuity pass\" manuscript/ch01/s01.md` or `--play continuity \"…\" target`. The host parses it (quoted instruction + space-separated targets). For OpenClaw `command-arg-mode: raw` slash dispatch."},
				},
			},
		},
		{
			"name":        "slowtick",
			"description": "DEBUG/GATE-1 probe: streams MCP progress notifications with a message every few seconds, then returns. Used to verify the panel renders live progress.",
			"inputSchema": map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"seconds": map[string]interface{}{"type": "integer", "description": "total run time (default 30)"},
					"label":   map[string]interface{}{"type": "string", "description": "label prefix for each frame"},
				},
			},
		},
		{
			"name": "image",
			"description": "Generate an image from a text prompt on the Mac (keys never leave the host). " +
				"provider=gpt (gpt-image, moderated/SFW) or grok (xAI grok-2-image, NSFW-capable). " +
				"Returns base64 image content. The caller relays it to the chat front-end.",
			"inputSchema": map[string]interface{}{
				"type":     "object",
				"required": []string{"prompt"},
				"properties": map[string]interface{}{
					"prompt":   map[string]interface{}{"type": "string", "description": "Text description of the image to generate."},
					"provider": map[string]interface{}{"type": "string", "enum": []string{"gpt", "grok"}, "description": "gpt (default, moderated) or grok (NSFW-capable)."},
					"n":        map[string]interface{}{"type": "integer", "description": "Number of images, 1-4 (default 1)."},
					"size":     map[string]interface{}{"type": "string", "description": "gpt only: e.g. 1024x1024 (default), 1536x1024, 1024x1536, auto. Ignored by grok."},
					"model":    map[string]interface{}{"type": "string", "description": "Override the provider's default model id."},
				},
			},
		},
	}
}

type callParams struct {
	Name      string          `json:"name"`
	Arguments json.RawMessage `json:"arguments"`
	Meta      struct {
		ProgressToken json.RawMessage `json:"progressToken"`
	} `json:"_meta"`
}

// sseSink serializes writes to the SSE response from the progress goroutine and
// the final-response path.
type sseSink struct {
	mu  sync.Mutex
	w   http.ResponseWriter
	fl  http.Flusher
	eid int
}

func (s *sseSink) send(v interface{}) {
	s.mu.Lock()
	defer s.mu.Unlock()
	b, _ := json.Marshal(v)
	s.eid++
	fmt.Fprintf(s.w, "id: %d\ndata: %s\n\n", s.eid, b)
	s.fl.Flush()
}

// comment writes an SSE comment line (ignored by parsers) purely to keep the
// connection warm. Critical: when the client sends no progressToken, the whole
// tool call would otherwise stream ZERO bytes for the 2-6 min conductor run —
// idle-connection timeouts then drop it and the client retries, spawning a
// duplicate run (the subscription-bleed bug). A periodic keepalive prevents that.
func (s *sseSink) comment() {
	s.mu.Lock()
	defer s.mu.Unlock()
	io.WriteString(s.w, ": keepalive\n\n")
	s.fl.Flush()
}

func handleToolsCall(w http.ResponseWriter, r *http.Request, req *rpcReq) {
	var cp callParams
	if err := json.Unmarshal(req.Params, &cp); err != nil {
		writeJSON(w, &rpcResp{JSONRPC: "2.0", ID: req.ID, Error: &rpcErr{Code: -32602, Message: "bad params"}})
		return
	}
	fl, ok := w.(http.Flusher)
	if !ok {
		writeJSON(w, &rpcResp{JSONRPC: "2.0", ID: req.ID, Error: &rpcErr{Code: -32603, Message: "streaming unsupported"}})
		return
	}
	// Open an SSE stream for the whole tool call (progress notifications + final response).
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.WriteHeader(http.StatusOK)
	sink := &sseSink{w: w, fl: fl}

	// Keepalive: stream SSE comments throughout the call so a client that requested
	// no progress (OpenClaw sends no progressToken) doesn't see an idle stream,
	// time out, and retry — which would spawn a duplicate conductor run (bleed).
	kaStop := make(chan struct{})
	kaDone := make(chan struct{})
	go func() {
		defer close(kaDone)
		t := time.NewTicker(15 * time.Second)
		defer t.Stop()
		for {
			select {
			case <-kaStop:
				return
			case <-t.C:
				sink.comment()
			}
		}
	}()

	progress := func(n float64, msg string) {
		if len(cp.Meta.ProgressToken) == 0 {
			return // client didn't ask for progress
		}
		params := map[string]interface{}{"progressToken": rawOrNull(cp.Meta.ProgressToken), "progress": n, "message": msg}
		sink.send(map[string]interface{}{"jsonrpc": "2.0", "method": "notifications/progress", "params": params})
	}

	ctx, cancel := context.WithTimeout(r.Context(), time.Duration(maxJobSecs)*time.Second)
	defer cancel()

	start := time.Now()
	log.Printf("tools/call %s START progressToken=%s", cp.Name, string(cp.Meta.ProgressToken))
	var result interface{}
	var rerr *rpcErr
	switch cp.Name {
	case "conduct":
		result, rerr = runConduct(ctx, cp.Arguments, progress)
	case "slowtick":
		result, rerr = runSlowtick(ctx, cp.Arguments, progress)
	case "image":
		result, rerr = runImage(ctx, cp.Arguments, progress)
	default:
		rerr = &rpcErr{Code: -32602, Message: "unknown tool: " + cp.Name}
	}
	close(kaStop) // stop keepalive before the final frame
	<-kaDone      // and wait for it to actually exit, so no keepalive comment can be
	// written AFTER the final JSON-RPC frame (corrupt SSE / write-after-return).
	log.Printf("tools/call %s END dur=%s ctxErr=%v isErr=%v", cp.Name, time.Since(start).Round(time.Second), ctx.Err(), rerr != nil)
	resp := &rpcResp{JSONRPC: "2.0", ID: req.ID}
	if rerr != nil {
		resp.Error = rerr
	} else {
		resp.Result = result
	}
	sink.send(resp)
}

func rawOrNull(r json.RawMessage) interface{} {
	if len(r) == 0 {
		return nil
	}
	var v interface{}
	if json.Unmarshal(r, &v) == nil {
		return v
	}
	return nil
}

func textResult(s string, isErr bool) map[string]interface{} {
	return map[string]interface{}{
		"content": []map[string]interface{}{{"type": "text", "text": s}},
		"isError": isErr,
	}
}

// imageResult returns one or more MCP image-content blocks (base64 + mimeType),
// the standard MCP shape for binary tool output. The /image plugin reads
// content[].data/mimeType and relays each as a base64:// image to the chat front-end.
func imageResult(imgs []genImage) map[string]interface{} {
	content := make([]map[string]interface{}, 0, len(imgs))
	for _, im := range imgs {
		block := map[string]interface{}{"type": "image", "mimeType": im.Mime, "data": im.B64}
		if im.URL != "" {
			// Hosted URL (xAI grok): the relay prefers this — NapCat sends URL images
			// fine but times out on inline base64, and the panel renders remote URLs.
			block["url"] = im.URL
		}
		content = append(content, block)
	}
	return map[string]interface{}{"content": content, "isError": false}
}

// ---- image ----

type genImage struct {
	B64  string
	URL  string // hosted image URL when the provider returns one (xAI grok)
	Mime string
}

// runImage generates image(s) on the Mac and returns them as base64 MCP content.
// Keys (OPENAI_API_KEY / XAI_API_KEY) are read from the host process env (sourced
// from .env by bin/host-mcp-run) and NEVER leave the Mac — the trust boundary holds.
//
// FIREWALL: the prompt is passed to the provider VERBATIM and is never logged
// (only provider + count + length are logged), because the grok provider is the
// NSFW-capable generator and an explicit prompt must not land in the Mac logs.
// Claude/Codex/Gemini never author prompts for this tool; the prompt originates
// from the human via the chat front-end. gpt is moderated and rejects explicit.
func runImage(ctx context.Context, raw json.RawMessage, progress func(float64, string)) (interface{}, *rpcErr) {
	var a struct {
		Prompt   string `json:"prompt"`
		Provider string `json:"provider"`
		N        int    `json:"n"`
		Size     string `json:"size"`
		Model    string `json:"model"`
	}
	_ = json.Unmarshal(raw, &a)
	prompt := strings.TrimSpace(a.Prompt)
	if prompt == "" {
		return textResult("image: empty prompt.", true), nil
	}
	provider := strings.ToLower(strings.TrimSpace(a.Provider))
	if provider == "" || provider == "openai" {
		provider = "gpt"
	}
	n := a.N
	if n < 1 {
		n = 1
	}
	if n > 4 {
		n = 4
	}
	log.Printf("image START provider=%s n=%d promptLen=%d", provider, n, len(prompt))
	progress(0.1, "🎨 "+provider+" is generating…")

	var imgs []genImage
	var err error
	switch provider {
	case "grok":
		imgs, err = genXAI(ctx, prompt, n, a.Model)
	case "gpt":
		imgs, err = genOpenAI(ctx, prompt, n, a.Size, a.Model)
	default:
		return textResult("image: unknown provider "+provider+" (use gpt or grok).", true), nil
	}
	if err != nil {
		log.Printf("image END provider=%s ERR=%v", provider, err)
		return textResult("image generation failed: "+err.Error(), true), nil
	}
	if len(imgs) == 0 {
		return textResult("image: provider returned no images.", true), nil
	}
	log.Printf("image END provider=%s ok=%d", provider, len(imgs))
	progress(1.0, "🎨 image ready")
	return imageResult(imgs), nil
}

// imageHTTP is the shared client for provider image APIs (generation can take 10-60s).
var imageHTTP = &http.Client{Timeout: 120 * time.Second}

// callImageGen POSTs an OpenAI-compatible /v1/images/generations request and
// decodes data[].b64_json. Both OpenAI (gpt-image) and xAI (grok-2-image) speak
// this shape. mime labels the returned bytes for the front-end.
func callImageGen(ctx context.Context, baseURL, key, mime string, body map[string]interface{}) ([]genImage, error) {
	buf, _ := json.Marshal(body)
	req, err := http.NewRequestWithContext(ctx, "POST", baseURL+"/v1/images/generations", bytes.NewReader(buf))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+key)
	res, err := imageHTTP.Do(req)
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	rb, _ := io.ReadAll(io.LimitReader(res.Body, 64<<20))
	if res.StatusCode != 200 {
		msg := strings.TrimSpace(string(rb))
		if len(msg) > 300 {
			msg = msg[:300]
		}
		return nil, fmt.Errorf("HTTP %d: %s", res.StatusCode, msg)
	}
	var parsed struct {
		Data []struct {
			B64 string `json:"b64_json"`
			URL string `json:"url"`
		} `json:"data"`
	}
	if e := json.Unmarshal(rb, &parsed); e != nil {
		return nil, fmt.Errorf("decode response: %v", e)
	}
	out := make([]genImage, 0, len(parsed.Data))
	for _, d := range parsed.Data {
		if d.B64 != "" || d.URL != "" {
			out = append(out, genImage{B64: d.B64, URL: d.URL, Mime: mime})
		}
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("no image data (b64 or url) in response")
	}
	return out, nil
}

// genOpenAI → gpt-image via the OpenAI Images API. gpt-image-1 always returns
// b64_json and rejects response_format, so it's omitted. size/quality are optional.
func genOpenAI(ctx context.Context, prompt string, n int, size, model string) ([]genImage, error) {
	key := os.Getenv("OPENAI_API_KEY")
	if key == "" {
		return nil, fmt.Errorf("OPENAI_API_KEY not set on the host (add it to .env)")
	}
	if model == "" {
		model = env("OPENAI_IMAGE_MODEL", "gpt-image-1")
	}
	body := map[string]interface{}{"model": model, "prompt": prompt, "n": n}
	if strings.TrimSpace(size) != "" {
		body["size"] = size
	}
	base := env("OPENAI_BASE_URL", "https://api.openai.com")
	return callImageGen(ctx, strings.TrimRight(base, "/"), key, "image/png", body)
}

// genXAI → grok-2-image via the xAI Images API (OpenAI-SDK compatible). xAI accepts
// only prompt/n/response_format (no size/quality) and returns jpg.
func genXAI(ctx context.Context, prompt string, n int, model string) ([]genImage, error) {
	key := os.Getenv("XAI_API_KEY")
	if key == "" {
		return nil, fmt.Errorf("XAI_API_KEY not set on the host (add it to .env)")
	}
	if model == "" {
		// grok-imagine-image is the current xAI image model (grok-2-image retired);
		// grok-imagine-image-quality is the pricier high-quality tier. Override via XAI_IMAGE_MODEL.
		model = env("XAI_IMAGE_MODEL", "grok-imagine-image")
	}
	// Request a hosted URL, not b64_json: NapCat (the QQ front-end) times out on inline
	// base64 images but sends URL images fine, and the OpenClaw panel renders remote URLs.
	body := map[string]interface{}{"model": model, "prompt": prompt, "n": n, "response_format": "url"}
	base := env("XAI_BASE_URL", "https://api.x.ai")
	return callImageGen(ctx, strings.TrimRight(base, "/"), key, "image/jpeg", body)
}

// ---- conduct ----

type conductArgs struct {
	Instruction string   `json:"instruction"`
	Targets     []string `json:"targets"`
	Play        string   `json:"play"`
	Raw         string   `json:"raw"`
}

// parseRawInvocation turns a single raw "/conduct" argument string into structured
// args, matching the skill's documented usage so OpenClaw `command-arg-mode: raw`
// slash dispatch maps 1:1 onto the tool (parsing stays HOST-side, behind the
// firewall, not in the container):
//
//	"<quoted instruction>" [target ...]      → instruction + targets
//	<unquoted instruction>                    → instruction, no targets
//
// An optional leading `--play <name>` selects a play template. Targets are only
// taken when the instruction is quoted (otherwise an unquoted trailing word is
// ambiguous — treat the whole string as the instruction).
func parseRawInvocation(raw string) conductArgs {
	var a conductArgs
	s := strings.TrimSpace(raw)
	if strings.HasPrefix(s, "--play ") {
		rest := strings.TrimSpace(strings.TrimPrefix(s, "--play "))
		parts := strings.SplitN(rest, " ", 2)
		a.Play = parts[0]
		if len(parts) == 2 {
			s = strings.TrimSpace(parts[1])
		} else {
			s = ""
		}
	}
	if s == "" {
		return a
	}
	if q := s[0]; q == '"' || q == '\'' {
		if end := strings.IndexByte(s[1:], q); end >= 0 {
			a.Instruction = s[1 : 1+end]
			a.Targets = strings.Fields(s[1+end+1:])
			return a
		}
	}
	a.Instruction = s
	return a
}

// inflightCall lets duplicate identical requests share ONE conductor run.
type inflightCall struct {
	done   chan struct{}
	result interface{}
	rerr   *rpcErr
}

var (
	sfMu sync.Mutex
	sfm  = map[string]*inflightCall{}
)

// runConduct de-dupes identical in-flight requests (single-flight), then runs
// doConduct. Without this, a client that retries (e.g. on a perceived stall)
// spawns a fresh multi-lane job each time — the subscription-bleed bug.
func runConduct(ctx context.Context, raw json.RawMessage, progress func(float64, string)) (res interface{}, rerr *rpcErr) {
	var a conductArgs
	if err := json.Unmarshal(raw, &a); err != nil {
		return nil, &rpcErr{Code: -32602, Message: "bad arguments"}
	}
	// Raw-dispatch path (OpenClaw `command-arg-mode: raw`): parse the single raw
	// string into structured args HOST-side, only when structured fields weren't
	// supplied. Keeps the firewall/parse boundary on the host, not the container.
	usedRaw := strings.TrimSpace(a.Raw) != "" && strings.TrimSpace(a.Instruction) == "" && len(a.Targets) == 0
	if usedRaw {
		p := parseRawInvocation(a.Raw)
		a.Instruction = p.Instruction
		a.Targets = p.Targets
		if a.Play == "" {
			a.Play = p.Play
		}
	}
	// Record the DISPATCH SHAPE only (never the instruction/target text — this stays
	// content-free, like the sanitized /live/events feed). This is the host-side
	// distinguisher for /conduct: OpenClaw's native plugin command dispatches as
	// `dispatch=raw`; an in-container model improvise calls the MCP tool with
	// structured fields (`dispatch=structured`). Lets a panel run be verified from
	// the Mac host log alone, since the arch gateway log isn't reachable from here.
	dispatch := "structured"
	if usedRaw {
		dispatch = "raw"
	}
	log.Printf("conduct dispatch=%s play=%q targets=%d", dispatch, a.Play, len(a.Targets))
	if a.Play == "" && strings.TrimSpace(a.Instruction) == "" {
		return nil, &rpcErr{Code: -32602, Message: "instruction (or play or raw) is required"}
	}

	key := a.Play + "\x00" + a.Instruction + "\x00" + strings.Join(a.Targets, "\x01")
	sfMu.Lock()
	if c, ok := sfm[key]; ok {
		sfMu.Unlock()
		log.Printf("conduct DEDUPE — attaching to in-flight run (key matched)")
		progress(1, "🎼 an identical request is already running — attaching to it instead of starting a duplicate (saves quota)…")
		select {
		case <-c.done:
			return c.result, c.rerr
		case <-ctx.Done():
			return textResult("cancelled while waiting for an identical in-flight run", true), nil
		}
	}
	// Serialize DISTINCT runs (S24 #3): one conductor at a time. The dedupe check
	// above already returned for an identical request (attach), so any remaining sfm
	// entry is a different run still in flight. A second concurrent run would (a)
	// steal the single global board from the run the operator is watching and (b)
	// interleave on the unguarded /live text feed. Single operator → reject with a
	// friendly "busy" instead. Nothing is published, so the in-flight run keeps the
	// board. (publishState's newest-wins guard stays as a backstop.)
	if len(sfm) > 0 {
		sfMu.Unlock()
		log.Printf("conduct BUSY — a different run is in flight; rejecting new request")
		return textResult("🎼 a conductor run is already in flight — let it finish (watch the Island), then retry. Only one run at a time.", true), nil
	}
	c := &inflightCall{done: make(chan struct{})}
	sfm[key] = c
	sfMu.Unlock()

	// Cleanup is deferred so a panic in doConduct can't leave the key in sfm with
	// c.done never closed — which would deadlock every future identical request on
	// <-c.done. recover() turns a panic into a normal error result for all waiters.
	defer func() {
		if r := recover(); r != nil {
			rerr = &rpcErr{Code: -32603, Message: fmt.Sprintf("conduct panicked: %v", r)}
			res = nil
		}
		c.result, c.rerr = res, rerr
		sfMu.Lock()
		delete(sfm, key)
		sfMu.Unlock()
		close(c.done)
	}()

	res, rerr = doConduct(ctx, a, progress)
	return res, rerr
}

func doConduct(ctx context.Context, a conductArgs, progress func(float64, string)) (interface{}, *rpcErr) {
	sink, err := os.CreateTemp("", "conduct-progress-*.txt")
	if err != nil {
		return nil, &rpcErr{Code: -32603, Message: "sink: " + err.Error()}
	}
	sinkPath := sink.Name()
	sink.Close()
	defer os.Remove(sinkPath)

	// Compose a header for the /live dashboard so a watcher sees WHAT is running.
	title := "🎼 conduct"
	if a.Play != "" {
		title += " --play " + a.Play
	}
	if s := strings.TrimSpace(a.Instruction); s != "" {
		if r := []rune(s); len(r) > 140 {
			s = string(r[:140]) + "…"
		}
		title += ": " + s
	}
	if len(a.Targets) > 0 {
		title += "\n   targets: " + strings.Join(a.Targets, ", ")
	}
	pub := func(frame string) { live.publish(title + "\n\n" + frame) }

	// Structured-events run id (SFW). Used by the cockpit to dedupe notifications.
	runID := newID()
	publishState(runID, true, func(s *runState) {
		*s = runState{RunID: runID, State: "starting", Play: a.Play}
	})

	startMsg := "🎼 starting — the conductor is reading your request and planning (Sonnet)…"
	_ = os.WriteFile(sinkPath, []byte(startMsg), 0o644)
	progress(1, startMsg)
	pub(startMsg)

	args := []string{}
	if a.Play != "" {
		args = append(args, "--play", a.Play)
		// S24 #5: a custom instruction combined with a forced --play used to be
		// silently dropped (only --play + targets were forwarded), while the /live
		// header still showed it — so it LOOKED honored. Forward it as --note so the
		// play template can steer its lanes toward the operator's focus.
		if s := strings.TrimSpace(a.Instruction); s != "" {
			args = append(args, "--note", s)
		}
	} else {
		args = append(args, a.Instruction)
	}
	args = append(args, a.Targets...)

	cmd := exec.CommandContext(ctx, filepath.Join(*repoRoot, "bin", "conduct"), args...)
	cmd.Dir = *repoRoot
	cmd.Env = append(os.Environ(), "CONDUCT_PROGRESS_SINK="+sinkPath)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	// Tail the progress sink → MCP progress notifications until the process exits.
	done := make(chan struct{})
	tailDone := make(chan struct{})
	go func() {
		defer close(tailDone)
		var last string
		var n float64 = 1
		t := time.NewTicker(1 * time.Second)
		defer t.Stop()
		for {
			select {
			case <-done:
				return
			case <-t.C:
				b, e := os.ReadFile(sinkPath)
				if e != nil {
					continue
				}
				frame := strings.TrimRight(string(b), " \n\t")
				if frame != "" && frame != last {
					last = frame
					n++
					progress(n, frame)
					pub(frame)
					publishState(runID, false, func(s *runState) {
						s.RunID = runID
						s.State = "running"
						if p := parseHeaderPlay(frame); p != "" {
							s.Play = p
						}
						s.Lanes = parseLanes(frame)
					})
				}
			}
		}
	}()

	runErr := cmd.Run()
	close(done)
	<-tailDone // wait for the tail goroutine to fully exit so no late "running" frame
	// can publish AFTER the terminal finishState below (which would re-strand the board).

	// Final frame (whatever the sink last held).
	finalFrame := ""
	if b, e := os.ReadFile(sinkPath); e == nil {
		finalFrame = strings.TrimRight(string(b), " \n\t")
	}
	if finalFrame != "" {
		pub(finalFrame) // leave the final board on the dashboard until the next run
	}

	// Terminal structured-events publish (SFW): lanes from the clean final board,
	// plus the run's outcome. rel is set only on success.
	finishState := func(state, rel string) {
		publishState(runID, false, func(s *runState) {
			s.RunID = runID
			s.State = state
			s.ArtifactRel = rel
			if finalFrame != "" {
				if p := parseHeaderPlay(finalFrame); p != "" {
					s.Play = p
				}
				s.Lanes = parseLanes(finalFrame)
			}
			// On a terminal failure the conductor was usually killed before it could
			// update the board, so lanes can still read "running"/"pending" — which
			// leaves the cockpit showing a spinning lane under a "failed" header.
			// Flip any non-terminal lane to the run's failure state so the board is
			// internally consistent (the operator sees what actually stopped).
			if state == "failed" || state == "timeout" {
				for i := range s.Lanes {
					switch s.Lanes[i].Status {
					case "running", "pending":
						s.Lanes[i].Status = state
					}
				}
			}
		})
	}

	if runErr != nil {
		state := "failed"
		if ctx.Err() == context.DeadlineExceeded {
			state = "timeout"
		}
		finishState(state, "")
		msg := stderr.String()
		if finalFrame != "" {
			msg = finalFrame + "\n\n" + msg
		}
		if msg == "" {
			msg = "conductor failed: " + runErr.Error()
		}
		return textResult(msg, true), nil
	}

	// bin/conduct prints the artifact absolute path as its final stdout line.
	art := lastLine(stdout.String())
	if art == "" {
		finishState("failed", "")
		return textResult("conductor produced no artifact.\n\n"+finalFrame+"\n\n"+stderr.String(), true), nil
	}
	bodyBytes, e := os.ReadFile(art)
	if e != nil {
		// Conductor succeeded but its artifact is unreadable: still a terminal
		// FAILURE for the cockpit — otherwise /live/events stays stuck "running"
		// forever and the operator never gets a failure ping (adversarial finding).
		finishState("failed", "")
		return textResult(fmt.Sprintf("conductor reported artifact %q but it could not be read: %v", art, e), true), nil
	}
	rel := strings.TrimPrefix(art, *repoRoot+"/")
	finishState("done", rel)
	var out strings.Builder
	fmt.Fprintf(&out, "# Conductor artifact: %s\n\n", rel)
	if finalFrame != "" {
		out.WriteString(finalFrame)
		out.WriteString("\n\n")
	}
	out.Write(bodyBytes)
	return textResult(out.String(), false), nil
}

func lastLine(s string) string {
	sc := bufio.NewScanner(strings.NewReader(s))
	sc.Buffer(make([]byte, 1<<20), 1<<20)
	last := ""
	for sc.Scan() {
		if t := strings.TrimSpace(sc.Text()); t != "" {
			last = t
		}
	}
	return last
}

// ---- slowtick (GATE-1 probe) ----

func runSlowtick(ctx context.Context, raw json.RawMessage, progress func(float64, string)) (interface{}, *rpcErr) {
	var a struct {
		Seconds int    `json:"seconds"`
		Label   string `json:"label"`
	}
	_ = json.Unmarshal(raw, &a)
	if a.Seconds <= 0 {
		a.Seconds = 30
	}
	if a.Label == "" {
		a.Label = "lane grok"
	}
	steps := a.Seconds / 3
	if steps < 1 {
		steps = 1
	}
	// Drive the structured events feed too, so the Mac cockpit can be exercised
	// end-to-end without spending LLM quota on a real conduct run.
	runID := newID()
	publishState(runID, true, func(s *runState) {
		*s = runState{RunID: runID, State: "starting", Play: "slowtick"}
	})
	for i := 1; i <= steps; i++ {
		select {
		case <-ctx.Done():
			publishState(runID, false, func(s *runState) { s.RunID = runID; s.State = "failed" })
			return textResult("slowtick cancelled", true), nil
		case <-time.After(3 * time.Second):
		}
		frame := fmt.Sprintf("🎼 tick %d/%d — %s ⏳ running %ds (slow ~2-3m)", i, steps, a.Label, i*3)
		progress(float64(i), frame)
		live.publish("🎼 slowtick (dashboard probe)\n\n" + frame)
		publishState(runID, false, func(s *runState) {
			s.RunID = runID
			s.State = "running"
			s.Lanes = []lane{{ID: a.Label, Model: "probe", Status: "running", ElapsedSeconds: i * 3}}
		})
	}
	live.publish("🎼 slowtick (dashboard probe)\n\n✓ done — " + fmt.Sprintf("%d frames over ~%ds", steps, a.Seconds))
	publishState(runID, false, func(s *runState) {
		s.RunID = runID
		s.State = "done"
		s.Lanes = []lane{{ID: a.Label, Model: "probe", Status: "done", ElapsedSeconds: steps * 3}}
	})
	return textResult(fmt.Sprintf("slowtick done: %d frames over ~%ds", steps, a.Seconds), false), nil
}
