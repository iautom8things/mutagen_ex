#!/usr/bin/env python3
# agent-rules: generated v0.29.5
"""Inject matching .claude/rules/*.md and .claude/dynamic-rules/*.md files into
agent context once per session.

Wired as a PreToolUse hook matched on Edit|Write|MultiEdit|Bash|apply_patch.
Reads the hook payload from stdin, iterates this repo's
.claude/rules/*.md and .claude/dynamic-rules/*.md files, and emits any whose
frontmatter matches the tool call.

Two source directories are scanned, same frontmatter and matching rules for
both:

    .claude/rules/          Also auto-loaded in full by Claude Code's native
                             CLAUDE.md loader when a rule has no `paths:`
                             field (see Claude Code docs on `.claude/rules/`).
                             Fine for rules you want in context every session
                             regardless of this hook, or whose `paths:` gating
                             should also be enforced natively.
    .claude/dynamic-rules/  Invisible to Claude Code's native loader — only
                             this hook reads it. Required for any rule gated
                             by `match_command:`, since native Claude Code has
                             no concept of command matching and would load a
                             match_command-only rule unconditionally every
                             session if it lived in .claude/rules/ instead.
                             Also holds `write_only: true` paths-gated rules:
                             writing conventions that shouldn't pay native
                             read-triggered loading.

Deny-once guarantee: a paths-gated rule living in .claude/dynamic-rules/ has no
native read surface, so without intervention its content would arrive only
AFTER the first matching write executed (PreToolUse additionalContext is
delivered with the tool result — the tool call it intercepts was already
authored). To guarantee the conventions land BEFORE the first write, a
path-mode match on a dynamic-rules rule DENIES that one tool call, carrying the
rule content in permissionDecisionReason with framing that tells the agent to
re-attempt the write. The dedup marker is written at deny time, so the
reattempt matches nothing and proceeds. One deny per rule body per agent
context. Claude's Edit/MultiEdit and Codex's apply_patch are always denied this
way. Claude's Write follows AGENT_RULES_WRITE_DELIVERY: `context` (the default
since evals/write-delivery-outcome.sh passed, decision
write_delivery_outcome_gated) lets the write land and returns the rule as
additionalContext that tells the agent to check the file it just wrote and fix
it with a follow-up edit; `deny` denies the same way as Edit. A dynamic path rule with `deny: always` denies
every matching write, Write included, with a one-line reminder after the first.
Path matches on rules in .claude/rules/ are not sent to Claude, because its
native loader delivers them on the Read that precedes an edit, except on a
Write that creates a new file, which has no such Read. Codex and Grok still get
them as additionalContext. Grok sessions never deny (the Grok adapter
has no deny contract). AGY has no native loader. A Read receives matching
.claude/rules/ advice and skips .claude/dynamic-rules/. A write can trigger a
dynamic path denial.

Command gates: `deny_command:` patterns mark a Bash command as itself being the
mistake — a match DENIES the command with the rule body as the reason.
`deny: once` (default) educates then stands down for the session. Its deny says
the same command will not be blocked again: re-run it unchanged when the rule
says it is right where the agent is, otherwise use the alternative the rule
names. `deny: always` blocks every match, with a short reminder after the
first, framed as "use the sanctioned alternative; do not retry as-is; rephrase
if the match is incidental." When gates of both strengths match one command,
the always framing wins, because the command stays blocked. Claude and
Codex both honor the deny (codex-cli's PreToolUse `permissionDecision: "deny"`
contract, proven live by evals/codex-deny-probe.sh); Grok gets the rule as
plain context. Pi honors the same denials on commands and writes, and gets
advice for Read matches from .claude/rules/. Plain `match_command:` matches are
never denied — their context arrives with the tool result, after the command ran.

Three surfaces are supported:

    Read/Edit/Write/MultiEdit -> match against `tool_input.file_path`
                            via `paths:` globs and optional `match_content:` regex.
    Bash                 -> match against `tool_input.command`
                            via `deny_command:` (checked first) or
                            `match_command:` regex (Python re, multiline).
    apply_patch          -> extract patch header paths from `tool_input.command`
                            and match them as path-mode edits. `match_content`
                            sees each file's on-disk text plus that file's own
                            added lines (`+` lines of an Update, every line of
                            an Add), so a patch that introduces a construct
                            matches on that call.

Each rule body is injected at most once per agent context across all
surfaces. Marker files at
${XDG_CACHE_HOME:-$HOME/.cache}/agent-rules/<agent>/<session_id>/<context>/<rule_name>-<body_hash>
track state across hook firings within a session; <agent> is `claude`, `codex`,
`grok`, `agy`, or `pi` and defaults to `claude`. AGY uses its `conversationId` as
the session and its optional `agentId` for the context. <context> is
`agent-<agent_id>` when the payload carries an `agent_id` (Claude sets it inside
a subagent, Codex for a child thread), else `main`, so a subagent gets its own
delivery. <body_hash> is the
first 12 hex digits of sha256(rule body): the same body is not re-sent when the
agent moves between linked worktrees, and a body that differs (another branch,
other rendered vars) is. If a marker cannot be written, a one-time denial is
delivered as advice and can be delivered again on the next matching call.
The companion prune-rules-cache hook
resets the context's markers when it compacts or clears, so rules
come back after the summary drops them. It also removes stale session directories
by age on every SessionStart. Repos still registered on the older SessionEnd
path keep clear-rules-cache.sh as a non-destructive compatibility hook.

Frontmatter schema (YAML between leading --- lines):

    description: Human-readable summary.
    paths:                    # optional. globs. paired with file_path tools.
      - "lib/**/*.ex"
    match_content:            # optional. regex. file must match >=1 (path-mode only).
      - "use Builder\\\\.Schema"
      - "^\\\\s*schema \\""
    match_command:            # optional. regex. matched against Bash tool_input.command.
      - "git\\\\s+worktree\\\\s+remove"
    deny_command:             # optional. regex. a matching Bash command is DENIED,
      - "..."                 # with the rule body as the deny reason — for commands
                              # that are themselves the mistake. Anchor patterns to
                              # command position to limit false matches.
    deny: once | always       # optional. deny strength for command deny gates and
                              # dynamic-rules path rules. "once" (default) blocks
                              # the first match then stands down for the agent
                              # context; "always" blocks every match.
    requires_executable:      # optional. names that must be on PATH. When one is
      - docker                # missing the rule is inert on this host: no context,
                              # no deny. For rules about a tool the host lacks, such
                              # as a Compose stack inside a container with no docker
                              # (a Forge task), whose sanctioned mix is the host's.
    skip_in_lane: true        # optional. inert (no context, no deny) in a
                              # /speedy-epic lane: a worktree whose git dir holds
                              # the `lane-epic` marker `scripts/lane new` writes.
                              # For compose rules, since a lane runs host mix.
    deny_gate_args_none:      # optional. a deny gate denies only when NONE of
      - --dry-run             # these patterns matches an arg token, so a
                              # read-only form of a gated command still runs.
                              # A `--no-dry-run` in the same command cancels it.
    write_only: true          # optional. not read by this hook — tells
                              # sync-agent-rules to install the rule under
                              # .claude/dynamic-rules/ (write-triggered only).

A rule with none of `paths:`, `match_command:`, or `deny_command:` is never
auto-injected — useful for workflow rules loaded via CLAUDE.md references.

Stdout is the hook's contract surface. Exit 0 with empty stdout means "no rules
matched, continue silently." Errors go to stderr and exit 0 so the hook never
blocks tool calls; missing inputs are treated as no-op.

With --defer-markers, stdout carries advisories [{marker_path, body}] and
an optional denial {reason, marker_paths, always, once_advisories}. The caller
checks that it can commit the one-time denial markers before emitting a denial
and can use once_advisories for any markers it cannot commit. An always denial
applies regardless of marker availability. The caller commits delivery markers
after flushing their respective output to the client.
"""
from __future__ import annotations

import fnmatch
import hashlib
import json
import os
import re
import shlex
import shutil
import stat
import sys
from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
from typing import NamedTuple

