---
id: 006
title: How agents connect to an editor
type: wayfinder:research
status: closed
assignee: jake.shepherd
blocked_by: []
parent: map.md
---

# How agents connect to an editor

## Question

How does diffity connect to Claude Code / Codex (MCP or otherwise)? What is the minimum to host an MCP server from a native app (stdio vs HTTP, lifecycle)? How can the editor drive Claude Code actively (headless CLI, prompts, streaming results back)?

## Resolution

Findings: branch `research/agent-transport`, file `research/agent-transport.md`. Sources: diffity's Rust source (read via WebFetch, not cloned), the MCP spec, Claude Code docs.

- **diffity, passive direction:**
  - A separate stdio MCP server (`diffity-mcp`, Rust `rmcp`) relays each tool call as one line of JSON over a Unix socket to the running app.
  - The "Connect" button just runs `claude mcp add --scope user diffity -- <diffity-mcp> --terminal --socket <sock>`.
  - Tools: get_diff, list_threads, add_comment, add_general_comment, reply, resolve, dismiss, set_guide, open_in_diffity.
  - If the app is closed, a tool call launches it and polls about 10s. The source looks macOS-only.
- **diffity, active direction:** it drives Claude through an npm ACP adapter (`claude-agent-acp`), so it needs Node, not `claude -p`.
- **MCP spec:**
  - The 2026-07-28 revision replaces `initialize` with a mandatory `server/discover`.
  - Claude Code still accepts the old handshake and probes newer servers, falling back.
  - Channels (pushing into a running session) only work on the old handshake.
- **The researcher suggests:**
  - Passive: an `--mcp-stdio` mode of the editor exe speaking the 2025-11-25 protocol (newline-delimited JSON-RPC: initialize, initialized, ping, tools/list, tools/call), relaying to the editor over a local socket. stdio over HTTP: copes with the editor being closed, no port, smaller security surface, repo taken from the working directory.
  - Active: spawn `claude -p --input-format stream-json --output-format stream-json --verbose --session-id <uuid> --mcp-config ... --allowedTools mcp__ed__*`, then `--resume`.
- **Unverified:**
  - The `--permission-prompt-tool` response format (secondary sources only).
  - Whether Odin supports AF_UNIX sockets on Windows, or named pipes are needed.

To decide in [Agent integration design](012-agent-integration-design.md).
