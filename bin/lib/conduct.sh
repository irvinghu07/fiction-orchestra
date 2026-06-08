#!/usr/bin/env bash
# conduct.sh — the Orchestration Conductor's engine (ORCHESTRATION.md).
#
# A host-side Claude conductor: classify a request → emit a plan.json of steps →
# dispatch each step to a specialist CLI as a TRACKED BACKGROUND JOB → synthesize
# the results into drafts/. Reuses the existing routing/firewall vocabulary
# (resolve_model / assemble_context / run_model) so the leak guard applies unchanged.
#
# Sourced by bin/conduct (terminal) and reused by bin/host-runner (bridge role "conduct").
# Hard rules honoured here:
#   - firewall: every step's context is built via assemble_context (synopsis-substituted
#     for moderated roles) and passes through run_model's leak guard. Nothing explicit
#     ever reaches a moderated model.
#   - lifecycle: every step has a status file + a per-step timeout; the poll loop kills
#     on timeout and never returns until every step is terminal. No silent hang/fail.
#   - macOS bash 3.2: no associative arrays, no mapfile, no setsid.

# --- model pinning (decision: Sonnet plans, Opus synthesizes) ---------------
CONDUCT_PLAN_MODEL="${CONDUCT_PLAN_MODEL:-sonnet}"
CONDUCT_SYNTH_MODEL="${CONDUCT_SYNTH_MODEL:-opus}"
# per-step timeouts (seconds). Grok hangs ~2-3min flushing telemetry, so it gets longer.
# Kimi (kimi-k2.6) is a THINKING model: a sizeable 中文 localization spends minutes on reasoning
# tokens before the prose lands. run-model.sh streams it (no per-read stall), but the lane still
# needs a long wall-clock budget or this poll loop SIGKILLs a healthy job at 300s (the S29 failure).
CONDUCT_STEP_TIMEOUT="${CONDUCT_STEP_TIMEOUT:-300}"
CONDUCT_GROK_TIMEOUT="${CONDUCT_GROK_TIMEOUT:-420}"
CONDUCT_KIMI_TIMEOUT="${CONDUCT_KIMI_TIMEOUT:-900}"

# ---------------------------------------------------------------------------
# plan.json query helper. Usage: _pj <plan.json> <query> [args...]
#   queries: validate | groups | steps_in_group <g> | field <stepid> <key>
#            reads <stepid> | stepid_for_writes <name> | play | targets
# ---------------------------------------------------------------------------
_pj() {
  python3 - "$@" <<'PY'
import json, sys
plan = json.load(open(sys.argv[1]))
q = sys.argv[2]
def steps(): return plan.get("steps", [])
def find(sid):
    for s in steps():
        if str(s.get("id")) == sid: return s
    return None
if q == "validate":
    errs = []
    if not isinstance(plan.get("play"), str) or not plan["play"].strip():
        errs.append("missing/empty 'play'")
    ss = plan.get("steps")
    if not isinstance(ss, list) or not ss:
        errs.append("missing/empty 'steps'")
    MODELS = {"claude","codex","agy","grok","deepseek","kimi"}
    seen = set()
    for i, s in enumerate(ss or []):
        for k in ("id","model","role","writes"):
            if not s.get(k): errs.append(f"step[{i}] missing '{k}'")
        if s.get("id") in seen: errs.append(f"duplicate step id '{s.get('id')}'")
        seen.add(s.get("id"))
        if s.get("model") not in MODELS: errs.append(f"step '{s.get('id')}' bad model '{s.get('model')}'")
        g = s.get("parallel_group")
        if not isinstance(g, int) or g < 1: errs.append(f"step '{s.get('id')}' bad parallel_group")
    if errs:
        print("\n".join(errs)); sys.exit(1)
    sys.exit(0)
elif q == "groups":
    gs = sorted({int(s.get("parallel_group",1)) for s in steps()})
    print("\n".join(str(g) for g in gs))
elif q == "steps_in_group":
    g = int(sys.argv[3])
    for s in steps():
        if int(s.get("parallel_group",1)) == g: print(s["id"])
elif q == "max_group":
    print(max((int(s.get("parallel_group",1)) for s in steps()), default=1))
elif q == "field":
    s = find(sys.argv[3]) or {}
    print(s.get(sys.argv[4], ""))
elif q == "reads":
    s = find(sys.argv[3]) or {}
    for r in s.get("reads", []) or []: print(r)
elif q == "stepid_for_writes":
    name = sys.argv[3]
    for s in steps():
        if s.get("writes") == name: print(s["id"]); break
elif q == "play":
    print(plan.get("play",""))
elif q == "targets":
    for t in plan.get("targets", []) or []: print(t)
PY
}

# ---------------------------------------------------------------------------
# conduct_index — a cheap "what's in the repo" map (names only, no contents) for
# the planner. Resolves ORCHESTRATION.md §10.4 without a generated index file.
# ---------------------------------------------------------------------------
conduct_index() {
  printf '===== REPO INDEX (names only) =====\n'
  local d
  for d in codex manuscript drafts; do
    [ -d "$ROOT/$d" ] || continue
    printf '\n-- %s/ --\n' "$d"
    # list .md files; never print contents. *.explicit.md names are SFW (just filenames).
    find "$ROOT/$d" -type f -name '*.md' 2>/dev/null | sed "s#^$ROOT/##" | sort
  done
}