# Isolated Python does not add the script directory to sys.path.
_agent_spec = spec_from_file_location(
    "agent_rules_agents", Path(__file__).resolve().with_name("agent_rules_agents.py")
)
assert _agent_spec is not None and _agent_spec.loader is not None
agents = module_from_spec(_agent_spec)
_write_bytecode = sys.dont_write_bytecode
try:
    sys.dont_write_bytecode = True
    _agent_spec.loader.exec_module(agents)
finally:
    sys.dont_write_bytecode = _write_bytecode

AGENT_CLAUDE = agents.AGENT_CLAUDE
AGENT_CODEX = agents.AGENT_CODEX
AGENT_GROK = agents.AGENT_GROK
AGENT_AGY = agents.AGENT_AGY
AGENT_PI = agents.AGENT_PI
DEFAULT_AGENT = agents.DEFAULT_AGENT
SUPPORTED_AGENTS = agents.SUPPORTED_AGENTS
detect_agent = agents.detect_agent
PATCH_PATH_RE = re.compile(r"^\*\*\* (Add File|Update File|Delete File|Move to):\s*(.+?)\s*$")


class ToolPath(NamedTuple):
    file_path: str  # file whose on-disk text match_content reads
    rel_path: str  # repo-relative path the `paths:` globs match
    pending_content: str = ""
    deleted: bool = False  # an apply_patch `Delete File:` path


class PatchPath(NamedTuple):
    path: Path
    # The write's pending text for this file: Write content, Edit new_string,
    # or the file's added lines in an apply_patch.
    pending_content: str = ""
    # On-disk file holding the current text; differs from `path` only for an
    # apply_patch `Move to:` target, whose text still lives at the source.
    content_path: Path | None = None
    # An apply_patch `Delete File:` path: it writes nothing, so it never takes
    # the pre-write deny (Claude deletes through rm, which is never path-matched).
    deleted: bool = False


class RuleTarget(NamedTuple):
    paths: list[ToolPath]
    command: str = ""
    worktree_commands: dict[str, list[list[str]]] | None = None
    worktree_only: bool = False


WORKTREE_ADD_RULE = "worktree-add"
WORKTREE_CLEANUP_RULE = "worktree-cleanup"
WORKTREE_OPERATION_RULES = {
    "add": WORKTREE_ADD_RULE,
    "remove": WORKTREE_CLEANUP_RULE,
    "prune": WORKTREE_CLEANUP_RULE,
}


# Shell operator tokens (boundaries between simple commands). A token is an
# operator when every character is one of these; covers && || | ; & ( ).
_OPERATOR_CHARS = set("|&;()")
# Redirection ops whose following filename token is skipped for gate matching.
_REDIRECT_OPS = frozenset({"<", ">", ">>"})
# Shell reserved words stripped at command position so the simple command they
# prefix (if/while conditions, then/do bodies) still reaches gate evaluation.
_RESERVED_WORDS = frozenset(
    {"if", "then", "elif", "else", "fi", "do", "done", "while", "until", "for", "!", "{", "}"}
)
# Wrappers popped (with leading flags) before gate evaluation on argv[0].
_WRAPPER_COMMANDS = frozenset(
    {"command", "env", "sudo", "nohup", "nice", "stdbuf", "time", "timeout"}
)
# Wrapper flags that consume the following token as a value (space-separated
# form only; attached forms like -n10 / -o0 are popped by the plain flag loop).
_WRAPPER_VALUE_FLAGS = {
    "nice": frozenset({"-n", "--adjustment"}),
    "timeout": frozenset({"-s", "--signal", "-k", "--kill-after"}),
    "sudo": frozenset({"-u", "-g", "-p", "-h"}),
}
# Leading VAR=value assignments dropped before gate evaluation.
_VAR_ASSIGN_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
# Heredoc openers: <<, <<-, <<~ with optional quoted/bare delimiter.
_HEREDOC_RE = re.compile(
    r"""<<([-~]?)[ \t]*(?:'([^'\n]*)'|"([^"\n]*)"|\\?(\S+))"""
)

DENY_FRAMING_WRITE = (
    "This tool call was intentionally blocked ONE TIME by the agent-rules hook, "
    "only so that the project rules below reach you BEFORE the write lands. "
    "This is NOT a permission problem, and the same write will NOT be blocked "
    "again this session. Review the rules, adjust your change if needed, and "
    "then re-attempt the write."
)

# A `deny: once` command gate stands down after this deny, so the framing
# invites a clean retry, the way DENY_FRAMING_WRITE does for writes.
DENY_FRAMING_COMMAND_ONCE = (
    "This command was intentionally blocked ONE TIME by the agent-rules hook, "
    "only so that the project rule below reaches you BEFORE the command runs. "
    "This is NOT a permission problem, and the same command will NOT be blocked "
    "again this session. Read the rule: if it says this command is right where "
    "you are, re-run it unchanged; otherwise use the alternative the rule names."
)

# A `deny: always` command gate blocks every match, so a retry fails again.
DENY_FRAMING_COMMAND = (
    "This command was blocked by a project rule gate — the command itself is "
    "the mistake the rule exists to prevent. Read the rule below and use the "
    "sanctioned alternative instead; do NOT retry the command as-is. If the "
    "matched pattern appears only incidentally (e.g. inside a quoted string or "
    "commit message), rephrase the command so the pattern does not appear."
)

DENY_FRAMING_PATH_ALWAYS = (
    "This write was blocked by a project rule that blocks every write to this "
    "file — writing it is the mistake the rule exists to prevent. Read the rule "
    "below and do what it says instead; do NOT retry the write."
)

# Claude Write delivery: `context` (the shipped default) or `deny`. The default
# moved to `context` when evals/write-delivery-outcome.sh passed on 2026-10-16
# (decision write_delivery_outcome_gated); `deny` is the kill switch.
WRITE_DELIVERY_ENV = "AGENT_RULES_WRITE_DELIVERY"
WRITE_DELIVERY_DENY = "deny"
WRITE_DELIVERY_CONTEXT = "context"
DEFAULT_WRITE_DELIVERY = WRITE_DELIVERY_CONTEXT

CONTEXT_FRAMING_WRITE = (
    "These conventions apply to the file you just wrote; check it and fix it "
    "with a follow-up edit if needed."
)

def pending_write_content(tool_name: str, tool_input: dict) -> str:
    """Return the pending write body that match_content must inspect.

    Write carries the full file in `content`. Edit carries the replacement in
    `new_string`. MultiEdit carries one `new_string` per `edits[]` entry — join
    them so a content-gated rule fires when any edit introduces the construct.
    """
    if tool_name == "Write":
        return tool_input.get("content", "") or ""
    if tool_name == "Edit":
        return tool_input.get("new_string", "") or ""
    if tool_name == "MultiEdit":
        edits = tool_input.get("edits") or []
        parts: list[str] = []
        for edit in edits:
            if isinstance(edit, dict):
                piece = edit.get("new_string", "") or ""
                if piece:
                    parts.append(piece)
        return "\n".join(parts)
    return ""


def hook_output(
    injected_blocks: list[str],
    repeat_deny_lines: list[str],
    deny_worthy: bool,
    deny_framing: str,
    context_framing: str = "",
) -> dict:
    """Pack already-collected rule blocks into a hook response.

    `context_framing`, when set, leads the additionalContext of a call that is
    not denied (a Claude Write under AGENT_RULES_WRITE_DELIVERY=context).
    """
    if not injected_blocks and not repeat_deny_lines:
        return {}
    combined = "\n\n".join(repeat_deny_lines + injected_blocks)
    if deny_worthy:
        output = {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": deny_framing + "\n\n" + combined,
            }
        }
    else:
        if context_framing:
            combined = context_framing + "\n\n" + combined
        output = {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "additionalContext": combined,
            }
        }
    return output


def main(*, defer_markers: bool = False) -> int:
    try:
        payload = json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        print(f"inject-rules: invalid hook payload: {exc}", file=sys.stderr)
        return 0
    if not isinstance(payload, dict):
        print("inject-rules: invalid hook payload: not a JSON object", file=sys.stderr)
        return 0

    output = evaluate(payload, defer_markers=defer_markers)
    if output:
        json.dump(output, sys.stdout)
    return 0


