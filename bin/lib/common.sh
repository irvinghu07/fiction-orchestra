#!/usr/bin/env bash
# common.sh — shared helpers, repo root, and the model-routing / firewall policy.
# Sourced by every bin/ entry script. No side effects beyond defining vars/functions.

set -euo pipefail

# --- repo root (this file lives at $ROOT/bin/lib/common.sh) ---
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$_LIB_DIR/../.." && pwd)"
export ROOT

# --- pretty output ---
if [ -t 2 ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLU=$'\033[34m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
  C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_DIM=''; C_RST=''
fi
log()  { printf '%s\n' "$*" >&2; }
info() { printf '%s%s%s\n' "$C_BLU" "$*" "$C_RST" >&2; }
ok()   { printf '%s%s%s\n' "$C_GRN" "$*" "$C_RST" >&2; }
warn() { printf '%s%s%s\n' "$C_YEL" "$*" "$C_RST" >&2; }
die()  { printf '%s%s%s\n' "$C_RED" "ERROR: $*" "$C_RST" >&2; exit 1; }

# --- NSFW firewall policy -----------------------------------------------------
# Explicit prose lives in *.explicit.md and MUST contain this marker on its first
# non-empty line. The leak guard greps for it; context.sh substitutes synopses.
NSFW_MARKER='<!-- NSFW:EXPLICIT'
# Optional newline-separated denylist of terms that must never reach a moderated
# model (belt-and-suspenders alongside file-provenance gating).
NSFW_DENYLIST="$ROOT/orchestration/nsfw-denylist.txt"

# is_explicit_file PATH -> 0 if the path is an explicit-tier file.
# Case-INSENSITIVE: macOS filesystems are case-insensitive, so S02.Explicit.MD must
# be recognised exactly like s02.explicit.md or it would bypass the prompt firewall.
is_explicit_file() {
  case "$1" in *.[Ee][Xx][Pp][Ll][Ii][Cc][Ii][Tt].[Mm][Dd]) return 0;; *) return 1;; esac
}

# file_is_nsfw_tagged PATH -> 0 if the file's YAML frontmatter contains nsfw: true.
# Robust to leading blank lines and HTML comments BEFORE the opening `---` fence
# (every codex file starts with a `<!-- … -->` comment, which the old check tripped
# over — silently treating tagged files as SFW). Matches an indented key too.
file_is_nsfw_tagged() {
  [ -f "$1" ] || return 1
  awk '
    infm==0 {
      if (incomment) { if ($0 ~ /-->/) incomment=0; next }
      if ($0 ~ /^[[:space:]]*$/) next
      if ($0 ~ /^[[:space:]]*<!--/) { if ($0 !~ /-->/) incomment=1; next }
      if ($0 ~ /^---[[:space:]]*$/) { infm=1; next }
      exit 1   # real content before any frontmatter fence -> no frontmatter, not tagged
    }
    {
      if ($0 ~ /^---[[:space:]]*$/) exit 1   # end of frontmatter, nsfw:true not found
      if (tolower($0) ~ /^[[:space:]]*nsfw:[[:space:]]*true/) exit 0
      next
    }
  ' "$1"
}

# --- model routing ------------------------------------------------------------
# role -> model. Roles are stable names workflows pass in.
resolve_model() {
  case "$1" in
    prose|voice|audit)        echo claude ;;
    conduct)                  echo claude ;;  # host-side Sonnet/Opus conductor (orchestrates the others)
    continuity)               echo agy ;;     # Gemini via Antigravity CLI
    structure|outline)        echo codex ;;
    cnprose)                  echo kimi ;;     # Kimi K2.6 — 简体中文 signature prose (MODERATED/SFW lane, leak-guarded)
    brainstorm|inspire|nsfw)  echo grok ;;
    bulk)                     echo deepseek ;;
    *) die "unknown role: $1" ;;
  esac
}

# A model is "moderated" (must never receive explicit content) unless it's grok.
# grok is the sole NSFW-capable model (user-verified).
is_moderated_model() { case "$1" in grok) return 1 ;; *) return 0 ;; esac; }
is_moderated_role()  { is_moderated_model "$(resolve_model "$1")"; }

# Human-readable lane label for a role (used in prompts/output headers).
role_label() {
  case "$1" in
    prose|voice|audit) echo "Claude (prose/voice/audit)";;
    conduct)           echo "Claude (conductor)";;
    continuity)        echo "Gemini via agy (continuity)";;
    structure|outline) echo "Codex/GPT (structure)";;
    cnprose)           echo "Kimi K2.6 (简体中文 prose)";;
    brainstorm|inspire)echo "Grok (brainstorm)";;
    nsfw)              echo "Grok (NSFW writer)";;
    bulk)              echo "DeepSeek (SFW bulk)";;
    *) echo "$1";;
  esac
}

# short id for draft filenames (no Math.random restriction here — host bash)
short_id() { date +%Y%m%d-%H%M%S; }

# slugify a string for filenames
slugify() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's#[^a-z0-9]+#-#g; s#^-+|-+$##g' | cut -c1-48; }