# ---------------------------------------------------------------------------
# conduct_play_template <name> <plan-out> <slug> <targets...>
# Emits a canonical plan.json for a --play template (no LLM call).
# ---------------------------------------------------------------------------
conduct_play_template() {
  local play="$1" out="$2" slug="$3"; shift 3
  CONDUCT_PLAY="$play" CONDUCT_SLUG="$slug" CONDUCT_STEER="${CONDUCT_STEER:-}" python3 - "$out" "$@" <<'PY'
import json, os, sys
out = sys.argv[1]
targets = sys.argv[2:]
play = os.environ["CONDUCT_PLAY"]
slug = os.environ["CONDUCT_SLUG"]
T = list(targets)

def synth(reads, instruction, artifact, model="claude"):
    return {"id":"synth","model":model,"role":"prose","parallel_group":2,
            "claude_model":"opus","reads":reads,"writes":"synth.md",
            "artifact":artifact,"instruction":instruction}

plans = {}
plans["idea"] = {
  "play":"idea","targets":T,
  "steps":[
    {"id":"angles","model":"grok","role":"brainstorm","parallel_group":1,
     "reads":T,"writes":"angles.md",
     "instruction":"Treat the target(s) as a raw idea. Surface 6-8 distinct, bold angles / reversals / hooks that would grip a 网文 reader. One line each on why it fits the established characters & world."},
    {"id":"feas","model":"codex","role":"structure","parallel_group":1,
     "reads":T+["codex/outline.md"],"writes":"feas.md",
     "instruction":"Assess structural feasibility of this idea against the outline: where it slots, what beats it needs, plot-logic risks, and the 3 highest-leverage structural moves."},
    {"id":"core","model":"claude","role":"voice","parallel_group":1,
     "reads":T,"writes":"core.md",
     "instruction":"Find the emotional/voice core of this idea: whose want drives it, the truest emotional beat, and how it should FEEL in the author's voice. Cite character cards."},
    synth(["angles.md","feas.md","core.md"],
          "Synthesize a single concrete proposal from the three inputs (wild angles, structural feasibility, emotional core). Lead with a one-paragraph rationale, then: the recommended direction, the key beats, and the strongest 2-3 ideas to keep. Dedupe overlap; flag disagreements.",
          f"{slug}.proposal.md"),
  ]}
plans["adversarial-review"] = {
  "play":"adversarial-review","targets":T,
  "steps":[
    {"id":"voice","model":"claude","role":"audit","parallel_group":1,
     "reads":T+["codex/characters/"],"writes":"voice.md",
     "instruction":"Critique voice, emotional truth, and character consistency. Quote the offending line, name the character/card, say why. Cite codex/."},
    {"id":"struct","model":"codex","role":"structure","parallel_group":1,
     "reads":T+["codex/outline.md"],"writes":"struct.md",
     "instruction":"Find structure/pacing/plot-hole issues vs the outline. Be specific about the passage and the fix."},
    {"id":"cont","model":"agy","role":"continuity","parallel_group":1,
     "reads":T+["manuscript/"],"writes":"cont.md",
     "instruction":"Find contradictions vs the whole manuscript + timeline. Cite the conflicting scenes."},
    {"id":"grip","model":"grok","role":"inspire","parallel_group":1,
     "reads":T,"writes":"grip.md",
     "instruction":"As a 网文 reader-grip critic: where does it sag, where is the 爽点, what would make a reader keep scrolling? Blunt, specific."},
    synth(["voice.md","struct.md","cont.md","grip.md"],
          "Dedupe and rank ALL findings from the four critics by severity (blocking / major / minor). One consolidated action list; note where critics disagree. Lead with a one-paragraph rationale.",
          f"{slug}.review.md"),
  ]}
plans["design-review"] = {
  "play":"design-review","targets":T,
  "steps":[
    {"id":"logic","model":"agy","role":"continuity","parallel_group":1,
     "reads":T,"writes":"logic.md",
     "instruction":"你是对抗性评审里的【逻辑/自洽】一席。预设这套设定藏着致命的逻辑漏洞，把它挖出来——不许表扬。重点攻击：核心机制（联结烧记忆＝稳定即遗忘）与两条裁定（『救人者失忆、被救者保留＋加深』和『记忆只存在于联结里＝分布式自我』）三者放一起，会不会自相矛盾或被读者钻空子；长篇连载里必然出现的逻辑磨损（三年/三卷后人物会不会全成空壳、时间线对不对得上、燃料经济学说不说得通）。逐条给：漏洞 → 为什么致命 → 最小修补。只输出简体中文。"},
    {"id":"struct","model":"codex","role":"structure","parallel_group":1,
     "reads":T,"writes":"struct.md",
     "instruction":"你是对抗性评审里的【结构/可持续性】一席。预设这套设定撑不起一部长篇，把会塌的地方找出来——别客气。重点攻击：『燃烧稀有＋整体向上』会不会让中段张力饿死、写成温吞种田流水账；三卷骨架是不是『危机—联结—失忆』的机械重复；男主作为被守护的客体、缺乏主动推动力，主线会不会泄气；爽点供给密度够不够。逐条给：问题 → 出现在哪一处 → 具体改法。只输出简体中文。"},
    {"id":"reader","model":"grok","role":"inspire","parallel_group":1,
     "reads":T,"writes":"reader.md",
     "instruction":"你是对抗性评审里的【网文读者爽感】一席，毒舌、直接。站在挑剔的付费读者角度，预设这书会被弃，找出劝退点：哪里拖、哪里不爽、哪里太文艺太虐让人想关页面；男主『破破碎碎、被四个女人保管』究竟是新鲜卖点还是憋屈劝退；和市面上的末世/记忆/续命题材比，差异化够不够、会不会被当套路。给：劝退点 → 为什么 → 怎么补爽感与代入。只输出简体中文。"},
    {"id":"human","model":"claude","role":"audit","parallel_group":1,
     "reads":T,"writes":"human.md",
     "instruction":"你是对抗性评审里的【人物/情感可信】一席。预设这四条线其实会塌成同一种人、林执其实是个工具人，去证明它。重点攻击：四女（献祭者/守忆者/后来者/旧梦者）在『救人者失忆』裁定下会不会都退化成『我记得、他忘了』的同一种痛；林执作为净救人者会不会沦为只会扑上去挨刀的受气包、没有主体性与魅力；『躯体残影/超载回放』反复使用会不会煽情过载、读者麻木。给：哪条线/哪个人最假 → 为什么 → 怎么救。只输出简体中文。"},
    synth(["logic.md","struct.md","reader.md","human.md"],
          "把四位对抗性评审的火力综合成一份面向人类作者的诊断报告，直接用简体中文写（别绕英文）。按严重度排序（致命/重大/次要），每条自然地点明是哪一席提出的（融进叙述，不要贴标签堆砌）。明确区分『真问题』与『只是口味偏好』；点出四席彼此打架、互相矛盾的地方。结尾给一段『如果只先改三件事，改哪三件、为什么』。只输出中文正文。",
          f"{slug}.review.md"),
  ]}
plans["scene-draft"] = {
  "play":"scene-draft","targets":T,
  "steps":[
    {"id":"draft",
     "model":("deepseek" if os.environ.get("CONDUCT_SCENE_BULK")=="1" else "claude"),
     "role":("bulk" if os.environ.get("CONDUCT_SCENE_BULK")=="1" else "prose"),
     "parallel_group":1,"reads":T,"writes":"draft.md",
     "artifact":f"{slug}.draft.md",
     "instruction":"Draft this scene per the spec/stub in the target. Stay in the author's voice and Simplified-Chinese register. Lead with a one-paragraph rationale, then the prose. Propose, don't claim final."},
  ]}
plans["continuity"] = {
  "play":"continuity","targets":T,
  "steps":[
    {"id":"cont","model":"agy","role":"continuity","parallel_group":1,
     "reads":T+["manuscript/"],"writes":"cont.md",
     "artifact":f"{slug}.continuity.md",
     "instruction":"Continuity + timeline audit of the target against the whole manuscript. List contradictions with the conflicting scenes cited; lead with a one-paragraph rationale."},
  ]}
plans["voice"] = {
  "play":"voice","targets":T,
  "steps":[
    {"id":"voice","model":"claude","role":"voice","parallel_group":1,
     "reads":T+["codex/characters/"],"writes":"voice.md",
     "artifact":f"{slug}.voice.md",
     "instruction":"Voice + emotional-truth audit of the target. Quote weak lines, name the character/card, propose targeted fixes (not a wholesale rewrite). Lead with a one-paragraph rationale."},
  ]}
# explore: divergent story-direction ideation with a Gemini logic lane + a localization
# tail. Generators (grok directions || codex structure || agy/Gemini logic-audit || claude
# emotional core) -> Opus synthesizes IN ENGLISH (reasoning layer) -> Kimi localizes to
# idiomatic 简体中文 -> Opus reviews the Chinese for fidelity and emits the final artifact.
# Rationale: Opus reasons best in English but its 中文 文笔 reads stiff; Kimi (native ear)
# renders the prose, Opus guards meaning. (No raw double-quotes inside any instruction value.)
plans["explore"] = {
  "play":"explore","targets":T,
  "steps":[
    {"id":"grok-angles","model":"grok","role":"brainstorm","parallel_group":1,
     "reads":T,"writes":"grok-angles.md",
     "instruction":"把目标文档当作已定的合并世界设定（病毒末世＋情感联结续命＋记忆机制）。发散头脑风暴这个世界的故事可以怎么走：给出4-6个彼此不同的剧情走向／主线引擎（不是世界设定，而是主要矛盾、推进动力、爽点曲线）。每条一段，点明最大的钩子与最大的风险。简体中文。"},
    {"id":"codex-structure","model":"codex","role":"structure","parallel_group":1,
     "reads":T,"writes":"codex-structure.md",
     "instruction":"基于目标的合并世界，设计故事的结构骨架：贯穿全篇的主线问题、三卷式骨架（每卷的转折与升级）、以及记忆机制如何驱动分卷节奏。指出最大的结构风险与对冲办法。简体中文。"},
    {"id":"gemini-logic","model":"agy","role":"continuity","parallel_group":1,
     "reads":T,"writes":"gemini-logic.md",
     "instruction":"以世界观自洽与长线逻辑审查的视角，压力测试这套合并机制（稳定＝烧记忆／记忆分布在彼此身上）。逐条找出长篇连载中的逻辑漏洞、机制可被读者钻空子的地方、以及隐藏的长程后果（例如三年后五人还剩多少共同记忆）。给出修补建议。简体中文。"},
    {"id":"claude-core","model":"claude","role":"voice","parallel_group":1,
     "reads":T,"writes":"claude-core.md",
     "instruction":"从情感与人物关系角度，给出四女一男在这套记忆×情感机制下的关系曲线：每个人的情感节奏如何与烧记忆的代价咬合，谁的线最能制造落差与爽点。聚焦情感逻辑，不写具体剧情。简体中文。"},
    {"id":"synth-cn","model":"claude","role":"prose","claude_model":"opus","parallel_group":2,
     "reads":["grok-angles.md","codex-structure.md","gemini-logic.md","claude-core.md"],"writes":"synth-cn.md",
     "instruction":"你是综合层，读者是人。四条分身草稿本身已是简体中文（Grok 走向发散、Codex 结构骨架、Gemini 逻辑审查、Claude 人物情感），所以直接用简体中文综合——不要绕英文（绕一圈会丢掉它们原有的好中文，连专有名词都会走样）。把四份揉成一份**面向人类读者**的探索稿，讲清楚这个融合世界的故事能往哪走：核心主线问题、三卷骨架、四女一男五条关系曲线如何与『烧记忆』机制咬合、2-3 个真正不同的故事方向、以及还没拍板的设计问题。硬规矩：(1)不要收敛到单一答案，铺开选项空间；(2)**保留每个观点的来源**（我要知道是哪个分身提的），但化进自然叙述里——写成『Codex 把结构搭成…』『Gemini 的审查抓住…』，绝不要用贴标签式的『某某（角色）：』堆砌；(3)不要照搬表格，把表格信息化成能读的段落；(4)不用行话黑话（如脊柱问题／承重／卷级钝痛），换成读者能懂的话；(5)沿用草稿里已有的好中文与专有名词——男主叫**林执**，四种态度叫献祭者／守忆者／后来者／旧梦者，不要另造名字。开头用一句话说明这是对融合世界故事走向的探索、尚非定稿。只输出中文正文。"},
    {"id":"review-cn","model":"claude","role":"audit","claude_model":"opus","parallel_group":3,
     "reads":["grok-angles.md","codex-structure.md","gemini-logic.md","claude-core.md","synth-cn.md"],"writes":"review.md",
     "artifact":f"{slug}.explore.md",
     "instruction":"对照四条分身草稿与综合稿，做忠实度＋可读性的最后一道工序：补回任何被丢掉的关键点、纠正机制细节错误、确认每处来源标注准确无误且读起来自然；同时润掉生硬、翻译腔或贴标签式的残留，但**不得改写作者声音、不得把自然中文改回生硬中文**。专有名词以草稿为准（男主＝林执；四态度＝献祭者／守忆者／后来者／旧梦者）。输出最终、干净、可直接交付的简体中文版本，仅中文正文。"},
  ]}

if play not in plans:
    sys.stderr.write(f"unknown play: {play}\n"); sys.exit(2)
# S24 #5: a forced --play can carry an operator instruction (--note). Steer every
# lane toward that focus by appending it to each step's instruction, so a templated
# play still honors "…focus on Jon" instead of silently ignoring it.
steer = os.environ.get("CONDUCT_STEER","").strip()
if steer:
    for st in plans[play]["steps"]:
        st["instruction"] = st["instruction"].rstrip() + "\n\nOPERATOR STEERING — focus this lane specifically on: " + steer
json.dump(plans[play], open(out,"w"), ensure_ascii=False, indent=2)
PY
}