def payload_dir(payload: dict) -> Path:
    cwd = payload.get("cwd") or payload.get("workspaceRoot")
    if isinstance(cwd, str) and Path(cwd).is_dir():
        return Path(cwd).resolve()
    return Path.cwd().resolve()


def tool_call(payload: dict) -> tuple[str, dict]:
    name = normalize_tool_name(payload.get("tool_name") or payload.get("toolName") or "")
    args = payload.get("tool_input") or payload.get("toolInput") or {}
    return name, args if isinstance(args, dict) else {}


def rule_targets(payload: dict, tool_name: str, tool_input: dict) -> dict[Path, RuleTarget]:
    cwd = payload_dir(payload)
    command = tool_input.get("command") if tool_name == "Bash" else None
    if isinstance(command, str) and command:
        workdir = tool_input.get("workdir")
        if isinstance(workdir, str) and workdir:
            cwd = resolve_tool_path(workdir, str(cwd))
        root = find_repo_root(cwd)
        targets = {root: RuleTarget([], command)} if root else {}
        if "worktree" in command:
            for repo, commands in worktree_command_targets(payload, command, cwd, root).items():
                targets[repo] = RuleTarget([], command, commands, worktree_only=repo != root)
        return targets

    paths_by_repo: dict[Path, list[ToolPath]] = {}
    # Each file's new lines and optional move source stay with that file.
    for candidate in tool_path_candidates(tool_name, tool_input, str(cwd)):
        if repo := find_repo_root(candidate.path.parent):
            if tool_path := path_relative_to_repo(candidate, repo):
                paths_by_repo.setdefault(repo, []).append(tool_path)
    return {repo: RuleTarget(paths) for repo, paths in paths_by_repo.items()}


def rule_files(repo: Path, agent: str, tool_name: str) -> list[Path]:
    directories = [repo / ".claude" / "rules"]
    if tool_name != "Read" or agent not in (AGENT_AGY, AGENT_PI):
        directories.append(repo / ".claude" / "dynamic-rules")
    return [f for directory in directories for f in sorted(directory.glob("*.md"))
            if f.name != "README.md"]


def evaluate(
    payload: dict,
    *,
    targets: dict[Path, RuleTarget] | None = None,
    native_repo: Path | None = None,
    defer_markers: bool = False,
) -> dict:
    agent = detect_agent(payload)
    session_id = agents.session_id(payload, agent)
    if not session_id:
        return {}

    tool_name, tool_input = tool_call(payload)
    if targets is None:
        targets = rule_targets(payload, tool_name, tool_input)
        project_dir = os.environ.get("CLAUDE_PROJECT_DIR")
        native_repo = find_repo_root(Path(project_dir) if project_dir else payload_dir(payload))

    rules = [
        (repo, target, rule_file)
        for repo, target in targets.items()
        for rule_file in rule_files(repo, agent, tool_name)
        if not target.worktree_only or rule_file.stem in (target.worktree_commands or {})
    ]
    if not rules:
        return {}

    cache_dir = marker_dir(payload, agent, session_id)
    cache_ready = False
    if not defer_markers:
        try:
            cache_dir.mkdir(parents=True, exist_ok=True)
            cache_ready = True
        except OSError as exc:
            print(f"inject-rules: cache unavailable: {exc}", file=sys.stderr)

    injected_blocks: list[str] = []
    advisories: list[dict[str, str]] = []
    denial_blocks: list[str] = []
    denial_marker_paths: list[str] = []
    once_advisories: list[dict[str, str]] = []
    deny_worthy = False
    always_deny = False
    deny_framing = DENY_FRAMING_WRITE
    path_always = False
    write_context = False
    repeat_deny_lines: list[str] = []
    # Shared across rules so tokenize_command runs at most once per hook fire.
    token_cache: dict = {}

    seen_markers: set[tuple[Path, bool]] = set()
    try:
        try:
            delivered_names = {marker.name.rpartition("-")[0] for marker in cache_dir.iterdir()}
        except OSError:
            delivered_names = set()

        for repo_root, target, rule_file in rules:
            rule_name = rule_file.stem

            try:
                try:
                    frontmatter, body = parse_frontmatter(rule_file)
                except FrontmatterError as exc:
                    print(f"inject-rules: {rule_file.name}: {exc}", file=sys.stderr)
                    continue

                always = deny_strength(frontmatter) == "always"
                if rule_name in delivered_names and not always:
                    marker = cache_dir / marker_name(rule_name, body)
                    if marker_delivered(marker, defer_markers=defer_markers):
                        continue

                if missing_executable(frontmatter) or skipped_in_lane(frontmatter, repo_root):
                    continue

                rule_token_cache = token_cache
                if tool_name == "Bash" and rule_name in WORKTREE_OPERATION_RULES.values():
                    commands = (target.worktree_commands or {}).get(rule_name)
                    if not commands:
                        continue
                    rule_token_cache = {"simple_commands": commands}

                matched = match_tool_call(
                    frontmatter,
                    target.paths,
                    target.command,
                    rule_name=rule_name,
                    token_cache=rule_token_cache,
                )
                if matched is None:
                    continue
                match_reason, surface = matched

                if surface == "path-delete":
                    if rule_file.parent.name == "dynamic-rules":
                        # A delete writes nothing, so a writing rule has nothing
                        # to say: no deny, no context, and the marker stays
                        # unset for the first patch that does write.
                        continue
                    surface = "path"

                if (
                    surface == "path"
                    and rule_file.parent.name == "rules"
                    and agent == AGENT_CLAUDE
                    and repo_root == native_repo
                    and (tool_name != "Write" or Path(target.paths[0].file_path).exists())
                ):
                    # Claude's native loader saw the file on the preceding Read.
                    continue

                if surface == "command-deny" and agent == AGENT_GROK:
                    # The Grok adapter has no deny contract — fall back to plain context.
                    surface = "command"

                # A dynamic-rules path rule needs pre-write delivery where the
                # agent honors denials: Claude, AGY, Pi, and Codex's apply_patch.
                path_deny = (
                    surface == "path"
                    and rule_file.parent.name == "dynamic-rules"
                    and tool_name in ("Edit", "Write", "MultiEdit", "apply_patch")
                    and (
                        agent in (AGENT_CLAUDE, AGENT_AGY, AGENT_PI)
                        or (agent == AGENT_CODEX and tool_name == "apply_patch")
                    )
                )
                command_deny = surface == "command-deny"
                blocks_every_time = always and (command_deny or path_deny)

                marker = cache_dir / marker_name(rule_name, body)
                marker_and_strength = (marker, blocks_every_time)
                if marker_and_strength in seen_markers:
                    continue
                seen_markers.add(marker_and_strength)
                if marker_delivered(marker, defer_markers=defer_markers):
                    # Already injected in this agent context. Only a deny:always
                    # gate still acts — it blocks again, with a short reminder
                    # instead of the full body.
                    if blocks_every_time:
                        deny_worthy = True
                        always_deny = True
                        target = "command"
                        if command_deny:
                            deny_framing = DENY_FRAMING_COMMAND
                        else:
                            path_always = True
                            target = "write"
                        desc = frontmatter.get("description") or ""
                        repeat_deny_lines.append(
                            f"Rule `{rule_name}` (already shown this session) blocks this "
                            f"{target} every time: {desc}".rstrip()
                        )
                    continue

                block = format_block(rule_name, match_reason, body)
                check_written_file = (
                    path_deny
                    and not always
                    and (agent, tool_name) == (AGENT_CLAUDE, "Write")
                    and write_delivery() == WRITE_DELIVERY_CONTEXT
                )
                marker_written = False
                if cache_ready:
                    try:
                        marker.touch()
                        marker_written = True
                    except OSError as exc:
                        print(
                            f"inject-rules: {rule_file.name}: cannot write cache marker: {exc}",
                            file=sys.stderr,
                        )

                # A retry can only pass a one-time gate once its marker can
                # be committed. In deferred mode the caller verifies that.
                deny_rule = blocks_every_time or (
                    (command_deny or (path_deny and not check_written_file))
                    and (defer_markers or marker_written)
                )
                if defer_markers:
                    advisory = {"marker_path": str(marker.absolute()), "body": block}
                    if deny_rule:
                        denial_blocks.append(block)
                        denial_marker_paths.append(advisory["marker_path"])
                        if not always:
                            once_advisories.append(advisory)
                    else:
                        if check_written_file:
                            advisory["body"] = CONTEXT_FRAMING_WRITE + "\n\n" + block
                        advisories.append(advisory)
                else:
                    injected_blocks.append(block)
                write_context = write_context or check_written_file
                if not deny_rule:
                    continue

                deny_worthy = True
                always_deny = always_deny or blocks_every_time
                if command_deny:
                    if always:
                        deny_framing = DENY_FRAMING_COMMAND
                    elif deny_framing != DENY_FRAMING_COMMAND:
                        # A deny:always gate on this same command keeps its
                        # framing: the command stays blocked after this deny.
                        deny_framing = DENY_FRAMING_COMMAND_ONCE
                elif always:
                    path_always = True
            except Exception as exc:
                # One bad rule must never abort siblings or change the exit code.
                print(
                    f"inject-rules: {rule_file.name}: unexpected error: {exc}",
                    file=sys.stderr,
                )
                continue
    except Exception as exc:
        # Final guard: emit anything already collected, then fail open (exit 0).
        print(f"inject-rules: unexpected error: {exc}", file=sys.stderr)

    if path_always and deny_framing == DENY_FRAMING_WRITE:
        # The "re-attempt the write" framing would be false: this write stays blocked.
        deny_framing = DENY_FRAMING_PATH_ALWAYS
    if defer_markers:
        output = {}
        if advisories:
            output["advisories"] = advisories
        if deny_worthy:
            output["denial"] = {
                "reason": deny_framing + "\n\n" + "\n\n".join(repeat_deny_lines + denial_blocks),
                "marker_paths": denial_marker_paths,
                "always": always_deny,
                "once_advisories": once_advisories,
            }
        return output
    return hook_output(
        injected_blocks,
        repeat_deny_lines,
        deny_worthy,
        deny_framing,
        CONTEXT_FRAMING_WRITE if write_context else "",
    )


