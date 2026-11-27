#!/usr/bin/env bash
# agent-rules: generated v0.29.5
# SessionEnd/SessionStart hook: prune rule-injection marker directories.
#
# Reads the hook payload from stdin (JSON), extracts session_id/sessionId, and
# removes ${XDG_CACHE_HOME:-$HOME/.cache}/agent-rules/<agent>/<session_id>/.
# Grok headless sessions do not reliably fire SessionEnd, so Grok also prunes
# old session directories on SessionStart.
#
# Claude and Codex no longer register this as their primary cache-cleanup
# hook — the age-based `prune-rules-cache` SessionStart hook owns that job for
# both. This script stays installed so repos with an older, not-yet-resynced
# SessionEnd registration keep working exactly as before.

set -euo pipefail

input="$(cat || true)"
clean_id="$(printf '%s' "$input" | jq -rs '
  if length == 1 then
    .[0] | (.session_id // .sessionId) | strings | gsub("[^A-Za-z0-9._-]+"; "_") | .[:128]
  else empty end
' 2>/dev/null || true)"
case "$clean_id" in
  ""|.|..) exit 0 ;;
esac
event_name="$(printf '%s' "$input" | jq -r '.hook_event_name // .hookEventName // empty' 2>/dev/null || true)"
agent="${AGENT_RULES_AGENT:-}"

if [ -z "$agent" ]; then
  if [ -n "${GROK_AGENT:-}" ] || [ -n "${GROK_SESSION_ID:-}" ]; then
    agent="grok"
  else
    agent="claude"
  fi
fi

case "$agent" in
  claude|codex|grok) ;;
  *) agent="claude" ;;
esac

marker_root="${XDG_CACHE_HOME:-${HOME:+$HOME/.cache}}"
[ -n "$marker_root" ] || exit 0
marker_root="$marker_root/agent-rules"
cache_root="$marker_root/$agent"
[ ! -L "$marker_root" ] && [ ! -L "$cache_root" ] || exit 0

case "$event_name" in
  SessionStart|session_start|new|resume)
    if [ "$agent" = "grok" ] && [ -d "$cache_root" ]; then
      find "$cache_root" -mindepth 1 -maxdepth 1 -type d ! -name "$clean_id" -exec rm -rf -- {} +
    fi
    ;;
  *)
    session_dir="$cache_root/$clean_id"
    if [ -L "$session_dir" ]; then
      rm -f -- "$session_dir"
    else
      rm -rf -- "$session_dir"
    fi
    ;;
esac

exit 0