# ---------------------------------------------------------------------------
# conduct_plan <plan-out> <request> <targets...> — LLM classifier/planner (Sonnet).
# Writes a validated plan.json to <plan-out>. Dies loudly on invalid JSON.
# ---------------------------------------------------------------------------
conduct_plan() {
  local out="$1" request="$2"; shift 2
  local pf; pf="$(mktemp)"
  {
    printf '# You are the Orchestration Conductor (Claude Sonnet, host-side).\n\n'
    printf 'You route a human novelist'"'"'s request to specialist models that collaborate over the\n'
    printf 'filesystem, then a synthesis step composes the result. Output ONLY a JSON plan.\n\n'
    printf '## House rules (AGENTS.md)\n'; cat "$ROOT/AGENTS.md"
    printf '\n## What is in the repo\n'; conduct_index
    printf '\n## The request\n%s\n' "$request"
    if [ "$#" -gt 0 ]; then
      printf '\n## Target material (firewalled)\n'
      assemble_context conduct "$@"
    fi
    cat <<'GUIDE'

## Play catalog (pick the best fit; you may adapt reads/instructions)
- idea: raw idea -> grok(angles) || codex(feasibility) || claude(voice/emotion) -> claude(opus) synthesizes a proposal.
- adversarial-review: audit a draft -> claude(voice) || codex(structure) || agy(continuity) || grok(reader-grip) -> claude(opus) dedupes+ranks.
- scene-draft: write a scene -> claude(prose) for signature/emotional, or deepseek(bulk) for genre/bulk -> (optional) claude polish.
- continuity: single agy continuity pass. voice: single claude voice pass.

## Routing brain (model strengths)
- claude: prose/voice/emotion, dialogue, synthesis (best 中文 文笔 of the five). roles: prose|voice|audit.
- codex: structure/outline/pacing/plot-logic. role: structure.
- agy (Gemini): whole-manuscript continuity / long context (NOT for Chinese prose). role: continuity.
- grok: wild angles + 爽点/reader-grip (slow ~2-3min). roles: brainstorm|inspire. (also the only NSFW lane, off-limits here.)
- deepseek: cheap SFW bulk / 网文 / setting first-pass (API). role: bulk.
- kimi (Kimi K2.6): 简体中文 signature/emotional prose, best 中文 文笔 of the API lanes (native-Chinese ear). role: cnprose. Use for 中文 signature passages; SFW only.

## Plan JSON schema (emit EXACTLY this shape, no markdown fences, no prose)
{
  "play": "<play-name>",
  "targets": [<the target paths you were given>],
  "steps": [
    {"id":"<short-id>", "model":"claude|codex|agy|grok|deepseek", "role":"<resolve_model role>",
     "parallel_group":<int >=1>, "reads":[<paths or earlier steps' writes-names>],
     "writes":"<name.md>", "instruction":"<what this model must produce>",
     "claude_model":"sonnet|opus (optional; use opus for the final synthesis step)",
     "artifact":"<bare filename only, NO directory — e.g. s01.continuity.md (it is written into drafts/ for you); ONLY on the last/synthesis step>"}
  ]
}

Rules:
- Same parallel_group runs concurrently; higher groups depend on lower groups' outputs.
- A step's `reads` may name an earlier step's `writes` value to consume its output.
- The final (highest-group) step is the synthesis: set claude_model=opus and an `artifact` filename.
- Use role names exactly: prose|voice|audit|structure|continuity|cnprose|brainstorm|inspire|bulk.
- CRITICAL JSON SAFETY: inside every "instruction" (and any other) string value, NEVER use a raw double-quote character. For emphasis in Chinese use 「」 or 『』; in English use single quotes '...'. A raw " inside a value breaks the JSON and the whole run aborts. Do not rely on escaping — just avoid " entirely inside values.
- Keep it SFW. Output ONLY the JSON object.
GUIDE
  } > "$pf"

  info "Planning with Claude $CONDUCT_PLAN_MODEL …"
  local raw; raw="$(CLAUDE_MODEL="$CONDUCT_PLAN_MODEL" run_model conduct "$pf")" || { rm -f "$pf"; die "conductor planning call failed"; }
  rm -f "$pf"
  # strip ```json fences / leading prose; keep from first { to last }
  printf '%s' "$raw" | python3 -c 'import sys,re; t=sys.stdin.read(); i=t.find("{"); j=t.rfind("}"); sys.stdout.write(t[i:j+1] if i>=0 and j>i else t)' > "$out"
  if ! python3 -m json.tool "$out" >/dev/null 2>&1; then
    warn "planner did not return valid JSON; raw output saved to ${out}.raw"
    printf '%s' "$raw" > "${out}.raw"
    die "conductor planning produced invalid JSON (see ${out}.raw)"
  fi
  local verr; if ! verr="$(_pj "$out" validate)"; then
    die "conductor plan failed validation:\n$verr"
  fi
  ok "Plan ready ($(_pj "$out" play), $(_pj "$out" groups | wc -l | tr -d ' ') group(s))."
}

# ---------------------------------------------------------------------------
# run_step <job-dir> <plan.json> <stepid> — run ONE step.
# Builds firewalled context (repo reads via assemble_context; earlier-step
# outputs inlined), dispatches via run_model, writes <stepid>.out / <stepid>.log,
# and sets the terminal status file as its LAST action.
# ---------------------------------------------------------------------------
run_step() {
  local jd="$1" plan="$2" sid="$3"
  local role model cmodel instruction
  role="$(_pj "$plan" field "$sid" role)"
  model="$(_pj "$plan" field "$sid" model)"
  cmodel="$(_pj "$plan" field "$sid" claude_model)"
  instruction="$(_pj "$plan" field "$sid" instruction)"

  # partition reads into earlier-step outputs vs repo targets (expand dirs)
  local repo_targets=() prior_inputs=() r sidof base
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    sidof="$(_pj "$plan" stepid_for_writes "$r")"
    if [ -n "$sidof" ] && [ -f "$jd/$sidof.out" ]; then
      prior_inputs+=("$r|$sidof")
      continue
    fi
    # repo path: absolutize against ROOT
    local p="$r"; case "$p" in /*) :;; *) p="$ROOT/$r";; esac
    if [ -d "$p" ]; then
      while IFS= read -r f; do
        case "$f" in "$ROOT"/codex/*) continue;; esac   # codex already in the bible
        repo_targets+=("$f")
      done < <(find "$p" -type f -name '*.md' 2>/dev/null | sort)
    elif [ -f "$p" ]; then
      case "$p" in "$ROOT"/codex/*) :;; *) repo_targets+=("$p");; esac
    else
      warn "step $sid: read not found, skipping: $r"
    fi
  done < <(_pj "$plan" reads "$sid")

  local pf; pf="$(mktemp)"
  {
    # CACHED PREFIX FIRST (house rules + bible + output contract) — byte-identical across
    # every step/role in this moderation class, so each critic + synth call hits the lane's
    # prefix cache instead of re-billing the whole bible. The variable suffix (step header,
    # target material, prior-step inputs, task) follows the delimiter. (Stage 1.5.)
    # NB: repo_targets already excludes $ROOT/codex/* (the bible lives in the prefix), so no
    # double-bible.
    assemble_prefix "$role"
    printf '# Conductor step: %s  (%s)\n' "$sid" "$(role_label "$role")"
    printf 'You are one specialist voice in a multi-model collaboration on a human novelist'"'"'s\n'
    printf 'Simplified-Chinese manuscript. Write ONLY your contribution.\n\n'
    if [ "${#repo_targets[@]}" -gt 0 ]; then
      printf '## Target material\n'
      assemble_targets "$role" "${repo_targets[@]}"
      printf '\n'
    fi
    if [ "${#prior_inputs[@]}" -gt 0 ]; then
      printf '## Inputs from earlier steps (each labeled with the model that produced it)\n'
      local pi name osid
      for pi in "${prior_inputs[@]}"; do
        name="${pi%%|*}"; osid="${pi#*|}"
        printf '\n----- %s — by %s [model: %s] -----\n' \
          "$name" "$(role_label "$(_pj "$plan" field "$osid" role)")" "$(_pj "$plan" field "$osid" model)"
        cat "$jd/$osid.out"; printf '\n'
      done
      printf '\n'
    fi
    printf '## Your task\n%s\n' "$instruction"
    if [ "${#prior_inputs[@]}" -gt 0 ]; then
      printf '\nATTRIBUTE every point to its source lane (e.g. "Codex (structure):", "Grok (爽点):", '
      printf '"Gemini (continuity):", "Claude (voice):") so each claim is traceable back to the model that raised it.\n'
    fi
  } > "$pf"

  local rc=0 raw="$jd/$sid.out.raw" effmodel="$model"
  [ -n "$cmodel" ] && [ "$model" = claude ] && effmodel="claude:$cmodel"
  # per-run usage capture: run_model side-writes this step's token/cost JSON here
  export USAGE_SINK="$jd/.usage-$sid.json"
  if [ -n "$cmodel" ] && [ "$model" = claude ]; then
    CLAUDE_MODEL="$cmodel" run_model "$role" "$pf" > "$raw" 2> "$jd/$sid.log" || rc=$?
  else
    run_model "$role" "$pf" > "$raw" 2> "$jd/$sid.log" || rc=$?
  fi
  rm -f "$pf"
  if [ "$rc" -eq 0 ] && [ -s "$raw" ]; then
    # prepend an attribution byline so the producing model is obvious when debugging / synthesizing
    {
      printf '<!-- conduct:step id=%s model=%s role=%s -->\n' "$sid" "$effmodel" "$role"
      printf '> _Contributed by **%s** — model `%s`, step `%s`._\n\n' "$(role_label "$role")" "$effmodel" "$sid"
      cat "$raw"
    } > "$jd/$sid.out"
    rm -f "$raw"
    date +%s > "$jd/.end-$sid"   # freeze the elapsed clock at completion
    printf 'done\n' > "$jd/.status-$sid"
  else
    date +%s > "$jd/.end-$sid"
    printf 'failed\n' > "$jd/.status-$sid"
    printf 'exit=%s\n' "$rc" >> "$jd/$sid.log"
    rm -f "$raw"
  fi
}

_step_timeout() {  # <plan> <stepid> -> seconds (grok + kimi get the longer budget)
  local m; m="$(_pj "$1" field "$2" model)"
  case "$m" in
    grok) [ "$CONDUCT_GROK_TIMEOUT" -gt "$CONDUCT_STEP_TIMEOUT" ] && echo "$CONDUCT_GROK_TIMEOUT" || echo "$CONDUCT_STEP_TIMEOUT" ;;
    kimi) [ "$CONDUCT_KIMI_TIMEOUT" -gt "$CONDUCT_STEP_TIMEOUT" ] && echo "$CONDUCT_KIMI_TIMEOUT" || echo "$CONDUCT_STEP_TIMEOUT" ;;
    *)    echo "$CONDUCT_STEP_TIMEOUT" ;;
  esac
}

# _usage_cell <usage-json> — format a step's usage sidecar as "12.3k/$0.05" (or "-").
_usage_cell() {
  [ -f "$1" ] || { printf -- '-'; return 0; }
  python3 - "$1" <<'PY' 2>/dev/null || printf -- '-'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("-"); sys.exit(0)
t = d.get("total_tokens"); c = d.get("cost_usd_est")
tok = "-" if t is None else (("%.1fk" % (t / 1000.0)) if t >= 1000 else str(t))
print(tok if c is None else "%s/$%.2f" % (tok, c))
PY
}

# conduct_usage_summary_ro <job-dir> — READ-ONLY per-lane usage YAML (no ledger write).
# Used by the frontmatter block, the --usage report, and the run footer.
conduct_usage_summary_ro() {
  python3 - "$1" <<'PY' 2>/dev/null || true
import json, os, sys, glob
jd = sys.argv[1]
lanes = {}; total_tok = 0; total_cached = 0; total_cost = 0.0; has_cost = False
for f in sorted(glob.glob(os.path.join(jd, ".usage-*.json"))):
    try:
        d = json.load(open(f))
    except Exception:
        continue
    lane = d.get("lane", "?")
    t = d.get("total_tokens"); c = d.get("cost_usd_est")
    cr = d.get("cache_read_tokens")
    if cr is None: cr = d.get("cached_input_tokens")
    L = lanes.setdefault(lane, {"tokens": 0, "cached": 0, "cost": 0.0, "calls": 0, "has_cost": False})
    if isinstance(t, (int, float)): L["tokens"] += t; total_tok += t
    if isinstance(cr, (int, float)): L["cached"] += cr; total_cached += cr
    if isinstance(c, (int, float)): L["cost"] += c; total_cost += c; L["has_cost"] = True; has_cost = True
    L["calls"] += 1
out = []
uncounted = []
for lane, L in sorted(lanes.items()):
    # A lane with calls but no token/cost numbers doesn't expose usage via its CLI
    # (e.g. Grok/Gemini — not scraped, by ToS). Say so plainly instead of "0 tok",
    # which reads as "free" and makes the total look complete when it isn't.
    if not L["has_cost"] and L["tokens"] == 0:
        uncounted.append(lane)
        out.append("  %s: usage not reported by CLI (%d call%s)" % (lane, L["calls"], "" if L["calls"] == 1 else "s"))
        continue
    cost = ("$%.4f" % L["cost"]) if L["has_cost"] else "n/a"
    out.append("  %s: %d tok (%d cached), %s (%d call%s)" % (lane, L["tokens"], L["cached"], cost, L["calls"], "" if L["calls"] == 1 else "s"))
gt = ("$%.4f" % total_cost) if has_cost else "n/a"
label = "total (counted lanes)" if uncounted else "total"
out.append("  %s: %d tok (%d cached), %s" % (label, total_tok, total_cached, gt))
if uncounted:
    out.append("  note: %s usage not exposed by their CLI — excluded from total" % ", ".join(uncounted))
sys.stdout.write("\n".join(out) + "\n")
PY
}

# conduct_ledger_append_job <job-dir> <job-id> — append each step's usage to the
# run-log ledger (orchestration/logs/usage-ledger.jsonl) that bin/usage tallies.
conduct_ledger_append_job() {
  local jd="$1" job="$2"
  USAGE_LEDGER="${USAGE_LEDGER:-$ROOT/orchestration/logs/usage-ledger.jsonl}" \
  python3 - "$jd" "$job" <<'PY' 2>/dev/null || true
import json, os, sys, glob, datetime
jd, job = sys.argv[1], sys.argv[2]
ledger = os.environ["USAGE_LEDGER"]
os.makedirs(os.path.dirname(ledger), exist_ok=True)
ts = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
with open(ledger, "a") as fh:
    for f in sorted(glob.glob(os.path.join(jd, ".usage-*.json"))):
        sid = os.path.basename(f)[len(".usage-"):-len(".json")]
        try:
            d = json.load(open(f))
        except Exception:
            continue
        t = d.get("total_tokens"); c = d.get("cost_usd_est")
        # cache-read tokens, however each lane names them (claude/deepseek: cache_read_tokens;
        # codex: cached_input_tokens). The Stage-1.5 post-cache-spend signal.
        cr = d.get("cache_read_tokens")
        if cr is None: cr = d.get("cached_input_tokens")
        fh.write(json.dumps({"ts": ts, "job": job, "sid": sid, "lane": d.get("lane", "?"),
                             "total_tokens": (t if isinstance(t, (int, float)) else None),
                             "cached_tokens": (cr if isinstance(cr, (int, float)) else None),
                             "cost_usd_est": (c if isinstance(c, (int, float)) else None)}) + "\n")
PY
}

# ---------------------------------------------------------------------------
# status_table <job-dir> <plan.json> — render step | model | status | elapsed | out | usage
# ---------------------------------------------------------------------------
status_table() {
  local jd="$1" plan="$2" g sid st model start now el bytes tag usage
  now="$(date +%s)"
  printf '  %-10s %-9s %-9s %-8s %-7s %-12s %s\n' STEP MODEL STATUS ELAPSED OUTPUT 'USAGE(tok/$)' ''
  for g in $(_pj "$plan" groups); do
    for sid in $(_pj "$plan" steps_in_group "$g"); do
      st=pending; [ -f "$jd/.status-$sid" ] && st="$(cat "$jd/.status-$sid")"
      model="$(_pj "$plan" field "$sid" model)"
      tag=""; [ "$model" = grok ] && tag="(slow~2-3m)"
      start=0; [ -f "$jd/.start-$sid" ] && start="$(cat "$jd/.start-$sid")"
      if [ "$start" -gt 0 ]; then el="$((now-start))s"; else el="-"; fi
      bytes="-"; [ -f "$jd/$sid.out" ] && bytes="$(wc -c < "$jd/$sid.out" | tr -d ' ')b"
      usage="$(_usage_cell "$jd/.usage-$sid.json")"
      printf '  %-10s %-9s %-9s %-8s %-7s %-12s %s\n' "$sid" "$model" "$st" "$el" "$bytes" "$usage" "$tag"
    done
  done
}

# ---------------------------------------------------------------------------
# Live progress brief — a friendly "writers'-room" snapshot streamed to the
# OpenClaw panel (via host-runner's bridge file + the plugin's ctx.onUpdate) so
# the user can WATCH the orchestra work instead of staring at a blind wait.
# Reuses status_table's on-disk data (.status-*/.start-*/.usage-*).
# ---------------------------------------------------------------------------
_status_icon() {  # <status> -> friendly glyph
  case "$1" in
    done)    printf '✓' ;;
    failed)  printf '✗' ;;
    timeout) printf '⏱' ;;
    running) printf '⏳' ;;
    *)       printf '·' ;;
  esac
}