def write_delivery() -> str:
    """Return how a Claude Write gets a dynamic-rules path rule: `deny` or `context`.

    Read from AGENT_RULES_WRITE_DELIVERY. Unset or empty is the shipped default;
    an unknown value warns and falls back to it (the hook stays fail-open).
    """
    value = os.environ.get(WRITE_DELIVERY_ENV, "").strip().lower()
    if not value:
        return DEFAULT_WRITE_DELIVERY
    if value in (WRITE_DELIVERY_DENY, WRITE_DELIVERY_CONTEXT):
        return value
    print(
        f"inject-rules: unsupported {WRITE_DELIVERY_ENV}={value!r}; "
        f"defaulting to {DEFAULT_WRITE_DELIVERY}",
        file=sys.stderr,
    )
    return DEFAULT_WRITE_DELIVERY


def tool_path_candidates(tool_name: str, tool_input: dict, payload_cwd: str) -> list[PatchPath]:
    """Return path candidates represented by the current tool call."""
    file_path = tool_input.get("file_path", "")
    if file_path and isinstance(file_path, str):
        path = resolve_tool_path(file_path, payload_cwd)
        return [PatchPath(path, pending_write_content(tool_name, tool_input), path)]

    if tool_name == "apply_patch":
        patch_text = tool_input.get("command", "")
        if not isinstance(patch_text, str):
            return []
        return extract_apply_patch_paths(patch_text, payload_cwd)

    return []


def resolve_tool_path(raw_path: str, payload_cwd: str) -> Path:
    path = Path(raw_path)
    if not path.is_absolute():
        base = Path(payload_cwd) if payload_cwd else Path.cwd()
        path = base / path
    return path.resolve(strict=False)


def extract_apply_patch_paths(patch_text: str, payload_cwd: str) -> list[PatchPath]:
    """Extract path candidates, each with its own added lines, from an apply_patch.

    Each `*** Add/Update/Delete File:` header opens a file section. Its pending
    content is the lines the patch adds to that file: every line of an Add
    File, the `+` lines of an Update File's hunks, nothing for a Delete File.
    A `*** Move to:` target carries its section's added lines and reads its
    on-disk text from the source path. A construct added to one file is never
    part of another file's pending content.
    """
    sections: list[dict] = []
    current: dict | None = None
    for line in patch_text.splitlines():
        match = PATCH_PATH_RE.match(line)
        if match:
            kind, raw_path = match.groups()
            if not raw_path:
                current = None
                continue
            path = resolve_tool_path(raw_path, payload_cwd)
            if kind == "Move to":
                if current is not None and current["kind"] == "Update File":
                    current["move_to"] = path
                else:
                    sections.append({"kind": kind, "path": path, "added": [], "move_to": None})
                continue
            current = {"kind": kind, "path": path, "added": [], "move_to": None}
            sections.append(current)
            continue
        if line.startswith("*** "):
            # End Patch / End of File / Begin Patch: no file content.
            if line.startswith("*** End Patch"):
                current = None
            continue
        if current is not None and current["kind"] in ("Add File", "Update File"):
            if line.startswith("+"):
                current["added"].append(line[1:])

    paths: list[PatchPath] = []
    for section in sections:
        added = "\n".join(section["added"])
        deleted = section["kind"] == "Delete File"
        paths.append(PatchPath(section["path"], added, section["path"], deleted))
        if section["move_to"] is not None:
            paths.append(PatchPath(section["move_to"], added, section["path"]))
    return paths


def path_relative_to_repo(candidate: PatchPath, repo_root: Path) -> ToolPath | None:
    try:
        rel_path = str(candidate.path.relative_to(repo_root.resolve()))
    except ValueError:
        return None
    content_path = candidate.content_path or candidate.path
    return ToolPath(str(content_path), rel_path, candidate.pending_content, candidate.deleted)


def match_tool_call(
    frontmatter: dict,
    tool_paths: list[ToolPath],
    command: str,
    *,
    rule_name: str = "?",
    token_cache: dict | None = None,
) -> tuple[str, str] | None:
    """Match the call's paths, then its command. A path that is only deleted
    matches with surface "path-delete"; a written path wins over it."""
    deletes = [p for p in tool_paths if p.deleted]
    for tool_path in [p for p in tool_paths if not p.deleted] + deletes:
        matched = match_rule(
            frontmatter,
            tool_path.file_path,
            tool_path.rel_path,
            "",
            tool_path.pending_content,
            rule_name=rule_name,
        )
        if matched is not None:
            reason, surface = matched
            if tool_path.deleted and surface == "path":
                surface = "path-delete"
            return reason, surface

    return match_rule(
        frontmatter,
        "",
        "",
        command,
        rule_name=rule_name,
        token_cache=token_cache,
    )


def missing_executable(frontmatter: dict) -> bool:
    """True when the rule names a `requires_executable:` this host's PATH lacks.

    Such a rule governs a tool that is not here, so it says nothing: no context
    and no deny. A Compose rule inside a container with no docker is the case.
    """
    names = frontmatter.get("requires_executable") or []
    if isinstance(names, str):
        names = [names]
    return any(shutil.which(str(name)) is None for name in names)


def lane_worktree(repo_root: Path) -> bool:
    """True when `repo_root` is a /speedy-epic lane: its git dir holds `lane-epic`.

    `scripts/lane new` writes the marker into the lane's private git dir, so it
    is never committed and no other worktree of the repo carries it.
    """
    directory = git_dir(repo_root)
    return directory is not None and (directory / "lane-epic").is_file()


def skipped_in_lane(frontmatter: dict, repo_root: Path) -> bool:
    """True when the rule declares `skip_in_lane: true` and `repo_root` is a lane.

    Such a rule says nothing in a lane: no context and no deny. A lane runs host
    mix by design, so the compose rule that denies host mix does not apply there.
    """
    value = frontmatter.get("skip_in_lane")
    if not isinstance(value, str) or value.strip().lower() != "true":
        return False
    return lane_worktree(repo_root)


