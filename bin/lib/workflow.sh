#!/usr/bin/env bash
# workflow.sh — shared harness for the four author workflows. Builds a role-shaped
# prompt (house rules + firewalled story context + task), dispatches via run_model,
# and saves the result into drafts/ (never manuscript/).
#
# do_workflow <workflow> <role> <slug> <instruction> <target-path>...

do_workflow() {
  local wf="$1" role="$2" slug="$3" instruction="$4"; shift 4
  local tmp draft; tmp="$(mktemp)"
  {
    # CACHED PREFIX FIRST (byte-identical per moderation class): house rules + bible +
    # output contract. Then the variable suffix (role/workflow, target material, task).
    assemble_prefix "$role"
    printf '# Role: %s — Workflow: %s\n' "$(role_label "$role")" "$wf"
    printf 'You are a collaborator in a human novelist'"'"'s git-based manuscript repo.\n\n'
    if [ "$#" -gt 0 ]; then
      printf '## Target material\n'
      assemble_targets "$role" "$@"
      printf '\n'
    fi
    printf '## Your task\n%s\n' "$instruction"
  } > "$tmp"

  draft="$ROOT/drafts/${wf}-${slug}-$(short_id).md"
  info "Assembling firewalled context for $(role_label "$role")…"
  {
    printf -- '---\nworkflow: %s\nrole: %s (%s)\ntargets: %s\ngenerated: %s\n---\n\n' \
      "$wf" "$role" "$(role_label "$role")" "$*" "$(date '+%Y-%m-%d %H:%M:%S')"
    run_model "$role" "$tmp"
  } > "$draft"
  rm -f "$tmp"
  ok "Draft written → ${draft#"$ROOT"/}"
  printf '%s\n' "$draft"
}

# load the lib bundle (call from each entry script's directory)
load_libs() {
  local d="$1"
  . "$d/lib/common.sh"; . "$d/lib/context.sh"; . "$d/lib/run-model.sh"; . "$d/lib/workflow.sh"
}