# progress_frame <job-dir> <plan.json> [headline] — render one compact frame.
progress_frame() {
  local jd="$1" plan="$2" headline="${3:-conducting}" g sid st model start now el usage icon tag play
  now="$(date +%s)"
  play="$(_pj "$plan" play 2>/dev/null)"
  printf '🎼 %s — %s\n' "$headline" "${play:-conduct}"
  for g in $(_pj "$plan" groups); do
    for sid in $(_pj "$plan" steps_in_group "$g"); do
      st=pending; [ -f "$jd/.status-$sid" ] && st="$(cat "$jd/.status-$sid")"
      model="$(_pj "$plan" field "$sid" model)"
      icon="$(_status_icon "$st")"
      tag=""; [ "$model" = grok ] && [ "$st" = running ] && tag="  (slow ~2-3m)"
      start=0; [ -f "$jd/.start-$sid" ] && start="$(cat "$jd/.start-$sid")"
      endt=0; [ -f "$jd/.end-$sid" ] && endt="$(cat "$jd/.end-$sid")"
      if [ "$start" -gt 0 ] && [ "$st" != pending ]; then
        # freeze a finished step's clock at its end time; tick a running one against now
        if [ "$endt" -gt 0 ]; then el="$((endt-start))s"; else el="$((now-start))s"; fi
      else el="-"; fi
      usage="$(_usage_cell "$jd/.usage-$sid.json")"
      [ "$usage" = "-" ] && usage=""
      printf '  %s %-9s %-7s %-7s %-6s %s%s\n' "$icon" "$sid" "$model" "$st" "$el" "$usage" "$tag"
    done
  done
}