def deny_strength(frontmatter: dict) -> str:
    """Return the deny strength for `deny_command:` gates: "once" or "always".

    "once" (the default) blocks the first matching command with the full rule
    body, then stands down for the session — educate, then trust. "always"
    blocks every matching command — for commands that are never right for an
    agent to issue directly (e.g. raw `git worktree remove`).
    """
    value = frontmatter.get("deny")
    if isinstance(value, str) and value.strip().lower() == "always":
        return "always"
    return "once"


def safe_search(pattern: str, text: str, *, rule_name: str) -> bool:
    """re.search that isolates one bad pattern from the rest of the rule.

    A pattern that fails to compile or raises re.error at search time is skipped
    with a single stderr warning naming the rule and pattern; callers treat it
    as a non-match so sibling patterns and rules still evaluate.
    """
    try:
        return re.search(pattern, text, re.MULTILINE) is not None
    except re.error as exc:
        print(
            f"inject-rules: rule `{rule_name}`: skipping invalid regex {pattern!r}: {exc}",
            file=sys.stderr,
        )
        return False


def match_rule(
    frontmatter: dict,
    file_path: str,
    rel_path: str,
    command: str,
    pending_content: str = "",
    rule_name: str = "?",
    token_cache: dict | None = None,
) -> tuple[str, str] | None:
    """Return (human-readable match reason, surface), or None if no match.

    Path-mode (Edit/Write/MultiEdit/apply_patch) and command-mode (Bash) are
    independent — a rule can opt into either or both. The first surface that
    hits wins; its reason labels the injected block and its surface ("path",
    "command", or "command-deny") drives the deny-once decision for
    dynamic-rules rules.

    `match_content` searches the on-disk text of `file_path` and
    `pending_content`, the write's pending text for this one file.

    Command-mode evaluation order (first hit wins):
      deny structured gates → legacy deny_command regexes →
      context structured gates → legacy match_command regexes.
    Tokenization is lazy and shared via `token_cache` when provided.
    """
    if rel_path:
        paths = frontmatter.get("paths") or []
        if paths and any(match_glob(g, rel_path) for g in paths):
            content_patterns = frontmatter.get("match_content") or []
            if content_patterns:
                try:
                    file_text = Path(file_path).read_text(errors="replace")
                except OSError:
                    file_text = ""
                haystacks = [t for t in (file_text, pending_content) if t]
                if any(
                    safe_search(pat, text, rule_name=rule_name)
                    for pat in content_patterns
                    for text in haystacks
                ):
                    return f"`{rel_path}`", "path"
            else:
                return f"`{rel_path}`", "path"

    if command:
        deny_gate = resolve_structured_gate(frontmatter, "deny", rule_name)
        context_gate = resolve_structured_gate(frontmatter, "context", rule_name)
        simple_commands: list[list[str]] | None = None

        def ensure_simple_commands() -> list[list[str]]:
            nonlocal simple_commands
            if simple_commands is not None:
                return simple_commands
            if token_cache is not None and "simple_commands" in token_cache:
                simple_commands = token_cache["simple_commands"]
                return simple_commands
            simple_commands = tokenize_command(command)
            if token_cache is not None:
                token_cache["simple_commands"] = simple_commands
            return simple_commands

        if deny_gate is not None:
            cmds, args_any, args_all, args_none = deny_gate
            if any_simple_command_matches(
                ensure_simple_commands(), cmds, args_any, args_all, args_none
            ):
                return (
                    format_gate_reason(command, cmds, args_any, args_all, args_none),
                    "command-deny",
                )

        deny_patterns = frontmatter.get("deny_command") or []
        if deny_patterns and any(
            safe_search(pat, command, rule_name=rule_name) for pat in deny_patterns
        ):
            return f"command `{truncate(command, 80)}`", "command-deny"

        if context_gate is not None:
            cmds, args_any, args_all, _args_none = context_gate
            if any_simple_command_matches(ensure_simple_commands(), cmds, args_any, args_all):
                return (
                    format_gate_reason(command, cmds, args_any, args_all),
                    "command",
                )

        cmd_patterns = frontmatter.get("match_command") or []
        if cmd_patterns and any(
            safe_search(pat, command, rule_name=rule_name) for pat in cmd_patterns
        ):
            return f"command `{truncate(command, 80)}`", "command"

    return None


def resolve_structured_gate(
    frontmatter: dict,
    kind: str,
    rule_name: str,
) -> tuple[list[str], list[str], list[str], list[str]] | None:
    """Return (gate_command, args_any, args_all, args_none) or None if absent/invalid.

    `kind` is "deny" or "context". Only the deny gate has an args_none key
    (`deny_gate_args_none`); the context gate's args_none is always empty.
    Args without a command list are treated as an absent gate with a single
    stderr warning (hook false-negative posture; rules-check/sync fail loud
    separately).
    """
    if kind == "deny":
        cmd_key, any_key, all_key, none_key = (
            "deny_gate_command",
            "deny_gate_args_any",
            "deny_gate_args_all",
            "deny_gate_args_none",
        )
    else:
        cmd_key, any_key, all_key, none_key = (
            "gate_command",
            "gate_args_any",
            "gate_args_all",
            None,
        )

    commands = list(frontmatter.get(cmd_key) or [])
    args_any = list(frontmatter.get(any_key) or [])
    args_all = list(frontmatter.get(all_key) or [])
    args_none = list(frontmatter.get(none_key) or []) if none_key else []

    if not commands and not args_any and not args_all and not args_none:
        return None
    if not commands:
        print(
            f"inject-rules: rule `{rule_name}`: {any_key}/{all_key} without "
            f"{cmd_key}; treating gate as absent",
            file=sys.stderr,
        )
        return None
    return commands, args_any, args_all, args_none


def format_gate_reason(
    command: str,
    commands: list[str],
    args_any: list[str],
    args_all: list[str],
    args_none: list[str] = (),
) -> str:
    """Human-readable match reason naming the structured gate that hit."""
    gate_desc = format_gate_short(commands, args_any, args_all, args_none)
    return f"command `{truncate(command, 80)}` (gate: {gate_desc})"


def format_gate_short(
    commands: list[str],
    args_any: list[str],
    args_all: list[str],
    args_none: list[str] = (),
) -> str:
    """Compact gate description for --list output (no command string)."""
    bits = list(commands)
    bits.extend(args_all)
    if args_any:
        bits.append("/".join(args_any))
    if args_none:
        bits.append("!(" + "/".join(args_none) + ")")
    return "+".join(bits) if bits else "?"


def has_structured_gates(frontmatter: dict) -> bool:
    """True when any structured gate key is present (including invalid args-only)."""
    for key in (
        "gate_command",
        "gate_args_any",
        "gate_args_all",
        "deny_gate_command",
        "deny_gate_args_any",
        "deny_gate_args_all",
        "deny_gate_args_none",
    ):
        if frontmatter.get(key):
            return True
    return False


def has_deny_surface(frontmatter: dict) -> bool:
    """True when the rule can produce a command-deny match (gate or legacy)."""
    return bool(
        frontmatter.get("deny_gate_command")
        or frontmatter.get("deny_command")
        or frontmatter.get("deny_gate_args_any")
        or frontmatter.get("deny_gate_args_all")
        or frontmatter.get("deny_gate_args_none")
    )


def has_context_surface(frontmatter: dict) -> bool:
    """True when the rule can produce a command context match (gate or legacy)."""
    return bool(
        frontmatter.get("gate_command")
        or frontmatter.get("match_command")
        or frontmatter.get("gate_args_any")
        or frontmatter.get("gate_args_all")
    )


def has_legacy_command_regexes(frontmatter: dict) -> bool:
    """True when legacy match_command / deny_command regexes are present."""
    return bool(frontmatter.get("match_command") or frontmatter.get("deny_command"))


def example_count(frontmatter: dict) -> int:
    """Total golden example commands across should_deny/match/not_match."""
    total = 0
    for key in ("should_deny", "should_match", "should_not_match"):
        val = frontmatter.get(key) or []
        if isinstance(val, list):
            total += len(val)
    return total


