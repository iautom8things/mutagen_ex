#!/usr/bin/env bash
# Normalize Grok hook payloads to the Claude-shaped stdin expected by shared
# hook scripts, then translate the shared hook result back to Grok decision JSON.

set -uo pipefail

usage() {
  echo "usage: $0 <shared-hook-script> [args...]" >&2
}

if [ "$#" -lt 1 ]; then
  usage
  exit 64
fi

hook_script="$1"
shift

if [ ! -x "$hook_script" ]; then
  echo "grok-hook-adapter: hook script is not executable: $hook_script" >&2
  exit 64
fi

input="$(cat)"

if [ -z "$input" ]; then
  input="{}"
fi

if ! normalized="$(
  printf '%s' "$input" | jq -c '
    def tool_name:
      (.toolName // .tool_name // "") as $name
      | if $name == "run_terminal_command" then "Bash"
        elif $name == "search_replace" then "Edit"
        elif $name == "write" or $name == "write_file" then "Write"
        elif $name == "read_file" then "Read"
        elif $name == "skill" then "Skill"
        else $name
        end;

    def tool_input:
      (.toolInput // .tool_input // {}) as $ti
      | if (($ti.file_path // "") == "") and (($ti.target_file // "") != "") then
          $ti + {file_path: $ti.target_file}
        else
          $ti
        end;

    . + {
      hook_event_name: (.hookEventName // .hook_event_name // ""),
      session_id: (.sessionId // .session_id // ""),
      tool_name: tool_name,
      tool_input: tool_input,
      tool_use_id: (.toolUseId // .tool_use_id // ""),
      cwd: (.cwd // .workspaceRoot // "")
    }
  ' 2>/dev/null
)"; then
  echo '{"decision":"allow"}'
  exit 0
fi

stdout_file="$(mktemp "${TMPDIR:-/tmp}/grok-hook-adapter-stdout.XXXXXX")"
stderr_file="$(mktemp "${TMPDIR:-/tmp}/grok-hook-adapter-stderr.XXXXXX")"
trap 'rm -f "$stdout_file" "$stderr_file"' EXIT

hook_status=0
printf '%s' "$normalized" | "$hook_script" "$@" >"$stdout_file" 2>"$stderr_file" || hook_status=$?

stdout="$(cat "$stdout_file")"
stderr="$(cat "$stderr_file")"

if [ "$hook_status" -eq 2 ]; then
  reason="$stderr"
  if [ -z "$reason" ]; then
    reason="$stdout"
  fi
  if [ -z "$reason" ]; then
    reason="Hook denied the tool call."
  fi
  jq -cn --arg reason "$reason" '{decision:"deny", reason:$reason}'
  exit 0
fi

if [ "$hook_status" -ne 0 ]; then
  echo '{"decision":"allow"}'
  exit 0
fi

if [ -z "$stdout" ]; then
  echo '{"decision":"allow"}'
  exit 0
fi

if printf '%s' "$stdout" | jq -e 'type == "object" and (.decision == "allow" or .decision == "deny")' >/dev/null 2>&1; then
  printf '%s' "$stdout" | jq -c 'del(.hookSpecificOutput.additionalContext)'
  exit 0
fi

echo '{"decision":"allow"}'