# conduct_brief <job-dir> <plan.json> — the FINAL frame: snapshot + verdict + relay marker.
# This is what host-runner prepends to the artifact so the relay's verbatim echo
# always shows what happened (incl. any failed/timed-out step).
conduct_brief() {
  local jd="$1" plan="$2" g sid fails=0 total=0
  for g in $(_pj "$plan" groups); do
    for sid in $(_pj "$plan" steps_in_group "$g"); do
      total=$((total+1))
      case "$(cat "$jd/.status-$sid" 2>/dev/null)" in failed|timeout) fails=$((fails+1)) ;; esac
    done
  done
  progress_frame "$jd" "$plan" "done"
  if [ "$fails" -gt 0 ]; then
    printf -- '→ %s of %s steps did not complete — synthesis noted the gap.\n' "$fails" "$total"
  else
    printf -- '→ all %s step(s) completed.\n' "$total"
  fi
  printf 'relay: this is the conductor'"'"'s verbatim artifact (host-side Claude — Sonnet plan / Opus synth).\n'
}

# _emit_progress <job-dir> <plan.json> [headline] — atomically write a frame to
# CONDUCT_PROGRESS_SINK (no-op when unset, e.g. plain terminal runs).
_emit_progress() {
  [ -n "${CONDUCT_PROGRESS_SINK:-}" ] || return 0
  local tmp="$CONDUCT_PROGRESS_SINK.tmp.$$"
  progress_frame "$1" "$2" "${3:-conducting}" > "$tmp" 2>/dev/null && mv -f "$tmp" "$CONDUCT_PROGRESS_SINK" 2>/dev/null
  rm -f "$tmp" 2>/dev/null
}