def classify_command(frontmatter: dict, command: str, *, rule_name: str = "?") -> str:
    """Classify a command against the rule via match_rule: deny | context | none."""
    matched = match_rule(frontmatter, "", "", command, rule_name=rule_name)
    if matched is None:
        return "none"
    _reason, surface = matched
    if surface == "command-deny":
        return "deny"
    if surface == "command":
        return "context"
    return "none"


def validate_rule_schema(frontmatter: dict, *, rule_name: str = "?") -> list[str]:
    """Return schema error strings for a rule's frontmatter (empty = valid).

    Fail-loud surface for rules-check and sync-agent-rules. Never called from
    main()/the hook path — the hook keeps false-negative posture for bad gates.

    Checks:
      - gate/deny_gate args (including deny_gate_args_none) without a
        corresponding command list
      - skip_in_lane set to anything but true/false
      - should_deny without a deny surface
      - should_match without a context surface
      - non-list or empty-string golden example entries
      - legacy match_command / deny_command / match_content patterns that fail re.compile
    """
    errors: list[str] = []
    label = f"rule `{rule_name}`"

    gate_cmds = frontmatter.get("gate_command") or []
    gate_any = frontmatter.get("gate_args_any") or []
    gate_all = frontmatter.get("gate_args_all") or []
    if (gate_any or gate_all) and not gate_cmds:
        errors.append(
            f"{label}: gate_args_any/gate_args_all without gate_command"
        )

    deny_cmds = frontmatter.get("deny_gate_command") or []
    deny_any = frontmatter.get("deny_gate_args_any") or []
    deny_all = frontmatter.get("deny_gate_args_all") or []
    deny_none = frontmatter.get("deny_gate_args_none") or []
    if (deny_any or deny_all) and not deny_cmds:
        errors.append(
            f"{label}: deny_gate_args_any/deny_gate_args_all without deny_gate_command"
        )
    if deny_none and not deny_cmds:
        errors.append(f"{label}: deny_gate_args_none without deny_gate_command")

    skip_in_lane = frontmatter.get("skip_in_lane")
    if skip_in_lane is not None and str(skip_in_lane).strip().lower() not in ("true", "false"):
        errors.append(f"{label}: skip_in_lane must be true or false, got {skip_in_lane!r}")

    should_deny = frontmatter.get("should_deny")
    if should_deny:
        if not has_deny_surface(frontmatter):
            errors.append(
                f"{label}: should_deny present but no deny surface "
                f"(deny_gate_command or deny_command)"
            )

    should_match = frontmatter.get("should_match")
    if should_match:
        if not has_context_surface(frontmatter):
            errors.append(
                f"{label}: should_match present but no context surface "
                f"(gate_command or match_command)"
            )

    for key in ("should_deny", "should_match", "should_not_match"):
        val = frontmatter.get(key)
        if val is None:
            continue
        if not isinstance(val, list):
            errors.append(f"{label}: {key} must be a YAML list, got {type(val).__name__}")
            continue
        for i, item in enumerate(val):
            if not isinstance(item, str) or not item.strip():
                errors.append(
                    f"{label}: {key}[{i}] is empty or not a string"
                )

    for key in ("match_command", "deny_command", "match_content"):
        patterns = frontmatter.get(key) or []
        if not isinstance(patterns, list):
            errors.append(f"{label}: {key} must be a list")
            continue
        for pat in patterns:
            if not isinstance(pat, str):
                errors.append(f"{label}: {key} entry is not a string: {pat!r}")
                continue
            try:
                re.compile(pat)
            except re.error as exc:
                errors.append(
                    f"{label}: {key} pattern {pat!r} fails re.compile: {exc}"
                )

    return errors


def run_golden_examples(
    frontmatter: dict,
    *,
    rule_name: str = "?",
) -> list[dict]:
    """Run should_deny / should_match / should_not_match through match_rule.

    Returns a list of result dicts:
      {
        "key": "should_deny" | "should_match" | "should_not_match",
        "command": str,
        "expected": "deny" | "context" | "none",
        "actual": "deny" | "context" | "none",
        "ok": bool,
      }

    Module-level only — never called from main(). Callers: rules-check --examples
    and sync-agent-rules cmd_adopt pre-flight.
    """
    expectations = (
        ("should_deny", "deny"),
        ("should_match", "context"),
        ("should_not_match", "none"),
    )
    results: list[dict] = []
    for key, expected in expectations:
        commands = frontmatter.get(key) or []
        if not isinstance(commands, list):
            continue
        for command in commands:
            if not isinstance(command, str):
                continue
            actual = classify_command(frontmatter, command, rule_name=rule_name)
            results.append(
                {
                    "key": key,
                    "command": command,
                    "expected": expected,
                    "actual": actual,
                    "ok": actual == expected,
                }
            )
    return results


def any_simple_command_matches(
    simple_commands: list[list[str]],
    commands: list[str],
    args_any: list[str],
    args_all: list[str],
    args_none: list[str] = (),
) -> bool:
    """True if any simple command's argv satisfies the structured gate.

    `args_none` vetoes a simple command when any of its patterns matches any
    arg token (the read-only `--dry-run` form of a gated command), unless the
    same command negates it (see args_none_vetoes).
    """
    for argv in simple_commands:
        if not argv:
            continue
        if not any(fnmatch.fnmatchcase(argv[0], pat) for pat in commands):
            continue
        arg_tokens = argv[1:]
        if args_any:
            if not any(
                any(fnmatch.fnmatchcase(tok, pat) for tok in arg_tokens)
                for pat in args_any
            ):
                continue
        if args_all:
            if not all(
                any(fnmatch.fnmatchcase(tok, pat) for tok in arg_tokens)
                for pat in args_all
            ):
                continue
        if args_none and args_none_vetoes(arg_tokens, args_none):
            continue
        return True
    return False


_NEGATION_PREFIX = "--no-"


def args_none_vetoes(arg_tokens: list[str], args_none: list[str]) -> bool:
    """True when the last args_none flag in the command is not negated after it.

    Git applies the last flag, so `git worktree prune -n --no-dry-run` runs a
    real prune (no veto, the gate denies) and `prune --no-dry-run -n` only
    reports (veto). A negation of any long-form pattern counts against every
    pattern (`-n` is `--dry-run`'s short form). A negation is `--no-<name>` for
    a `--<name>` pattern, or a prefix of it such as `--no-dry`, since git's
    option parser accepts abbreviations.
    """
    negations = [
        _NEGATION_PREFIX + pat[2:]
        for pat in args_none
        if pat.startswith("--") and not pat.startswith(_NEGATION_PREFIX) and len(pat) > 2
    ]
    vetoed = False
    for tok in arg_tokens:
        if len(tok) > len(_NEGATION_PREFIX) and tok.startswith(_NEGATION_PREFIX) and any(
            neg.startswith(tok) or fnmatch.fnmatchcase(tok, neg) for neg in negations
        ):
            vetoed = False
        elif any(fnmatch.fnmatchcase(tok, pat) for pat in args_none):
            vetoed = True
    return vetoed


def tokenize_command(command: str) -> list[list[str]]:
    """Convert a raw Bash command string into simple-command argv lists.

    Pipeline (false-negative posture — any failure returns []):
      1. Strip heredoc bodies (bodies are invisible to gates).
      2. Quote-aware: replace unquoted newlines with `;`.
      3. shlex (posix, punctuation_chars) for quote-aware tokenization.
      4. Split on shell operator tokens; skip redirection filenames.
      5. Drop leading reserved words (if/then/do/…), VAR= assignments, and
         wrapper commands (command/env/sudo/nohup/nice/stdbuf/time/timeout);
         basename argv[0].

    `bash -c "..."` inner strings are a single opaque token (not recursed).
    """
    try:
        text = strip_heredoc_bodies(command)
        text = normalize_unquoted_newlines(text)
        lexer = shlex.shlex(text, posix=True, punctuation_chars="();<>|&")
        lexer.whitespace_split = True
        raw_tokens = list(lexer)
        simple = split_simple_commands(raw_tokens)
        out: list[list[str]] = []
        for argv in simple:
            normalized = normalize_simple_command(argv)
            if normalized:
                out.append(normalized)
        return out
    except Exception:
        # ValueError (unbalanced quotes) and any unexpected parse error: gates
        # see nothing. Legacy raw regexes still run against the original string.
        return []


