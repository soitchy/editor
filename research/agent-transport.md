# Agent transport: how diffity talks to Claude Code, and what our editor needs

Research date: 2026-11-03. Sources are primary unless marked otherwise: diffity source at commit
[`8abe0d1`](https://github.com/nilbuild/diffity/tree/8abe0d1150e7adf7331a399960c6e543741935bb), the
MCP specification, and the Claude Code docs at code.claude.com.

Abbreviation used below: `D/` = `https://github.com/nilbuild/diffity/blob/8abe0d1150e7adf7331a399960c6e543741935bb/`

## TL;DR

- **Passive direction in diffity** is a stdio MCP server, `diffity-mcp`. It is a small separate
  binary that Claude Code (or Codex) spawns. It forwards each tool call as one line of JSON over a
  Unix domain socket to the running Diffity app. **Connect** in Settings -> Terminal just runs
  `claude mcp add --scope user diffity -- <diffity-mcp> --terminal --socket <sock>`.
- **Active direction in diffity** does not use `claude -p`. Diffity is an **ACP (Agent Client
  Protocol) client**. It launches the `@agentclientprotocol/claude-agent-acp` adapter, an npm
  package that needs Node, and passes the same `diffity-mcp` to it as a stdio MCP server, with a
  per-run token.
- **MCP spec**: the latest revision is **2026-07-28**. It is stateless: there is no `initialize`,
  every request carries `_meta`, and `server/discover` is mandatory. Claude Code still speaks the
  legacy `initialize` handshake (2025-11-25) to servers that don't support 2026-07-28. Its v2
  runtime also probes for the new revision. **Channels**, the feature for pushing messages into a
  session, only work over the legacy handshake.
- **Recommendation**: copy diffity's shape, but drop Node. Ship the editor binary with a
  `--mcp-stdio` mode that speaks **legacy MCP (2025-11-25) over stdio**: newline-delimited
  JSON-RPC, five methods. It relays to the running editor over a local socket. For the active
  direction, spawn `claude -p --input-format stream-json --output-format stream-json --verbose`
  with `--mcp-config` pointing at the same relay, and with a session ID we choose so we can
  resume. Details follow.

---

## 1. How diffity connects to Claude Code / Codex

### 1.1 Process topology

Three binaries are built from one Cargo crate, as `[[bin]]` entries `diffity-desktop`,
`diffity-mcp` and `diffity-cli`. The crate depends on `rmcp = 3.5.0` (features `server` and
`transport-io`) and `agent-client-protocol = 2.2.0`
([`D/src-tauri/Cargo.toml`](https://github.com/nilbuild/diffity/blob/8abe0d1150e7adf7331a399960c6e543741935bb/src-tauri/Cargo.toml)).

```
Claude Code ──stdio (MCP JSON-RPC)──> diffity-mcp ──Unix socket (NDJSON)──> Diffity app (McpBridge)
```

### 1.2 `diffity-mcp` (the MCP server)

Source: [`D/src-tauri/src/bin/diffity-mcp/main.rs`](https://github.com/nilbuild/diffity/blob/8abe0d1150e7adf7331a399960c6e543741935bb/src-tauri/src/bin/diffity-mcp/main.rs)

- **Transport: stdio only**, via `server.serve(rmcp::transport::stdio())`. It has no HTTP
  listener. The `rmcp` library handles JSON-RPC framing and negotiates the protocol version.
- **Handlers**: `get_info` (serves `initialize`), `list_tools`, `list_prompts`, `get_prompt`,
  `call_tool`. `serverInfo` is `Implementation::new("diffity", CARGO_PKG_VERSION)`. Capabilities
  are tools plus prompts in terminal mode, and tools only in in-app mode.
- **Flags**:
  - `--socket` (or the `DIFFITY_MCP_SOCKET` env var) is required.
  - `--token` (or `DIFFITY_MCP_TOKEN`) is required unless `--terminal` is passed.
  - `--scheme` defaults to `diffity`. It is used for `open_in_diffity` deep links.
- **Wire to the app**: newline-delimited JSON over `UnixStream`. A request looks like
  `{"terminal":{"client":…,"repo":…},"tool":name,"args":args}`, or uses `token` in place of
  `terminal`. A reply looks like `{"ok":true,"result":…}` or `{"ok":false,"error":"…"}`. A failed
  exchange is retried once after reconnecting.
- **Identity in terminal mode**:
  - The client is `peer_info().client_info.name` from the MCP `initialize` handshake. The app maps
    `claude-code` to "Claude Code (terminal)" and `codex-mcp-client` to "Codex (terminal)".
  - The repo is `git -C <cwd or path arg> rev-parse --show-toplevel`. The server process inherits
    the agent's cwd, so this is the user's project.
- **If the app isn't running**:
  - Terminal mode finds the enclosing `.app` bundle from `current_exe` and runs `open -g <bundle>`.
    It then polls the socket 50 times, 200 ms apart, about 10 s in total. On failure it returns a
    tool error string, such as "Diffity isn't running. Open it and try again."
  - In-app mode returns "Diffity app is not reachable…".
  - Either way the MCP process itself stays up. Only the tool call fails.
- **Tool list**:
  - In terminal mode, `tools/list` is static and the app isn't contacted. So Claude Code can list
    tools while the app is closed.
  - In in-app mode, the server asks the app for `__list_tools` and filters the list by run mode.
  - It sets `ttl_ms: 0` with private cache scope.

### 1.3 Tools exposed

Source: [`D/src-tauri/src/bin/diffity-mcp/tools.rs`](https://github.com/nilbuild/diffity/blob/8abe0d1150e7adf7331a399960c6e543741935bb/src-tauri/src/bin/diffity-mcp/tools.rs)

| Tool | Read-only | Required args (optional) |
|---|---|---|
| `get_diff` | yes | (`summary`, `files[]`) |
| `list_threads` | yes | (`status`: open, resolved or dismissed) |
| `add_comment` | no | `file`, `startLine`, `body` (`endLine`, `side`: new or old, `severity`: must-fix, suggestion, nit or question) |
| `add_general_comment` | no | `body` |
| `reply` | no | `threadId`, `body` |
| `resolve` | no | `threadId` (`summary`) |
| `dismiss` | no | `threadId` (`reason`) |
| `set_guide` | no | `summary`, `chapters[]` (a structured reading guide) |
| `open_in_diffity` | yes | terminal mode only (`path`, `ref`) |

- In terminal mode every tool also takes `path` and `ref`, so the agent can name which repo and
  diff view it means.
- The only annotation used is `readOnlyHint`.
- The server sends no `instructions`. The "address my Diffity review" flow relies purely on the
  tool descriptions. Diffity's README says the agent "reads the open comments … replies to each
  thread, and resolves the fixed ones"
  ([README](https://github.com/nilbuild/diffity#readme)).

### 1.4 App-side bridge

Source: [`D/src-tauri/src/agents/bridge.rs`](https://github.com/nilbuild/diffity/blob/8abe0d1150e7adf7331a399960c6e543741935bb/src-tauri/src/agents/bridge.rs) and [`D/src-tauri/src/agents/terminal.rs`](https://github.com/nilbuild/diffity/blob/8abe0d1150e7adf7331a399960c6e543741935bb/src-tauri/src/agents/terminal.rs)

- **Socket**: `<data dir>/mcp.sock` when the path is 100 characters or fewer. Otherwise it falls
  back to `/tmp/diffity[-dev]-<uid>.sock`. The socket is `chmod 0600`, stale files are removed on
  bind, and the file is deleted on drop.
- **Auth**:
  - In-app runs get a per-run token made of two concatenated UUIDv4s. The token maps to a
    `Binding`, which holds the session and the mode.
  - Terminal requests skip the token. They are gated by a global "Allow terminal agents" flag
    (settings key `terminal.allowed`).
- **Policy**: [`policy.rs`](https://github.com/nilbuild/diffity/blob/8abe0d1150e7adf7331a399960c6e543741935bb/src-tauri/src/agents/policy.rs)
  defines the modes Ask, Review, Resolve and Edit. Ask only gets `get_diff` and `list_threads`.
  The other modes add the comment and thread tools.
- **Live UI**: after a mutating tool succeeds, the bridge fires a `ThreadsChangedHook(session_id)`,
  and the UI refreshes threads.
- **Platform**: the bridge uses `UnixListener` without a platform gate. The launcher uses `open -g`
  on a `.app` bundle, and the CLI installs to `/usr/local/bin`. **The source looks macOS-only.**
  I found no Windows named-pipe path.

### 1.5 What "Settings -> Terminal -> Connect" does

Source: [`D/src-tauri/src/commands/terminal.rs`](https://github.com/nilbuild/diffity/blob/8abe0d1150e7adf7331a399960c6e543741935bb/src-tauri/src/commands/terminal.rs)

Diffity writes no config files itself. It shells out to the agent's own CLI:

```sh
claude mcp remove --scope user diffity          # ignored if it fails
claude mcp add --scope user diffity -- <mcp_binary> --terminal --socket <socket_path>
codex  mcp remove diffity
codex  mcp add diffity -- <mcp_binary> --terminal --socket <socket_path>
```

- Dev builds append `--scheme diffity-dev` and use the server name `diffity-dev`.
- **Status**: runs `<cli> mcp get diffity`. Exit code 0 means connected. Each check is killed
  after 20 s.
- **Disconnect**: runs `<cli> mcp remove`.
- The UI also shows the raw argv `[mcp_binary, "--terminal", "--socket", sock]` so users can paste
  it into other clients, such as Cursor or OpenCode.

### 1.6 Active direction in diffity ("send to Claude")

Sources: [`D/src-tauri/src/agents/session.rs`](https://github.com/nilbuild/diffity/blob/8abe0d1150e7adf7331a399960c6e543741935bb/src-tauri/src/agents/session.rs) and [`D/src-tauri/src/agents/detect.rs`](https://github.com/nilbuild/diffity/blob/8abe0d1150e7adf7331a399960c6e543741935bb/src-tauri/src/agents/detect.rs)

- Diffity acts as an **ACP client**, using the `agent-client-protocol` crate over the child's
  stdio.
- **Agent binary**:
  - Claude: `@agentclientprotocol/claude-agent-acp@0.84.0`, binary `claude-agent-acp`.
  - Codex: `@agentclientprotocol/codex-acp@2.0.0`, binary `codex-acp`.
  - Each is looked up on PATH first, then falls back to `npx -y <pkg>`. **Node.js is required.**
    If it's missing, Diffity shows "Diffity also needs Node.js…".
  - `CLAUDE_CODE_EXECUTABLE` or `CODEX_PATH` is set when the user gives a custom CLI path.
  - Auth is probed with `claude auth status --json` (reading `loggedIn`) and `codex login status`.
- **Session setup**:
  - The `initialize` call advertises the fs read and write capabilities, with terminal turned off.
  - It sends `session/load` when there is a resume ID, otherwise `session/new`. In both cases it
    passes `McpServer::Stdio("diffity", mcp_command, mcp_args)`, which is the same `diffity-mcp`,
    in token mode.
  - Model and effort are set via session config options.
- **Streaming**: `SessionNotification` updates are mapped to UI events: `AgentMessageChunk`,
  `AgentThoughtChunk`, `ToolCall`/`ToolCallUpdate` (diffs are cached) and `Plan`.
- **Permissions**:
  - Diffity's own MCP tools (`mcp__diffity__*`) are auto-allowed.
  - Other requests are auto-denied or auto-allowed by mode policy, or sent to a modal through a
    `PermissionBroker`.
  - `fs/write_text_file` is refused with `-32001` in read-only modes.

---

## 2. MCP spec: minimum viable server from a native app

### 2.1 Versions

- **Latest: `2026-07-28`**
  ([spec](https://modelcontextprotocol.io/specification/2026-07-28/basic.md)). The protocol is
  stateless.
  - "Servers MUST NOT rely on prior requests over the same connection to establish context".
  - Every request carries `_meta["io.modelcontextprotocol/protocolVersion"]` and
    `…/clientCapabilities`, and may carry `…/clientInfo`.
  - Results carry `resultType` (`"complete"`).
  - Servers MUST implement `server/discover`, and there is no `initialize`
    ([versioning](https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning.md),
    [discover](https://modelcontextprotocol.io/specification/2026-07-28/server/discover)).
- **Legacy: `2025-11-25` and earlier.** These use the `initialize` request, its response, and a
  `notifications/initialized` notification. Version negotiation happens inside `initialize`
  ([lifecycle 2025-11-25](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle)).
- **Compatibility**
  ([matrix](https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning.md#compatibility-matrix)):
  - A legacy-only server works with legacy and dual-era clients.
  - On stdio, a dual-era client probes with `server/discover`. If it gets "any other error, or
    does not respond within a reasonable timeout", it falls back to `initialize`
    ([stdio compat](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/stdio.md#backward-compatibility)).
  - A dual-era server picks the era from the first message: `initialize` means legacy, `_meta`
    means modern.

### 2.2 What Claude Code actually speaks

From [Claude Code MCP docs](https://code.claude.com/docs/en/mcp):

- Claude Code has two client runtimes. **v1** is built on the MCP TS SDK 1.x and is legacy.
  **v2** is built on TS SDK 2.0, which "adds MCP protocol revision 2026-07-28".
- v2 is on by default on v2.1.232 or later when feature flags are fetched, and on v2.1.274 or
  later in some other environments. On v2, Claude Code asks stdio and HTTP servers whether they
  support 2026-07-28, "and uses it with those that do". Other servers connect on the earlier
  handshake.
- Overrides: `MCP_SDK_GENERATION=v1|v2` and `MCP_PROTOCOL_NEGOTIATION=auto|legacy`.
- **Channels**: "a channel server that negotiates MCP protocol revision 2026-07-28 can't deliver
  channel messages, so Claude Code doesn't register it as a channel". This is from the same page.
- **Conclusion**: a **legacy-only (2025-11-25) stdio server works with every Claude Code
  version**, and it keeps channels open as an option. Adding 2026-07-28 later is optional.

### 2.3 Minimal legacy surface (tools-only)

| Method | Direction | Notes |
|---|---|---|
| `initialize` | C->S request | Reply with `protocolVersion` (echo the client's version if supported, else `"2025-11-25"`), `capabilities: {tools:{}}`, `serverInfo`, and optional `instructions` |
| `notifications/initialized` | C->S notification | No reply |
| `ping` | either | Reply with `{}` |
| `tools/list` | C->S | `{tools:[{name, description, inputSchema, annotations?}]}` |
| `tools/call` | C->S | `{content:[{type:"text",text}], isError?}`. Report tool failures as `isError:true`, not as JSON-RPC errors |
| `server/discover` (modern probe) | C->S | A legacy server returns `-32601`, and the client falls back to `initialize` |
| `notifications/cancelled` | C->S | Optional to honour |
| anything else with an `id` | | `-32601` Method not found |

Optional extras:

- `prompts/list` and `prompts/get`. Claude Code shows these as `/server:prompt` slash commands
  ([docs](https://code.claude.com/docs/en/mcp)), for example `/editor:address-review`.
- `notifications/tools/list_changed`.

JSON Schema defaults to 2020-12. Claude Code rejects a top-level `anyOf`/`oneOf`/`allOf` in
`inputSchema` ([docs](https://code.claude.com/docs/en/mcp)). Implementing this needs a JSON
parser and serializer, a line reader, and a dispatch switch. No SDK or runtime is required.

### 2.4 stdio vs Streamable HTTP

**stdio** ([spec](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/stdio.md)):

- The client spawns the server.
- Framing is UTF-8 JSON-RPC, one message per line. A message "MUST NOT contain embedded
  newlines".
- stdout must carry only MCP messages. stderr is free for logging.
- Shutdown: the client closes stdin, waits, then kills. "Servers SHOULD exit promptly when their
  standard input is closed". On Windows, Claude Code closes stdin and then ends the process tree
  after 300 ms ([docs](https://code.claude.com/docs/en/mcp)).
- The spec explicitly says the same NDJSON framing SHOULD be reused over Unix sockets or TCP for
  custom transports, which is exactly diffity's app bridge.

**Streamable HTTP** ([spec](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http.md)):

- One POST endpoint. Each response is either a JSON body or an SSE stream.
- In 2026-07-28 the GET stream and `Mcp-Session-Id` were removed. Required headers are now
  `MCP-Protocol-Version`, `Mcp-Method` and `Mcp-Name`, and they are validated against the body.
- Servers MUST validate `Origin` against DNS rebinding and SHOULD bind 127.0.0.1.
- Registration would be `claude mcp add --transport http editor http://127.0.0.1:<port>/mcp`.

| | stdio relay (diffity's model) | HTTP hosted in the editor |
|---|---|---|
| Editor closed | The MCP process still starts, so tools list fine. Calls fail gracefully or launch the editor | Connection refused. The server shows as failed in `/mcp`. Claude Code retries a remote server's first connection up to 3 times and does not reconnect automatically after that |
| Port or path discovery | A fixed socket path in the user data dir | A fixed port is needed in the registered URL. It can collide, and multiple instances need care |
| Security | Socket `0600`, plus a token for active runs | Must validate `Origin` and authenticate, because any local process or browser page can POST |
| Implementation cost | NDJSON on stdin/stdout, plus an IPC client | An HTTP/1.1 server, SSE, and header validation |
| Repo identity | Free, from the inherited cwd | Must be passed in tool args |
| Spec churn | Small, because the stdio framing is stable | Larger, because the HTTP shape changed in 2026-07-28 |

**Verdict: stdio.** Use our own executable in a relay mode. The relay is short-lived. It is
spawned per Claude Code session and exits on stdin EOF. The editor owns the local socket listener.

On Windows the IPC between relay and editor needs either an AF_UNIX socket (supported on Windows
10 and later; check that Odin's `core:net` exposes it) or a named pipe. That choice is open for a
spike.

---

## 3. Registering with Claude Code

From [Claude Code MCP docs](https://code.claude.com/docs/en/mcp) and the [CLI reference](https://code.claude.com/docs/en/cli-reference):

- **stdio syntax**: `claude mcp add [options] <name> -- <command> [args...]`. Everything after
  `--` goes to the server untouched. The options include `--transport/-t`, `--scope/-s`,
  `--env/-e` and `--header/-H`.
- **Scopes**:

  | Scope | Loads in | Stored in |
  |---|---|---|
  | `local` (default) | current project only | `~/.claude.json` |
  | `project` | current project only | `.mcp.json` in the repo; needs approval before first use |
  | `user` | all projects | `~/.claude.json` |

- **Other commands**:
  - `claude mcp add-json <name> '<json>'`
  - `claude mcp get <name>`, which exits 0 if the server is configured. Diffity uses this for
    status.
  - `claude mcp list`, `claude mcp remove`, and `claude mcp reset-project-choices`
- **Session-only config**: `--mcp-config <file-or-json>` with optional `--strict-mcp-config`. This
  is the right fit for active runs because it leaves user config untouched.
- **Tool names** seen by Claude are `mcp__<server>__<tool>`. The same names are used in
  `--allowedTools` and permission rules.
- **Limits**:
  - Output warns at 10k tokens and is capped at 25k (`MAX_MCP_OUTPUT_TOKENS`).
  - Text over 50k characters is persisted to a file unless the tool sets
    `_meta["anthropic/maxResultSizeChars"]`.
  - Server instructions and upfront tool descriptions are cut at 4,096 characters.
  - Startup timeout is `MCP_TIMEOUT`, 30 s by default for `-p` with `--mcp-config`.
- **Tool search**: tools are deferred by default (tool search). The **server `instructions`** text
  is always loaded, so we should write instructions such as "When the user asks to address their
  review, call list_threads…" rather than relying on descriptions alone.

So our "Connect" button would be the same as diffity's:

```sh
claude mcp add --scope user <editor> -- <path-to-editor-exe> --mcp-stdio
```

Use `claude mcp get <editor>` for status and `claude mcp remove --scope user <editor>` to
disconnect.

---

## 4. Driving Claude Code actively from the editor

From [headless docs](https://code.claude.com/docs/en/headless) and the [CLI reference](https://code.claude.com/docs/en/cli-reference):

- **One-shot**: `claude -p "<prompt>" --output-format json`. The result includes `result`,
  `session_id`, `total_cost_usd`, and `structured_output` when `--json-schema` is passed. Exit
  code 0 means success.
- **Streaming out**: `--output-format stream-json --verbose`. Add `--include-partial-messages` for
  token deltas, which arrive as `stream_event` lines with `event.delta.type == "text_delta"`.
- **Stream lines**:
  - The first line is `system/init`, which lists `mcp_servers[{name,status}]` and
    `mcp_server_errors`. A `capabilities` array helps with feature detection.
  - Then `assistant` and `user` messages, `system/api_retry`, and `permission_denied`.
  - The last line is `result`.
- **Streaming in**: `--input-format stream-json` keeps one long-lived process for many turns.
  Write lines like `{"type":"user","message":{"role":"user","content":"…"},"parent_tool_use_id":null}`
  to stdin. The shape comes from the Agent SDK's `SDKUserMessage`
  ([streaming input](https://code.claude.com/docs/en/agent-sdk/streaming-vs-single-mode)).
  `--replay-user-messages` echoes them back as acknowledgements.
- **Sessions**:
  - `--session-id <uuid>` lets us pick the ID up front, so we can store it with the review.
  - `--resume <id|path.jsonl>` resumes from any directory on the machine.
  - `--continue` resumes the most recent session. `--fork-session` branches a resumed session.
- **Permissions**:
  - `--allowedTools "Read,Edit,mcp__editor__*"` uses permission rule syntax, for example
    `Bash(git diff *)`.
  - `--disallowedTools` removes tools or adds deny rules. `--tools` restricts the tool set.
  - `--permission-mode` takes `default|acceptEdits|plan|auto|dontAsk|bypassPermissions`. Since
    v2.1.302, `-p` starts in Manual mode, and an unapproved prompt is denied.
  - `--permission-prompt-tool mcp__editor__approve` sends prompts to an MCP tool we host, so the
    editor can show its own approval modal.
  - `--permission-prompts none` turns prompting off for unattended runs.
  - The MCP tool contract for `--permission-prompt-tool` is not on code.claude.com. Secondary
    sources describe input `{tool_name, input, tool_use_id?}` and output text JSON
    `{"behavior":"allow","updatedInput":{…}}` or `{"behavior":"deny","message":"…"}`
    ([claude-code#1175](https://github.com/anthropics/claude-code/issues/1175)). **Verify this in
    a spike.**
- **Isolation and speed**:
  - `--bare` skips CLAUDE.md, hooks, skills and auto-discovered MCP. Bare mode needs
    `ANTHROPIC_API_KEY` and does not use subscription login, so **don't use `--bare`** for a
    personal editor.
  - `--append-system-prompt` adds the review instructions.
  - `--max-turns` and `--max-budget-usd` cap a run.
- **Stopping**: SIGINT ends the turn cleanly. SIGTERM exits with code 143 and leaves the turn
  unfinished.

### Alternative active channels (for completeness)

- **ACP adapter**, which is what diffity uses. It needs Node and npx for the
  `claude-agent-acp` package, which goes against our no-runtime goal. Its benefit is that one
  protocol drives both Claude and Codex.
- **Channels** ([channels](https://code.claude.com/docs/en/channels),
  [reference](https://code.claude.com/docs/en/channels-reference)):
  - Our stdio MCP server declares `capabilities.experimental["claude/channel"]` and emits
    `notifications/claude/channel {content, meta}`. The text is injected into the user's
    *already-running interactive* session.
  - Optional permission relay uses `notifications/claude/channel/permission_request`, answered
    with `…/permission {request_id, behavior}`.
  - Limits: this is a **research preview**. It needs claude.ai or Console auth. Custom servers
    need `claude --dangerously-load-development-channels server:<name>` at launch, the flag is
    ignored under `-p`, and the server must negotiate the legacy protocol.
  - It is attractive later ("send comments to the session I already have open"). It is too
    unstable to be the primary path.
- **`claude mcp serve`** exposes Claude Code's own tools to an MCP client. It is not an agent
  loop, so it is not useful here.

---

## 5. Recommendation

1. **One binary, two modes.** `editor --mcp-stdio` is a legacy MCP 2025-11-25 server over stdio
   that implements `initialize`, `initialized`, `ping`, `tools/list` and `tools/call`, plus
   `-32601` for everything else. It relays tool calls as NDJSON to the running editor over a
   per-user local socket, with `0600` permissions or a named pipe on Windows. No Node, no Python.
2. **Tool surface**: mirror diffity: `get_diff`, `list_threads`, `add_comment`, `reply`,
   `resolve` and `dismiss`, plus `open_in_editor`. Add `path` and `ref` args and set
   `readOnlyHint` on the readers. Write strong `instructions`, because tool search defers tool
   definitions.
3. **Editor not running**: keep `tools/list` static so registration never shows "failed". On
   `tools/call`, try to launch the editor and poll briefly (diffity waits about 10 s). If that
   fails, return `isError:true` with a human-readable message.
4. **Connect button**: runs `claude mcp add --scope user <name> -- <exe> --mcp-stdio`. Status is
   `claude mcp get`. Gate terminal access behind a setting, as diffity does.
5. **Active direction**:
   - Spawn
     `claude -p --input-format stream-json --output-format stream-json --verbose --include-partial-messages --session-id <uuid> --mcp-config <json pointing at exe --mcp-stdio --token T> --allowedTools "mcp__<name>__*" --permission-mode acceptEdits`.
   - Parse NDJSON from stdout into the activity panel.
   - Later turns go to the same stdin. Use `--resume <uuid>` after a restart.
   - Use the per-run token so the editor knows which review and run each tool call belongs to,
     and so it can scope the allowed tools per mode, as diffity's `policy.rs` does.
6. **Defer**: Streamable HTTP, MCP 2026-07-28 dual-era support, channels, ACP, and Codex. Codex
   registers the same way: `codex mcp add <name> -- <cmd>`, per diffity's source.

### Open questions / to verify in a spike

- The exact `--permission-prompt-tool` request and response schema (not documented on
  code.claude.com).
- Whether Odin `core:net` supports AF_UNIX on Windows, or whether we need named pipes via
  `core:sys/windows`.
- Which `clientInfo.name` Claude Code sends today. Diffity's mapping implies `claude-code`.
- How tool-call results render in Claude Code when `isError` is used, compared with plain text.