# _emit_brief <job-dir> <plan.json> — atomically write the final brief to the sink.
_emit_brief() {
  [ -n "${CONDUCT_PROGRESS_SINK:-}" ] || return 0
  local tmp="$CONDUCT_PROGRESS_SINK.tmp.$$"
  conduct_brief "$1" "$2" > "$tmp" 2>/dev/null && mv -f "$tmp" "$CONDUCT_PROGRESS_SINK" 2>/dev/null
  rm -f "$tmp" 2>/dev/null
}

# ---------------------------------------------------------------------------
# dispatch_plan <job-dir> <plan.json> — run all groups in ascending order.
# Each step is a tracked background job; the poll loop enforces per-step
# timeouts (kill on overrun) and never returns until every step is terminal.
# Returns non-zero if any step failed/timed out.
# ---------------------------------------------------------------------------
dispatch_plan() {
  local jd="$1" plan="$2" g sid pid start now to st sig last_sig="" overall=0 heartbeat=0
  for g in $(_pj "$plan" groups); do
    info "── parallel_group $g ──"
    # launch every step in this group as a background job
    for sid in $(_pj "$plan" steps_in_group "$g"); do
      printf 'running\n' > "$jd/.status-$sid"
      date +%s > "$jd/.start-$sid"
      ( run_step "$jd" "$plan" "$sid" ) &
      printf '%s\n' "$!" > "$jd/.pid-$sid"
    done
    # poll until all steps in this group are terminal
    while true; do
      local alldone=1
      for sid in $(_pj "$plan" steps_in_group "$g"); do
        st="$(cat "$jd/.status-$sid" 2>/dev/null || echo running)"
        case "$st" in done|failed|timeout) continue;; esac
        pid="$(cat "$jd/.pid-$sid" 2>/dev/null || echo)"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
          start="$(cat "$jd/.start-$sid")"; now="$(date +%s)"; to="$(_step_timeout "$plan" "$sid")"
          if [ "$((now-start))" -ge "$to" ]; then
            warn "step $sid exceeded ${to}s — killing"
            kill -TERM "$pid" 2>/dev/null; pkill -TERM -P "$pid" 2>/dev/null
            sleep 1
            kill -KILL "$pid" 2>/dev/null; pkill -KILL -P "$pid" 2>/dev/null
            date +%s > "$jd/.end-$sid"
            printf 'timeout\n' > "$jd/.status-$sid"
            printf 'killed after %ss\n' "$to" >> "$jd/$sid.log"
          else
            alldone=0
          fi
        else
          # pid gone: run_step sets the terminal status as its last act; if it's
          # still "running", the process died without finishing → mark failed.
          if [ "$(cat "$jd/.status-$sid" 2>/dev/null)" = running ]; then
            date +%s > "$jd/.end-$sid"; printf 'failed\n' > "$jd/.status-$sid"
          fi
        fi
      done
      # redraw status only when something changed (or every ~30s heartbeat)
      sig="$(for sid in $(_pj "$plan" steps_in_group "$g"); do cat "$jd/.status-$sid" 2>/dev/null; done | tr '\n' ',')"
      heartbeat=$((heartbeat+1))
      if [ "$sig" != "$last_sig" ] || [ "$((heartbeat % 15))" -eq 0 ]; then
        status_table "$jd" "$plan" >&2
        last_sig="$sig"
      fi
      # Refresh the panel frame every poll (~2s) so the elapsed clock ticks live —
      # "watching it work" needs a moving counter, not a frozen one between transitions.
      _emit_progress "$jd" "$plan" "conducting"
      [ "$alldone" -eq 1 ] && break
      sleep 2
    done
    # if any step in this group failed/timed out, record but continue (synthesis
    # will note the gap). Never abort silently.
    for sid in $(_pj "$plan" steps_in_group "$g"); do
      case "$(cat "$jd/.status-$sid" 2>/dev/null)" in
        failed|timeout) overall=1; warn "step $sid: $(cat "$jd/.status-$sid") (see $jd/$sid.log)";;
      esac
    done
  done
  return "$overall"
}