def strip_heredoc_bodies(text: str) -> str:
    """Remove heredoc body lines (keep the opener line; drop through delimiter).

    Multiple heredocs on one opener line are queued and consumed in order.
    `<<-` / `<<~` allow the closing delimiter to be indented with tabs.
    """
    lines = text.split("\n")
    out: list[str] = []
    i = 0
    while i < len(lines):
        line = lines[i]
        delimiters: list[tuple[str, bool]] = []
        for match in _HEREDOC_RE.finditer(line):
            dash, single, double, bare = match.group(1), match.group(2), match.group(3), match.group(4)
            delim = single if single is not None else double if double is not None else bare
            if not delim:
                continue
            strip_tabs = dash in ("-", "~")
            delimiters.append((delim, strip_tabs))
        out.append(line)
        i += 1
        for delim, strip_tabs in delimiters:
            while i < len(lines):
                body = lines[i]
                i += 1
                check = body.lstrip("\t") if strip_tabs else body
                if check == delim:
                    break
                # body line dropped
    return "\n".join(out)


def normalize_unquoted_newlines(text: str) -> str:
    """Replace unquoted newlines with `;` so multi-line scripts split.

    Tracks single quotes, double quotes, and backslash escapes (outside
    single quotes). Quoted multi-line strings stay intact as one token.
    """
    result: list[str] = []
    in_single = False
    in_double = False
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        if c == "\\" and not in_single and i + 1 < n:
            result.append(c)
            result.append(text[i + 1])
            i += 2
            continue
        if c == "'" and not in_double:
            in_single = not in_single
            result.append(c)
        elif c == '"' and not in_single:
            in_double = not in_double
            result.append(c)
        elif c == "\n" and not in_single and not in_double:
            result.append(";")
        else:
            result.append(c)
        i += 1
    return "".join(result)


def split_simple_commands(tokens: list[str]) -> list[list[str]]:
    """Split shlex tokens on shell operators; skip redirection filenames."""
    commands: list[list[str]] = []
    current: list[str] = []
    i = 0
    while i < len(tokens):
        tok = tokens[i]
        if tok and all(c in _OPERATOR_CHARS for c in tok):
            if current:
                commands.append(current)
                current = []
            i += 1
            continue
        if tok in _REDIRECT_OPS:
            i += 1
            if i < len(tokens):
                i += 1  # skip filename
            continue
        current.append(tok)
        i += 1
    if current:
        commands.append(current)
    return commands


def normalize_simple_command(argv: list[str]) -> list[str]:
    """Drop reserved-word/VAR=/wrapper prefixes; basename the effective argv[0].

    Reserved words are stripped only here — at command position — so `then git
    worktree remove x` gates on `git` while `echo do it` keeps `do` as an
    argument. Wrapper flags in `_WRAPPER_VALUE_FLAGS` consume their
    space-separated value; `timeout` additionally consumes its duration
    positional so the wrapped command lands at argv[0].
    """
    argv = list(argv)
    while True:
        while argv and argv[0] in _RESERVED_WORDS:
            argv.pop(0)
        while argv and _VAR_ASSIGN_RE.match(argv[0]):
            argv.pop(0)
        if not argv:
            return []
        head = os.path.basename(argv[0])
        if head not in _WRAPPER_COMMANDS:
            break
        wrapper = head
        argv.pop(0)
        value_flags = _WRAPPER_VALUE_FLAGS.get(wrapper, frozenset())
        while argv and argv[0].startswith("-"):
            flag = argv.pop(0)
            if flag in value_flags and argv:
                argv.pop(0)
        if wrapper == "env":
            while argv and _VAR_ASSIGN_RE.match(argv[0]):
                argv.pop(0)
        if wrapper == "timeout" and argv:
            argv.pop(0)
    if not argv:
        return []
    return [os.path.basename(argv[0]), *argv[1:]]


def normalize_tool_name(tool_name: str) -> str:
    """Map Grok tool names to the Claude names used by rule frontmatter."""
    return {
        "run_terminal_command": "Bash",
        "search_replace": "Edit",
        "write": "Write",
        "write_file": "Write",
        "skill": "Skill",
    }.get(tool_name, tool_name)


def truncate(text: str, limit: int) -> str:
    text = text.replace("\n", " ")
    if len(text) <= limit:
        return text
    return text[: limit - 1] + "…"


def find_repo_root(start: Path) -> Path | None:
    """Walk up to the containing checkout, even for a new file's parent."""
    start = start.resolve()
    for current in (start, *start.parents):
        if (current / ".git").exists():
            return current
    return None


def git_dir(repo: Path) -> Path | None:
    dot_git = repo / ".git"
    if dot_git.is_dir():
        return dot_git.resolve()
    if not dot_git.is_file():
        return None
    try:
        gitfile = dot_git.read_text(errors="replace").strip()
    except OSError:
        return None
    if gitfile.startswith("gitdir:"):
        return (repo / gitfile.removeprefix("gitdir:").strip()).resolve()
    return None


def git_common_dir(repo: Path) -> Path | None:
    directory = git_dir(repo)
    if directory is None or not (directory / "HEAD").is_file():
        return None
    common = directory / "commondir"
    if not common.is_file():
        return directory
    try:
        return (directory / common.read_text().strip()).resolve()
    except OSError:
        return None


def worktree_command_targets(
    payload: dict, command: str, cwd: Path, base_repo: Path | None
) -> dict[Path, dict[str, list[list[str]]]]:
    """Route raw worktree operations to their repository and rule."""
    commands = tokenize_command(command)
    if commands and commands[0][0] == "cd":
        args = commands[0][1:]
        if args[:1] == ["--"]:
            args = args[1:]
        if len(args) == 1 and args[0] != "-":
            cwd = resolve_tool_path(os.path.expanduser(args[0]), str(cwd))

    scratch_roots = set()
    for raw in ("/tmp", os.environ.get("TMPDIR"), payload.get("scratchpad_dir")):
        if isinstance(raw, str) and Path(raw).is_absolute():
            root = Path(raw).resolve()
            if root != root.parent:
                scratch_roots.add(root)
    targets: dict[Path, dict[str, list[list[str]]]] = {}
    for argv in commands:
        checkout, operation = worktree_operation(argv, cwd)
        if not operation:
            continue
        rule = WORKTREE_OPERATION_RULES[operation[0]]

        repos = set()
        if repo := find_repo_root(checkout):
            repos.add(repo)
        if operation[0] == "remove":
            args = operation[1:]
            path = args[args.index("--") + 1] if "--" in args[:-1] else next(
                (arg for arg in args if not arg.startswith("-")), ""
            )
            if path:
                directory = resolve_tool_path(os.path.expanduser(path), str(checkout))
                if repo := find_repo_root(directory):
                    repos.add(repo)
        if not repos and base_repo and rule == WORKTREE_CLEANUP_RULE:
            # An unresolved target still gets the launch repo's existing gate.
            repos.add(base_repo)

        for repo in sorted(repos):
            common = git_common_dir(repo)
            if rule == WORKTREE_CLEANUP_RULE and common and any(
                repo.is_relative_to(root) and common.is_relative_to(root)
                for root in scratch_roots
            ):
                continue
            checkouts = [repo]
            if common and common.name == ".git" and common.parent != repo:
                # A linked worktree may predate rule adoption in its primary.
                checkouts.append(common.parent)
            for target in checkouts:
                if rule == WORKTREE_ADD_RULE and not (target / "make" / "worktree.mk").is_file():
                    continue
                rules = targets.setdefault(target, {})
                rules.setdefault(rule, []).append(["git", "worktree", *operation])
    return targets


