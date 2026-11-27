#!/usr/bin/env python3
# agent-rules: generated v0.29.5
"""Agent identity shared by the rule hook and its catalog fallback."""

from __future__ import annotations

import hashlib
import os
import re
import sys

AGENT_CLAUDE = "claude"
AGENT_CODEX = "codex"
AGENT_GROK = "grok"
AGENT_AGY = "agy"
AGENT_PI = "pi"
DEFAULT_AGENT = AGENT_CLAUDE
MAIN_CONTEXT = "main"
SUPPORTED_AGENTS = frozenset({AGENT_CLAUDE, AGENT_CODEX, AGENT_GROK, AGENT_AGY, AGENT_PI})
AGY_SAFE_KEY = re.compile(r"[a-z0-9][a-z0-9._-]{0,127}")


def explicit_agent() -> str:
    agent = os.environ.get("AGENT_RULES_AGENT", "").strip().lower()
    if agent and agent not in SUPPORTED_AGENTS:
        print(
            f"inject-rules: unsupported AGENT_RULES_AGENT={agent!r}; defaulting to {DEFAULT_AGENT}",
            file=sys.stderr,
        )
        return DEFAULT_AGENT
    return agent


def detect_agent(payload: dict) -> str:
    """Use the explicit override, then the client-specific payload or environment."""
    agent = explicit_agent()
    if agent:
        return agent
    if "conversationId" in payload:
        return AGENT_AGY
    if os.environ.get("GROK_AGENT") or os.environ.get("GROK_SESSION_ID"):
        return AGENT_GROK
    if "sessionId" in payload or "toolName" in payload or "workspaceRoot" in payload:
        return AGENT_GROK
    return DEFAULT_AGENT


def session_id(payload: dict, agent: str) -> str:
    conversation = payload.get("conversationId") if agent == AGENT_AGY else None
    value = conversation or payload.get("session_id") or payload.get("sessionId")
    if not isinstance(value, str) or (agent == AGENT_AGY and not value.strip()):
        return ""
    return value


def agy_key(value: object) -> str | None:
    """Use the AGY queue's filename encoding for conversation and agent IDs."""
    if not isinstance(value, str) or not value.strip():
        return None
    if AGY_SAFE_KEY.fullmatch(value):
        return value
    return "_" + hashlib.sha256(value.encode("utf-8", "surrogatepass")).hexdigest()


def safe_marker_id(value: str) -> str:
    """Encode an ID as one path segment. Return empty for reserved segments."""
    cleaned = re.sub(r"[^A-Za-z0-9._-]+", "_", value)[:128]
    return "" if cleaned in ("", ".", "..") else cleaned


def sanitize_id(value: str) -> str:
    return safe_marker_id(value) or "unknown"


def agent_context(payload: dict, agent: str = DEFAULT_AGENT) -> str:
    """Return the marker directory segment for main or a named child."""
    if agent == AGENT_AGY:
        key = agy_key(payload.get("agentId") or payload.get("agent_id"))
        return "agent-" + key if key else MAIN_CONTEXT
    agent_id = payload.get("agent_id") or payload.get("agentId")
    if not isinstance(agent_id, str) or not agent_id:
        return MAIN_CONTEXT
    return "agent-" + sanitize_id(agent_id)