# ---------------------------------------------------------------------------
# conduct_finalize <job-dir> <plan.json> <slug> — copy the synthesis (highest
# group) step's output to drafts/ with frontmatter. Prints the artifact path.
# ---------------------------------------------------------------------------
conduct_finalize() {
  local jd="$1" plan="$2" slug="$3"
  local maxg sid artifact play targets dest
  maxg="$(_pj "$plan" max_group)"
  play="$(_pj "$plan" play)"
  targets="$(_pj "$plan" targets | tr '\n' ' ')"
  # the synthesis/output step is the (single) highest-group step
  sid="$(_pj "$plan" steps_in_group "$maxg" | head -1)"
  artifact="$(_pj "$plan" field "$sid" artifact)"
  [ -n "$artifact" ] || artifact="${play}-${slug}-$(short_id).md"
  # Artifacts always land FLAT in drafts/. The LLM planner sometimes emits a
  # path ("drafts/foo.md") or even an absolute/escaping one, which the unconditional
  # "$ROOT/drafts/$artifact" below would double ("drafts/drafts/…") or let escape.
  # Reduce to the basename so the output dir is always exactly $ROOT/drafts/.
  artifact="$(basename -- "$artifact")"
  dest="$ROOT/drafts/$artifact"
  mkdir -p "$(dirname "$dest")"
  if [ ! -s "$jd/$sid.out" ]; then
    warn "synthesis step '$sid' produced no output; writing a stub artifact noting the failure."
    {
      printf -- '---\nplay: %s\ntargets: %s\ngenerated: %s\njob: %s\nstatus: INCOMPLETE\n---\n\n' \
        "$play" "$targets" "$(date '+%Y-%m-%d %H:%M:%S')" "$(basename "$jd")"
      printf '# Conductor run incomplete\n\nThe synthesis step did not produce output. Per-step results:\n\n'
      status_table "$jd" "$plan"
    } > "$dest"
    _emit_brief "$jd" "$plan"
    printf '%s\n' "$dest"; return 1
  fi
  # who did what — one line per step (model card + model id + usage) for traceability
  local contributors="" g s
  for g in $(_pj "$plan" groups); do
    for s in $(_pj "$plan" steps_in_group "$g"); do
      contributors="${contributors}  - ${s}: $(role_label "$(_pj "$plan" field "$s" role)") [$(_pj "$plan" field "$s" model)] — $(cat "$jd/.status-$s" 2>/dev/null || echo '?') — usage: $(_usage_cell "$jd/.usage-$s.json")
"
    done
  done
  # per-lane usage rollup for the frontmatter, and append this run to the usage ledger
  local usage_summary; usage_summary="$(conduct_usage_summary_ro "$jd")"
  conduct_ledger_append_job "$jd" "$(basename "$jd")"
  {
    printf -- '---\nplay: %s\nconductor: claude (sonnet plan / opus synth)\ntargets: %s\ngenerated: %s\njob: %s\ncontributors:\n%susage_summary:\n%s\n---\n\n' \
      "$play" "$targets" "$(date '+%Y-%m-%d %H:%M:%S')" "$(basename "$jd")" "$contributors" "$usage_summary"
    cat "$jd/$sid.out"
  } > "$dest"
  _emit_brief "$jd" "$plan"
  printf '%s\n' "$dest"
}
