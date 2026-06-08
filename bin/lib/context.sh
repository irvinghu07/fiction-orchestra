#!/usr/bin/env bash
# context.sh — assemble the codex/ story-bible + target files into a prompt context,
# applying the NSFW firewall: for moderated roles, explicit files are replaced by
# their .synopsis.md sibling and nsfw-tagged codex files are dropped entirely.
#
# Usage:  assemble_context <role> <target-path> [<target-path> ...]
# Prints the assembled context block to stdout.

# print one file as a labelled section
_emit_file() {
  local path="$1" label="${2:-$1}"
  [ -f "$path" ] || return 0
  printf '\n----- %s -----\n' "$label"
  cat "$path"
  printf '\n'
}

# emit the codex/ bible, respecting nsfw tagging for moderated roles
_emit_codex() {
  local role="$1" moderated=1 f
  is_moderated_role "$role" || moderated=0
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in _TEMPLATE.md) continue;; esac
    if [ "$moderated" -eq 1 ] && file_is_nsfw_tagged "$f"; then
      _emit_file_placeholder "$f" "codex (nsfw-tagged, withheld from moderated model)"
      continue
    fi
    _emit_file "$f" "codex/${f#"$ROOT"/codex/}"
  done < <(find "$ROOT/codex" -type f -name '*.md' 2>/dev/null | sort)
}

_emit_file_placeholder() {
  printf '\n----- %s -----\n[withheld: %s]\n' "$1" "$2"
}

# emit a target scene/file, substituting synopsis when moderated. A target is
# explicit if it is named *.explicit.md OR frontmatter-tagged nsfw:true — both must
# trigger substitution for a moderated role (filename alone is not enough; a tagged
# scene that isn't renamed would otherwise leak raw to a safe model).
_emit_target() {
  local role="$1" path="$2" moderated=1 syn=""
  is_moderated_role "$role" || moderated=0
  if [ "$moderated" -eq 0 ]; then
    # unmoderated (grok): explicit is its job — show everything, labelled if explicit.
    if is_explicit_file "$path"; then
      _emit_file "$path" "${path#"$ROOT"/} (EXPLICIT — unmoderated role)"
    else
      _emit_file "$path" "${path#"$ROOT"/}"
    fi
    return 0
  fi
  if is_explicit_file "$path" || file_is_nsfw_tagged "$path"; then
    case "$path" in
      *.explicit.md) syn="${path%.explicit.md}.synopsis.md";;
      *.md)          syn="${path%.md}.synopsis.md";;
    esac
    if [ -n "$syn" ] && [ -f "$syn" ]; then
      _emit_file "$syn" "${syn#"$ROOT"/} (SFW synopsis substituted for explicit/nsfw scene)"
    else
      _emit_file_placeholder "$path" "explicit/nsfw scene with no .synopsis.md; nothing safe to show this model"
    fi
  else
    _emit_file "$path" "${path#"$ROOT"/}"
  fi
}

# assemble_bible <role> — emit ONLY the codex/ story bible (no targets).
# This is the byte-identical CACHE PREFIX: for a given moderation class it is the same
# bytes on every call, so the prefix caches on all five lanes (Claude 5-min server cache,
# DeepSeek/Codex/Grok auto prefix cache) hit across repeated lane calls instead of paying
# full input price each time. Keep it stable & front-loaded — any per-call variation above
# it kills the hit. (Stage 1.5 — see DEVLOG ▶ FORWARD PLAN.)
assemble_bible() {
  local role="$1"
  printf '===== STORY BIBLE (codex/) =====\n'
  _emit_codex "$role"
}

# assemble_targets <role> <target-path> [...] — emit ONLY the (variable) target material,
# firewalled per role. Goes at the END of a prompt, after the cached prefix. No-op with
# no targets.
assemble_targets() {
  local role="$1"; shift
  [ "$#" -gt 0 ] || return 0
  printf '===== TARGET MATERIAL =====\n'
  local t
  for t in "$@"; do _emit_target "$role" "$t"; done
}

# assemble_context <role> [targets...] — backward-compatible wrapper: bible + targets
# together (the original behavior). New callers wanting cache hits should instead emit
# assemble_prefix first and append assemble_targets last.
assemble_context() {
  local role="$1"; shift
  assemble_bible "$role"
  if [ "$#" -gt 0 ]; then
    printf '\n'
    assemble_targets "$role" "$@"
  fi
}

# Constant fence marking the end of the cacheable prefix. Must stay byte-stable.
CACHE_PREFIX_DELIM='════════ end of shared context (cached) — your specific task follows ════════'

# Fixed, role-agnostic output contract. Part of the cache prefix, so it must NOT vary
# per call. Per-task specifics go in the variable suffix after the delimiter.
_OUTPUT_CONTRACT='## Output contract (applies to whatever task follows)
- Stay SFW. Cite the codex/ file behind any story fact; if it is not in the bible, say "not in the bible" — do not invent canon.
- Stay in the author'\''s voice (AGENTS.md §4 style guide + the relevant character card). Propose, do not overwrite the author'\''s prose.
- Lead with a one-paragraph rationale, then your contribution as Markdown.'

# assemble_prefix <role> — the canonical BYTE-IDENTICAL cache prefix every lane call leads
# with: house rules (AGENTS.md, incl. the §4 style guide) → story bible → output contract →
# a constant delimiter. Identical across roles within a moderation class ⇒ cross-call /
# cross-step prefix-cache hits. Append only variable task text (via assemble_targets +
# the instruction) AFTER this.
assemble_prefix() {
  local role="$1"
  printf '## House rules (AGENTS.md)\n'
  cat "$ROOT/AGENTS.md"
  printf '\n\n'
  assemble_bible "$role"
  printf '\n%s\n\n%s\n\n' "$_OUTPUT_CONTRACT" "$CACHE_PREFIX_DELIM"
}