def worktree_operation(argv: list[str], cwd: Path) -> tuple[Path, list[str]]:
    if argv[0] != "git":
        return cwd, []
    args = iter(argv[1:])
    for arg in args:
        if arg == "-C":
            if directory := next(args, ""):
                cwd = resolve_tool_path(os.path.expanduser(directory), str(cwd))
        elif arg in ("-c", "--git-dir", "--work-tree", "--namespace", "--config-env"):
            next(args, None)
        elif not arg.startswith("-"):
            if arg == "worktree":
                operation = list(args)
                if operation and operation[0] in WORKTREE_OPERATION_RULES:
                    return cwd, operation
            break
    return cwd, []


def cache_root() -> Path:
    xdg = os.environ.get("XDG_CACHE_HOME")
    base = Path(xdg) if xdg else Path.home() / ".cache"
    return base / "agent-rules"


sanitize_id = agents.sanitize_id
agent_context = agents.agent_context


def marker_dir(payload: dict, agent: str, session_id: str) -> Path:
    """Marker key shared by catalog delivery and context-scoped compaction."""
    context = agent_context(payload, agent)
    if agent == AGENT_AGY:
        return cache_root().absolute() / agent / (agents.agy_key(session_id) or "unknown") / context
    return cache_root() / agent / sanitize_id(session_id) / context


def marker_name(rule_name: str, body: str) -> str:
    """`<rule>-<sha256(body)[:12]>`: a body that differs is delivered again."""
    digest = hashlib.sha256(body.encode("utf-8")).hexdigest()
    return f"{rule_name}-{digest[:12]}"


def marker_delivered(marker: Path, *, defer_markers: bool = False) -> bool:
    try:
        if not defer_markers:
            return marker.exists()
        info = marker.lstat()
    except OSError:
        return False
    return stat.S_ISREG(info.st_mode) and info.st_uid == os.geteuid() and info.st_nlink == 1


class FrontmatterError(Exception):
    pass


def find_frontmatter_start(text: str) -> int | None:
    """Return the index of the opening `---` of a YAML frontmatter block, or None.

    Accepts any mix of leading HTML comment lines and blank lines before the
    opening fence (the agentic-worktree-mcp generator's
    `<!-- comment -->\\n\\n---` header style). Anything else means there is no
    frontmatter.
    """
    idx = 0
    while True:
        if text.startswith("---\n", idx):
            return idx
        line_end = text.find("\n", idx)
        if line_end == -1:
            return None
        line = text[idx:line_end].strip()
        if not line:
            # Blank line between provenance comment and fence — keep scanning.
            idx = line_end + 1
            continue
        if not line.startswith("<!--") or not line.endswith("-->"):
            return None
        idx = line_end + 1


def parse_frontmatter(path: Path) -> tuple[dict, str]:
    """Parse frontmatter from a rule file path. See parse_frontmatter_text."""
    return parse_frontmatter_text(path.read_text())


def parse_frontmatter_text(text: str) -> tuple[dict, str]:
    """Parse a minimal YAML frontmatter block. Supports the fields we use only:
    scalar keys plus one-level string lists (paths, gates, goldens, legacy regexes).
    Returns ({}, body) when no frontmatter is present.

    Tolerates leading provenance HTML comment lines and blank lines (e.g. the
    `<!-- agent-rules: generated vX.Y.Z -->` header sync writes) before the
    opening `---`.
    """
    start = find_frontmatter_start(text)
    if start is None:
        return {}, text
    end_idx = text.find("\n---", start + 4)
    if end_idx == -1:
        raise FrontmatterError("unterminated YAML frontmatter")

    fm_text = text[start + 4 : end_idx]
    body = text[end_idx + len("\n---") :].lstrip("\n")

    fm: dict = {
        "description": None,
        "paths": [],
        "match_content": [],
        "match_command": [],
        "deny_command": [],
        "deny": None,
        "gate_command": [],
        "gate_args_any": [],
        "gate_args_all": [],
        "deny_gate_command": [],
        "deny_gate_args_any": [],
        "deny_gate_args_all": [],
        "deny_gate_args_none": [],
        "skip_in_lane": None,
        "should_deny": [],
        "should_match": [],
        "should_not_match": [],
        "requires_executable": [],
    }
    list_keys = {
        "paths",
        "match_content",
        "match_command",
        "deny_command",
        "gate_command",
        "gate_args_any",
        "gate_args_all",
        "deny_gate_command",
        "deny_gate_args_any",
        "deny_gate_args_all",
        "deny_gate_args_none",
        "should_deny",
        "should_match",
        "should_not_match",
        "requires_executable",
    }
    current_list: list | None = None

    for raw_line in fm_text.splitlines():
        line = raw_line.rstrip()
        if not line or line.startswith("#"):
            continue
        if line.startswith(" ") or line.startswith("\t"):
            stripped = line.strip()
            if current_list is None or not stripped.startswith("- "):
                continue
            value = strip_yaml_string(stripped[2:].strip())
            current_list.append(value)
            continue

        if ":" not in line:
            current_list = None
            continue
        key, _, after = line.partition(":")
        key = key.strip()
        after = after.strip()

        if key in list_keys:
            if after:
                raise FrontmatterError(f"`{key}` must be a YAML list, not inline value")
            current_list = []
            fm[key] = current_list
        elif key in ("description", "deny", "reference_only", "skip_in_lane", "write_only"):
            fm[key] = strip_yaml_string(after)
            current_list = None
        else:
            current_list = None

    return fm, body


def strip_yaml_string(value: str) -> str:
    """Strip surrounding quotes from a YAML scalar.

    Double-quoted scalars decode backslash escapes only when a backslash is
    actually present. The utf-8 → unicode_escape → latin-1 → utf-8 round-trip
    preserves non-ASCII (em dashes endemic in rule prose) while still turning
    sequences like ``\\\\b`` / ``\\\\n`` into their escaped forms — plain
    ``utf-8`` + ``unicode_escape`` alone mojibakes multi-byte UTF-8.
    """
    if len(value) >= 2 and value[0] == value[-1] and value[0] in ('"', "'"):
        inner = value[1:-1]
        if value[0] == '"' and "\\" in inner:
            inner = (
                inner.encode("utf-8")
                .decode("unicode_escape")
                .encode("latin-1")
                .decode("utf-8")
            )
        return inner
    return value


def match_glob(pattern: str, path: str) -> bool:
    """Match a gitignore-style glob against a relative path. Supports `**`."""
    regex = glob_to_regex(pattern)
    return bool(re.match(regex, path))


def glob_to_regex(pattern: str) -> str:
    """Translate a gitignore-style glob into an anchored regex.

    Semantics:
        **/  matches zero or more path components
        **   matches anything
        *    matches any character except /
        ?    matches a single character except /
    """
    out: list[str] = []
    i = 0
    while i < len(pattern):
        c = pattern[i]
        if c == "*":
            if i + 1 < len(pattern) and pattern[i + 1] == "*":
                if i + 2 < len(pattern) and pattern[i + 2] == "/":
                    out.append("(?:.*/)?")
                    i += 3
                    continue
                out.append(".*")
                i += 2
                continue
            out.append("[^/]*")
            i += 1
            continue
        if c == "?":
            out.append("[^/]")
            i += 1
            continue
        if c in r".+()[]{}|^$\\":
            out.append("\\" + c)
            i += 1
            continue
        out.append(c)
        i += 1
    return "^" + "".join(out) + "$"


def format_block(rule_name: str, match_reason: str, body: str) -> str:
    """Format a rule's body for injection into Claude's additional context.

    `match_reason` is rendered verbatim after "matched " — callers wrap path
    matches as `path`-style code spans and command matches with the literal
    word "command".
    """
    header = f"### Rule: {rule_name}\n_Auto-loaded — matched {match_reason}._\n"
    return header + "\n" + body.rstrip() + "\n"


if __name__ == "__main__":
    try:
        sys.exit(main(defer_markers="--defer-markers" in sys.argv[1:]))
    except Exception as exc:
        # Fail open: a crash exits 0, never a failed or blocking hook.
        print(f"inject-rules: unexpected error: {exc}", file=sys.stderr)
        sys.exit(0)
