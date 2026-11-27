# Agent integrations: research reference

Researched and written 2026-11-22. Every fact below comes from the primary documentation (or, where
noted, primary source code) fetched on that date. The tools covered change monthly; re-check the
linked pages before shipping. Anything marked **UNVERIFIED** could not be confirmed from a primary
source and must be tested by hand before the app relies on it.

Scope: what Breakpoint needs from each coding agent — when it starts working on a prompt, when it
finishes, when it is waiting for the user, which project folder it is in, and a short label for
the prompt — plus shell integration for long-running commands.

---

## 0. Read this first: decisions and cross-cutting pitfalls

### 0.1 Transport

Breakpoint's CLI talks to the app over a Unix domain socket with no TCP port (SPEC.md §5.1), so
every snippet below is a command hook (`breakpoint emit …`, CLI in SPEC.md §5.8, event kinds in
§6); native HTTP hooks are described only as an alternative.

### 0.2 CLI path used in the snippets

The snippets call the CLI by an absolute path, because hooks do not reliably get the user's shell
`PATH`. GUI-launched apps like Cursor, and Claude Code started from the Dock or desktop app, may
have a minimal `PATH`. They use:

```
$HOME/.breakpoint/bin/breakpoint        # in shell-form commands (the shell expands $HOME)
/Users/<you>/.breakpoint/bin/breakpoint # where a tool runs the program directly without a shell
```

Pick one stable path with **no spaces** (a symlink into the app bundle is fine). The default
`~/Library/Application Support/...` path contains a space, which every shell-form hook would have
to quote. Do not point hooks straight into `/Applications/Breakpoint.app/...`: if macOS App
Translocation runs the app from a random read-only path, or the user moves the app, the hooks
break.

### 0.3 The "never block, fail silently" recipe

Every tool treats a hook's stdout and exit code as meaningful. The `breakpoint emit` binary must:

1. **Print nothing on stdout, ever.** In Claude Code, plain-text stdout from `UserPromptSubmit` and
   `SessionStart` hooks is **added to the model's context**. Codex adds plain stdout from
   `SessionStart`/`UserPromptSubmit` as developer context and treats plain text from
   `Stop`/`SubagentStop` as invalid. Gemini CLI treats any non-JSON stdout as a failure. Cursor
   permission hooks block on invalid JSON.
2. **Always exit 0**, including when the app is not running, the socket is missing, or stdin is
   malformed. Exit code 2 means "block" in Claude Code, Cursor, Codex and Gemini.
3. **Read stdin to EOF quickly** (the payload is one JSON object), with a size cap of about 1 MB
   and a short read timeout, then send one line to the socket with a connect/write timeout of about
   100 ms and exit. SPEC.md already requires "well under 50 ms".
4. **Not inherit stdout/stderr into any child it leaves running.** Claude Code waits up to 10 s
   for a non-async hook whose background child still holds stdout open.

Wrap each shell-form hook so that a missing binary is a silent no-op too:

```sh
[ -x "$HOME/.breakpoint/bin/breakpoint" ] && "$HOME/.breakpoint/bin/breakpoint" emit agentStarted --source claude-code --stdin-json >/dev/null 2>&1 || true
```

### 0.4 Cross-tool double firing (important)

Several tools read Claude Code's settings files:

| Tool | Reads Claude Code hooks from | Source |
|---|---|---|
| Cursor | `~/.claude/settings.json`, `.claude/settings.json`, `.claude/settings.local.json`, when "Include Third-Party Plugins, Skills, and Other Configs" is on (**on by default**) | cursor.com/docs/reference/third-party-hooks |
| GitHub Copilot CLI | repository `.claude/settings.json` and `.claude/settings.local.json` | docs.github.com hooks reference |
| VS Code agent hooks | Claude settings files, only when `chat.useClaudeHooks` is enabled (off by default) | code.visualstudio.com hooks page |

So a Breakpoint hook installed in `~/.claude/settings.json` **also runs inside Cursor** and reports
itself as `--source claude-code`. Mitigations:

- Install Claude Code hooks only at **user level** (`~/.claude/settings.json`), never in a project's
  `.claude/settings.json` (Copilot CLI reads those).
- In `breakpoint emit --stdin-json`, **detect the real host from the payload and environment**
  before trusting `--source`. Cursor payloads always carry `cursor_version`, `conversation_id` and
  `workspace_roots`, and Cursor sets `CURSOR_VERSION` in the hook environment. Claude Code sets
  `CLAUDECODE=1` and `CLAUDE_CODE_CHILD_SESSION=1` for hook commands. Cursor also sets
  `CLAUDE_PROJECT_DIR` as a compatibility alias, so that variable is not a discriminator. If
  `cursor_version` is present, treat the event as Cursor (and the app can drop it if the native
  Cursor integration is also installed).
- **UNVERIFIED:** what `hook_event_name` value Cursor passes when it runs a mapped Claude hook
  (Claude-style `Stop` or Cursor-style `stop`).
- **UNVERIFIED:** whether Cursor's third-party import also loads Claude Code *plugins*, such as a
  skills-directory plugin at `~/.claude/skills/<name>/`. If it does, the plugin route has the same
  double-firing risk.

### 0.5 Recommended event mapping (summary)

| Breakpoint kind | Claude Code | Cursor | Codex CLI | Copilot CLI |
|---|---|---|---|---|
| `sessionStarted` | `SessionStart` | `sessionStart` | `SessionStart` | `sessionStart` |
| `agentStarted` | `UserPromptSubmit` | `beforeSubmitPrompt` | `UserPromptSubmit` | `userPromptSubmitted` |
| `agentFinished` | `Stop` + `StopFailure` | `stop` (has `status`) | `Stop` (+ `Interrupt`) | `agentStop` |
| `agentNeedsUser` | `PermissionRequest` (immediate), `Notification` (`permission_prompt`, `elicitation_dialog`, `idle_prompt`), `PreToolUse` matcher `AskUserQuestion` | **none documented** | `PermissionRequest` | `notification` (`permission_prompt`, `elicitation_dialog`) |
| `agentActivity` (optional) | `PostToolUse` | `postToolUse` / `afterAgentResponse` | `PostToolUse` | `postToolUse` |
| `subagentFinished` | `SubagentStop` | `subagentStop` | `SubagentStop` | `subagentStop` |
| `sessionEnded` | `SessionEnd` | `sessionEnd` | `SessionEnd` | `sessionEnd` |
| project folder | `cwd` (changes with `cd`); `$CLAUDE_PROJECT_DIR` is stable | `workspace_roots[0]`, `$CURSOR_PROJECT_DIR` | `cwd` | `cwd` |
| prompt label | `prompt` on `UserPromptSubmit` | `prompt` on `beforeSubmitPrompt` | `prompt` on `UserPromptSubmit` | `prompt` on `userPromptSubmitted` |
| session id | `session_id` | `conversation_id` (`session_id` on session hooks) | `session_id` | `sessionId` / `session_id` |

---

## 1. Claude Code

Sources (all fetched 2026-11-22; `docs.claude.com/en/docs/claude-code/hooks` 301-redirects to
`code.claude.com/docs/en/hooks`; every page is also served as Markdown by appending `.md`):

- Hooks reference: https://code.claude.com/docs/en/hooks
- Hooks guide: https://code.claude.com/docs/en/hooks-guide
- Environment variables: https://code.claude.com/docs/en/env-vars
- Plugins overview: https://code.claude.com/docs/en/plugins/overview
- Create a plugin: https://code.claude.com/docs/en/plugins/create
- Install and manage plugins: https://code.claude.com/docs/en/plugins/install
- Plugin commands (CLI) reference: https://code.claude.com/docs/en/plugins/cli-reference
- Plugin manifest reference: https://code.claude.com/docs/en/plugins/manifest-reference
- Create a marketplace: https://code.claude.com/docs/en/plugins/create-marketplace
- Marketplace reference: https://code.claude.com/docs/en/plugins/marketplace-reference
- Plugin loading reference: https://code.claude.com/docs/en/plugins/loading

Version note: the docs cite feature gates up to v2.1.330 (for example `onFailure` needs v2.1.295 or
later). The snippets below use only long-standing fields (`type`, `command`, `async`, `timeout`,
`matcher`), plus `args` only where stated.

### 1.1 Where hooks run

Claude Code fires the same hook events in the terminal CLI, the IDE extensions, the Desktop app and
cloud sessions. Cloud sessions do not read `~/.claude/settings.json`, so local user hooks never run
there.

### 1.2 Settings file locations

| Location | Scope |
|---|---|
| `~/.claude/settings.json` | user, all projects |
| `.claude/settings.json` | project (committed) |
| `.claude/settings.local.json` | project, local (gitignored when Claude Code writes it) |
| managed policy settings | organization |
| plugin `hooks/hooks.json` | while the plugin is enabled |
| skill / subagent frontmatter | while that skill or subagent is active |

Hooks from all levels are merged (they don't replace each other). The same handler defined in more
than one *settings file* runs once, but a plugin's copy of the same handler stays separate. So
settings.json plus plugin means it runs twice.

Settings-file edits are normally picked up by a file watcher without a restart.

**Workspace trust:** in an interactive session, Claude Code holds back hooks from *every* settings
file, including `~/.claude/settings.json`, until the user accepts the workspace trust dialog for
that folder. In `-p`/SDK sessions the folder is treated as trusted.

**Admin blocks:** `allowManagedHooksOnly` in managed settings blocks user, project, local and
plugin hooks. `disableAllHooks: true` turns all non-managed hooks off.

### 1.3 Config shape and matchers

Three levels: event → matcher group → handlers.

```json
{
  "hooks": {
    "EventName": [
      { "matcher": "optional", "hooks": [ { "type": "command", "command": "..." } ] }
    ]
  }
}
```

Matcher rules:
- `"*"`, `""` or an omitted matcher matches everything.
- A value made only of letters, digits, `_`, `-`, spaces, `,` and `|` is an exact string or a list
  (`Edit|Write`, `Edit, Write`).
- Anything else is an unanchored JavaScript regex.
- `FileChanged` and `StopFailure` accept only letters, digits, `_` and `|` as exact-match
  characters.
- Matchers are case-sensitive.
- Events with no matcher support (`UserPromptSubmit`, `Stop`, `PostToolBatch`, `TeammateIdle`,
  `TaskCreated`, `TaskCompleted`, `WorktreeCreate`, `WorktreeRemove`, `MessageDisplay`,
  `CwdChanged`) silently ignore one.

What each event's matcher filters:

| Event | Matcher filters | Values |
|---|---|---|
| `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `PermissionRequest`, `PermissionDenied` | tool name | `Bash`, `Edit\|Write`, `mcp__.*` |
| `SessionStart` | start source | `startup`, `resume`, `clear`, `compact`, `fork` |
| `SessionEnd` | end reason | `clear`, `resume`, `logout`, `prompt_input_exit`, `other` |
| `Notification` | notification type | see 1.6 |
| `SubagentStart`, `SubagentStop` | agent type | `general-purpose`, `Explore`, `Plan`, custom names, `^plugin:name$` |
| `StopFailure` | error type | `rate_limit`, `authentication_failed`, `server_error`, `max_output_tokens`, `unknown`, ... |
| `PreCompact`, `PostCompact` | trigger | `manual`, `auto` |

`if` (on a handler) takes one permission rule such as `"Bash(git *)"` and works only on tool events.

### 1.4 Handler types

| `type` | What it does | Events |
|---|---|---|
| `command` | runs a shell command (or an executable with `args`). Input on stdin | all |
| `http` | POSTs the input JSON to `url` | all except `SessionStart` and `Setup` |
| `mcp_tool` | calls a tool on a configured MCP server | most; skipped on launch `SessionStart` and `Setup` |
| `prompt` | single-turn LLM yes/no | subset (tool events, Stop, UserPromptSubmit, ...) |
| `agent` | subagent verifier (experimental) | subset |

`SessionStart` supports only `command` and `mcp_tool`. `Setup` supports only `command`.

**Common fields** (all types):
- `type`
- `if`
- `timeout` (seconds; see below)
- `statusMessage` (spinner text)
- `once` (honored only in skill frontmatter)

**Command fields:**
- `command`: shell string, or the executable when `args` is set.
- `args`: exec form, no shell; placeholders like `${CLAUDE_PLUGIN_ROOT}` are substituted as plain
  strings.
- `async`: true runs in the background without blocking.
- `asyncRewake`: background; wakes Claude on exit 2.
- `shell`: `"bash"` or `"powershell"`.
- `onFailure`: `"continue"` or `"block"`; v2.1.295 or later.

Shell form runs through `sh -c` on macOS. Placeholders `${CLAUDE_PROJECT_DIR}`,
`${CLAUDE_PLUGIN_ROOT}` and `${CLAUDE_PLUGIN_DATA}` are also exported as environment variables.

**HTTP fields:**
- `url`
- `headers` (env interpolation only for names in `allowedEnvVars`)
- `allowedEnvVars`
- `onFailure`

The body is the same JSON, sent with `Content-Type: application/json`. Managed settings may restrict
URLs with `allowedHttpHookUrls`.

**Default timeouts:**

| Hook | Default timeout |
|---|---|
| `command`, `http`, `mcp_tool` | 600 s |
| same three on `UserPromptSubmit`, `PreModelSwitch`, `PostModelSwitch` | 30 s |
| same three on `MessageDisplay` | 10 s |
| `prompt` | 30 s |
| `agent` | 60 s |
| all `SessionEnd` hooks together | 1.5 s shared budget, raised to the largest per-hook `timeout` up to 60 s, or set with `CLAUDE_CODE_SESSIONEND_HOOKS_TIMEOUT_MS` |

A plugin hook's timeout does not raise the SessionEnd budget. **`timeout` is not enforced on
`async: true` command hooks.**

Matching hooks for one event run **in parallel**.

### 1.5 Exit codes, stdout and failure behaviour

| Outcome | Effect |
|---|---|
| exit 0, no output | success, no effect |
| exit 0, one JSON object on stdout | fields applied |
| exit 0, plain text stdout | success. On `UserPromptSubmit`, `UserPromptExpansion`, `SessionStart`, `PostModelSwitch` the text is **added to Claude's context**; on `PreCompact` it becomes compaction instructions |
| exit 2 | blocking error where the event can block (`PreToolUse`, `UserPromptSubmit`, `Stop` keeps Claude working, `SubagentStop`, `PostToolBatch`, `PreCompact`, ...). Ignored on `Notification`, `StopFailure`, `Setup`. Shown to the user only on `SessionStart`, `SessionEnd`, `SubagentStart` |
| any other exit code / cannot start / invalid JSON | **non-blocking error**: the action proceeds. On events such as `PreToolUse` the transcript shows a `<hook name> hook error` notice. On `Notification` a failed command hook shows no notice |
| timeout | hook cancelled, output discarded, action proceeds (unless `onFailure: "block"`) |

The docs warn that a shell profile which echoes text can corrupt JSON output. Hooks run in
non-interactive shells, but `BASH_ENV` and similar can still source a profile. The `[ -x ... ] &&
... >/dev/null 2>&1 || true` wrapper keeps Breakpoint's hooks silent and at exit 0.

HTTP hook responses:
- 2xx with an empty body is success.
- 2xx with a JSON object body is parsed as hook output.
- 2xx with any **other body (plain text) is a non-blocking error**.
- A non-2xx status or a connection failure is a non-blocking error.

So a Breakpoint HTTP listener must answer `204` or `200 {}` and nothing else.

Universal JSON output fields:
- `continue`
- `stopReason`
- `systemMessage`
- `suppressOutput` (no effect)
- `terminalSequence`

Breakpoint should never return any of them.

### 1.6 Events relevant to Breakpoint, with exact stdin JSON

**Common input fields:**

| Field | Notes |
|---|---|
| `session_id` | |
| `prompt_id` | UUID of the current user prompt; absent before the first prompt |
| `transcript_path` | written asynchronously, may lag |
| `cwd` | current working directory when the hook runs; changes when Claude `cd`s |
| `scratchpad_dir` | v2.1.257 or later |
| `permission_mode` | `default`, `plan`, `acceptEdits`, `auto`, `dontAsk`, `bypassPermissions`; not on every event |
| `effort` | `{level}` on tool-context events |
| `hook_event_name` | |
| `agent_id`, `agent_type` | present when the hook fires inside a subagent or with `--agent` |

Environment for hooks:
- `CLAUDE_PROJECT_DIR`: the root where the session started; stays put in worktrees.
- `CLAUDECODE=1`
- `CLAUDE_CODE_CHILD_SESSION=1`
- `CLAUDE_CODE_REMOTE="true"` in web sessions.

Full list of events, for completeness:

| Group | Events |
|---|---|
| Session | `SessionStart`, `Setup`, `SessionEnd` |
| Prompt and display | `UserPromptSubmit`, `UserPromptExpansion`, `MessageDisplay`, `InstructionsLoaded` |
| Tools and permissions | `PreToolUse`, `PermissionRequest`, `PermissionDenied`, `PostToolUse`, `PostToolUseFailure`, `PostToolBatch` |
| Subagents, tasks, teams | `SubagentStart`, `SubagentStop`, `TaskCreated`, `TaskCompleted`, `TeammateIdle` |
| Turn end | `Stop`, `StopFailure` |
| Notifications | `Notification` |
| Config and environment | `ConfigChange`, `CwdChanged`, `DirectoryAdded`, `FileChanged` |
| Worktrees | `WorktreeCreate`, `WorktreeRemove` |
| Compaction | `PreCompact`, `PostCompact` |
| Model switching | `PreModelSwitch`, `PostModelSwitch` |
| MCP elicitation | `Elicitation`, `ElicitationResult` |

The ones Breakpoint needs:

**SessionStart.** Fires when a session begins or resumes. Command and `mcp_tool` handlers only (no
HTTP). Event-specific fields:
- `source`: `startup`, `resume`, `clear`, `compact` or `fork`.
- `model`: optional.
- `agent_type`: with `--agent`.
- `session_title`: when a custom title is set.
- On resume/fork from v2.1.251: `seconds_since_last_response`, `context_tokens`,
  `prompt_cache_likely_expired`, `estimated_cache_write_usd`.

Interactive SessionStart hooks already run in the background, but Claude's *first response* waits
for them.

```json
{"session_id":"abc123","transcript_path":"/Users/.../.claude/projects/.../00893aaf-....jsonl",
 "cwd":"/Users/...","hook_event_name":"SessionStart","source":"startup","model":"claude-opus-5"}
```

**UserPromptSubmit.** Fires when a prompt is submitted, before Claude processes it. It also fires
for turns Claude Code starts on its own:
- a session-scoped scheduled task or `/loop` iteration
- a background subagent reporting back
- a message from another session

Fields:
- `prompt`: pasted text is expanded, possibly wrapped in `<pasted_content id=...>` lines. A slash
  command arrives as typed (`/deploy staging`).
- `session_title`: optional.

The default timeout is 30 s and the hook blocks model processing until it completes, so it must be
`async`.

```json
{"session_id":"abc123","transcript_path":"...","cwd":"/Users/...","permission_mode":"default",
 "hook_event_name":"UserPromptSubmit","prompt":"Write a function to calculate the factorial of a number"}
```

**Stop.** Fires when the main agent finishes responding. It does **not** fire on a user interrupt
(Esc), and API errors fire `StopFailure` instead. Fields:
- `stop_hook_active`
- `last_assistant_message`
- `background_tasks`: array of in-flight tasks: `id`, `type` (`shell`, `subagent`, `monitor`,
  `workflow`, ...), `status`, `description`, ...
- `session_crons`: array

The two arrays let a hook tell "done" from "paused waiting for background work".

```json
{"session_id":"abc123","transcript_path":"...","cwd":"/Users/...","permission_mode":"default",
 "hook_event_name":"Stop","stop_hook_active":false,
 "last_assistant_message":"I've completed the refactoring...","background_tasks":[],"session_crons":[]}
```

**StopFailure.** Fires when the turn ends due to an API error. Output and exit code are ignored.
Fields:
- `error`: `rate_limit`, `authentication_failed`, `oauth_org_not_allowed`, `account_on_hold`,
  `billing_error`, `invalid_request`, `model_not_found`, `server_error`, `max_output_tokens`,
  `cloud_credential_error` or `unknown`.
- `error_details`: optional.
- `last_assistant_message`: the API error string.

**Notification.** Fires when Claude Code sends a notification, even with desktop notifications
turned off. Fields: `message`, optional `title`, and `notification_type`. Types (also the matcher
values):

| Type | When it fires |
|---|---|
| `permission_prompt` | a permission prompt has waited about **6 s** with no typing; each keystroke defers it. In Desktop/VS Code (`canUseTool` hosts) it fires about 6 s after the request without deferral; v2.1.233 or later |
| `idle_prompt` | about **60 s** after Claude finished responding with no typing, and only if no background agent is running |
| `elicitation_dialog`, `elicitation_url_dialog` | MCP asks for input; about 6 s |
| `elicitation_complete`, `elicitation_response` | |
| `agent_needs_input`, `agent_completed` | background sessions, while agent view is open |
| `auth_success`, `auth_storage_failure` | |
| `quota_auto_resume_fired`, `quota_auto_resume_stale`, `quota_auto_resume_disabled` | usage-limit pauses |
| `plugin_notification` | |

Notification hooks cannot block. Exit code and stderr are ignored.

```json
{"session_id":"abc123","transcript_path":"...","cwd":"/Users/...","hook_event_name":"Notification",
 "message":"Claude needs your permission","notification_type":"permission_prompt"}
```

**PermissionRequest.** Fires the moment Claude Code is about to show a permission dialog, with no
6-second delay. Use this for an immediate `agentNeedsUser`. Fields:
- `tool_name`
- `tool_input`
- `permission_suggestions`: optional
- `mcp_server`: for MCP tools

There is no `tool_use_id`. Matcher: tool name.

Caveats:
- In sessions that cannot show a prompt (non-interactive background subagents), it still runs, and
  a call nobody decides is denied.
- It does not fire for a sandboxed command's network request. `Notification`/`permission_prompt`
  covers that case.
- A hook that returns no decision leaves the normal dialog in place, which is what Breakpoint wants.

**PreToolUse with matcher `AskUserQuestion`.** Signals that Claude is about to ask the user a
multiple-choice question. Documented tool input sections exist for `AskUserQuestion` and
`ExitPlanMode`. This is the "needs input, no permission involved" case.

**SubagentStop.** Fires when a subagent finishes. Fields:
- `stop_hook_active`
- `agent_id`
- `agent_type`
- `agent_transcript_path`
- `last_assistant_message`
- `background_tasks`
- `session_crons`

It also fires for Claude Code's internal agents (prompt suggestions, `/btw`), with `agent_type` set
to the session's own agent name or `""`. Filter those out, for example by ignoring an empty
`agent_type`.

**SessionEnd.** Fires when a session terminates. Field `reason`: `clear`, `resume`, `logout`,
`prompt_input_exit` or `other`. JSON output is discarded. The 1.5 s shared budget applies.

**PostToolUse.** Optional `agentActivity` heartbeat. Fields: `tool_name`, `tool_input`,
`tool_response`, `tool_use_id`. It fires on every tool call, so it is chatty; use it only if the
app needs "working again after waiting" (for example after the user approves a permission).

### 1.7 Making Claude Code hooks never block

- `"async": true` on a command hook starts it and continues immediately.
  - Async output (`additionalContext`/`systemMessage`) is delivered on the next turn; print nothing.
  - Completion notices are hidden unless verbose mode is on.
  - `timeout` is not enforced on async hooks.
  - Under `claude -p`, async hooks still running at teardown are killed.
  - Async is available **only on `type: "command"`**.
  - `terminalSequence` does not work from async hooks (irrelevant to Breakpoint).
- HTTP hooks are always synchronous. Keep `timeout` small (for example `2`). **UNVERIFIED:**
  whether fractional `timeout` values such as `0.5` are accepted.
- For `SessionEnd`, prefer a **synchronous** hook with `"timeout": 2`, because the session is
  shutting down. **UNVERIFIED:** whether an async `SessionEnd` hook survives process exit in an
  interactive session. A fast synchronous CLI (under 50 ms) is safely inside the 1.5 s budget.

### 1.8 Ready-to-use config (settings.json, user level)

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "async": true,
        "command": "[ -x \"$HOME/.breakpoint/bin/breakpoint\" ] && \"$HOME/.breakpoint/bin/breakpoint\" emit sessionStarted --source claude-code --stdin-json >/dev/null 2>&1 || true" } ] }
    ],
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "async": true,
        "command": "[ -x \"$HOME/.breakpoint/bin/breakpoint\" ] && \"$HOME/.breakpoint/bin/breakpoint\" emit agentStarted --source claude-code --stdin-json >/dev/null 2>&1 || true" } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "async": true,
        "command": "[ -x \"$HOME/.breakpoint/bin/breakpoint\" ] && \"$HOME/.breakpoint/bin/breakpoint\" emit agentFinished --source claude-code --stdin-json >/dev/null 2>&1 || true" } ] }
    ],
    "StopFailure": [
      { "hooks": [ { "type": "command", "async": true,
        "command": "[ -x \"$HOME/.breakpoint/bin/breakpoint\" ] && \"$HOME/.breakpoint/bin/breakpoint\" emit agentFinished --source claude-code --stdin-json >/dev/null 2>&1 || true" } ] }
    ],
    "PermissionRequest": [
      { "matcher": "*", "hooks": [ { "type": "command", "async": true,
        "command": "[ -x \"$HOME/.breakpoint/bin/breakpoint\" ] && \"$HOME/.breakpoint/bin/breakpoint\" emit agentNeedsUser --source claude-code --stdin-json >/dev/null 2>&1 || true" } ] }
    ],
    "PreToolUse": [
      { "matcher": "AskUserQuestion", "hooks": [ { "type": "command", "async": true,
        "command": "[ -x \"$HOME/.breakpoint/bin/breakpoint\" ] && \"$HOME/.breakpoint/bin/breakpoint\" emit agentNeedsUser --source claude-code --stdin-json >/dev/null 2>&1 || true" } ] }
    ],
    "Notification": [
      { "matcher": "permission_prompt|elicitation_dialog|elicitation_url_dialog|idle_prompt",
        "hooks": [ { "type": "command", "async": true,
        "command": "[ -x \"$HOME/.breakpoint/bin/breakpoint\" ] && \"$HOME/.breakpoint/bin/breakpoint\" emit agentNeedsUser --source claude-code --stdin-json >/dev/null 2>&1 || true" } ] }
    ],
    "SubagentStop": [
      { "hooks": [ { "type": "command", "async": true,
        "command": "[ -x \"$HOME/.breakpoint/bin/breakpoint\" ] && \"$HOME/.breakpoint/bin/breakpoint\" emit subagentFinished --source claude-code --stdin-json >/dev/null 2>&1 || true" } ] }
    ],
    "SessionEnd": [
      { "hooks": [ { "type": "command", "timeout": 2,
        "command": "[ -x \"$HOME/.breakpoint/bin/breakpoint\" ] && \"$HOME/.breakpoint/bin/breakpoint\" emit sessionEnded --source claude-code --stdin-json >/dev/null 2>&1 || true" } ] }
    ]
  }
}
```

Notes on this config:
- `--stdin-json` must map `hook_event_name` + `notification_type` to a kind, so the kind on the
  command line is a hint. The CLI can also set `kind` from the payload, which makes the mapping
  robust if the app later wants finer kinds such as `idle_prompt` versus `permission_prompt`.
- `idle_prompt` means "finished about 60 s ago and the user hasn't typed". The app may prefer to
  treat it as a reminder that the agent is waiting, not as a fresh state change.
- Label: take the first line of `prompt`, strip `<pasted_content ...>` wrapper lines, and truncate
  to about 80 characters. Keep it local (SPEC privacy setting).

**HTTP alternative** (only if the app listens on TCP; not valid for `SessionStart`):

```json
{ "type": "http", "url": "http://127.0.0.1:47823/v1/hooks/claude-code", "timeout": 2 }
```

The port is an example. HTTP hooks can't be async, so a hung Breakpoint server delays the agent by
up to `timeout` on every event. **UNVERIFIED:** whether a refused connection on `UserPromptSubmit`
or `Stop` shows a visible "hook error" notice. The docs say non-blocking errors show a notice "on
events such as `PreToolUse`", so expect transcript noise when the app is not running. The command
form avoids this.

### 1.9 Install, merge and uninstall (settings.json route)

- **Location:** `~/.claude/settings.json`. Create it with `{}` if absent. Never write
  `.claude/settings.json` in projects (Copilot CLI reads those; see 0.4).
- **Merge:** parse the JSON (it's strict JSON: comments and trailing commas are invalid). If parsing
  fails, refuse and tell the user. For each event, append Breakpoint's matcher group to
  `hooks.<Event>` (create the arrays as needed) and leave every other key and entry untouched.
- **Mark:** identify Breakpoint handlers by the substring `/.breakpoint/bin/breakpoint" emit` plus
  `--source claude-code` in `command`. JSON has no comments, so the command string is the marker.
- **Idempotent:** skip any event that already has a marked handler.
- **Write safely:** back up first (SPEC: `backups/`). Re-read immediately before writing, because
  Claude Code itself writes this file (for example when the user saves a permission rule). Write to
  a temp file in the same directory, `rename` atomically, and keep the existing file mode.
- **Uninstall:** remove only marked handler objects, then any matcher group whose `hooks` array is
  now empty, then any event whose array is empty, then `hooks` if empty. Leave the rest
  byte-for-byte where possible (re-serialising may reorder keys; preserve order and 2-space
  indentation).
- Changes are picked up by the file watcher. The user can confirm with `/hooks` (read-only browser)
  in Claude Code.

### 1.10 Alternative: ship Breakpoint as a Claude Code plugin

A plugin is a directory with `.claude-plugin/plugin.json` (the manifest; only `name` is required)
and components at the plugin root. Hooks live in `hooks/hooks.json`, which has the same shape as
`hooks` in settings.json **wrapped in a top-level `"hooks"` key**. A file containing only the event
map fails to load. The manifest may also declare `"hooks"` as a path, an inline object or an array;
these merge with `hooks/hooks.json`. Plugin hooks get `${CLAUDE_PLUGIN_ROOT}` and
`${CLAUDE_PLUGIN_DATA}`.

```
breakpoint-claude/
├── .claude-plugin/
│   └── plugin.json        {"name":"breakpoint","description":"Break reminders that wait for your agent","version":"1.0.0"}
└── hooks/
    └── hooks.json         {"hooks": { ...same event map as section 1.8... }}
```

Three ways to get it loaded:

1. **Skills-directory plugin** (simplest; no marketplace, no install command). A folder under
   `~/.claude/skills/` containing `.claude-plugin/plugin.json` loads in every session as
   `<name>@skills-dir`. The plugin-loading page confirms that a skipped skills-dir plugin's "hooks
   and MCP servers" are missing, so hooks are supported there.
   - Install: copy the folder to `~/.claude/skills/breakpoint/`.
   - Uninstall: delete the folder, or `claude plugin disable breakpoint@skills-dir`.
   - Blocked silently by `strictPluginOnlyCustomization`, a `strictKnownMarketplaces` allowlist
     without `skills-dir`, or `blockedMarketplaces`.
   - `claude plugin init` also writes a root `SKILL.md`. **UNVERIFIED:** whether a skills-dir plugin
     with no `SKILL.md` and only `hooks/` loads. Test it.
   - Running sessions need `/reload-plugins` or a restart.
2. **Local marketplace + install:**
   - Marketplace file at `<dir>/.claude-plugin/marketplace.json`:
     `{"name":"breakpoint","owner":{"name":"Breakpoint"},"plugins":[{"name":"breakpoint","source":"./plugins/breakpoint"}]}`.
     The `name`, `owner` and `plugins` fields are required. Relative sources start at the
     marketplace root and must not contain `..`. Keep the entry name equal to the manifest name.
   - Install: `claude plugin marketplace add "<dir>"` then
     `claude plugin install breakpoint@breakpoint` (user scope by default; `--json` gives a
     machine-readable last line).
   - Uninstall: `claude plugin uninstall breakpoint@breakpoint`, or
     `claude plugin marketplace remove breakpoint`, which removes the marketplace and uninstalls
     its plugins.
   - A local-directory marketplace with relative-path sources is read in place, so copy it to
     `~/Library/Application Support/Breakpoint/claude-marketplace/` first, not inside the app bundle.
3. **Git repository marketplace:** `claude plugin marketplace add owner/repo` (or a full git URL,
   with `#ref` to pin), then install as above. Needs the network and git credentials, so it is not
   suitable for an offline local app.

Plugin pitfalls:
- The app must find the `claude` executable (not necessarily on a GUI app's `PATH`).
- Installing via `/plugin` inside a session opens a review panel. `claude plugin install` from the
  shell does not prompt for plain plugins.
- Settings-file hooks and plugin hooks with the same handler both run. Use one route only.
- Prefer exec form (`"command": "...", "args": [...]`) in plugins when referencing
  `${CLAUDE_PLUGIN_ROOT}`. But exec form fails noisily ("can't start" = non-blocking error notice)
  if the Breakpoint binary is gone, so for silent failure use a shell-form wrapper, or point
  `command` at a tiny script inside the plugin that checks for the binary.

### 1.11 Known pitfalls (Claude Code)

- **No event on user interrupt.** `Stop` does not fire when the user presses Esc. **UNVERIFIED:**
  any documented event for "turn interrupted". The app needs a fallback, for example treating a
  session as idle when `transcript_path` stops changing for N seconds, or on the next
  `UserPromptSubmit`/`SessionEnd`.
- **`Notification` is delayed** (about 6 s for permission, about 60 s for idle). Use
  `PermissionRequest` and `PreToolUse:AskUserQuestion` for immediate signals.
- **`UserPromptSubmit` also fires for autonomous turns** (scheduled tasks, `/loop`, background
  subagent reports, cross-session messages). It is still "agent working", but the "prompt" may not
  be something the user typed.
- **Subagents fire tool hooks** with `agent_id`/`agent_type` set. Ignore tool events carrying
  `agent_id` if only the main agent matters.
- **Workspace trust** gates all settings-file hooks in interactive sessions until trust is
  accepted.
- **Stdout pollution:** plain-text stdout on `UserPromptSubmit`/`SessionStart` is injected into
  the model context.
- **Cursor runs these hooks too** (see 0.4).
- **Cloud/web sessions** don't run user-level hooks.
- **`cwd` vs project:** `cwd` follows Claude's `cd`; use `$CLAUDE_PROJECT_DIR` (env) for the
  stable project root. The CLI can read it from the environment.

---

## 2. Cursor

Sources (fetched 2026-11-22; Cursor serves Markdown at `<page>.md`;
`https://cursor.com/docs/agent/hooks` redirects to `https://cursor.com/docs/hooks`):

- Hooks: https://cursor.com/docs/hooks (Markdown: https://cursor.com/docs/hooks.md)
- Third-party hooks (Claude Code compatibility): https://cursor.com/docs/reference/third-party-hooks
- Plugins: https://cursor.com/docs/plugins
- Plugins reference: https://cursor.com/docs/reference/plugins
- CLI changelog (hook support in the `agent` CLI): https://cursor.com/docs/cli/changelog

### 2.1 Locations and precedence

| Source | Path | Command working dir |
|---|---|---|
| Enterprise (MDM) | macOS `/Library/Application Support/Cursor/hooks.json` | enterprise config dir |
| Team | dashboard, Enterprise only | managed hooks dir |
| Project | `<project>/.cursor/hooks.json` (trusted workspaces only) | **project root** |
| User | `~/.cursor/hooks.json` | **`~/.cursor/`** |
| Plugins | plugin `hooks/hooks.json` | plugin install dir (`$CURSOR_PLUGIN_ROOT`); `stop`/`subagentStop` plugin hooks run from the workspace root |
| Claude Code files | see 0.4 | |

All matching hooks from every source run. Cursor watches `hooks.json` files and reloads them on
save; restart Cursor if they don't load. Debugging: the Hooks tab in **Customize** and a "Hooks"
output channel.

The Cursor CLI (`agent`) also runs hooks; its changelog documents hook fixes and plugin hooks.
Cloud agents run only project hooks (not `~/.cursor/hooks.json`) and skip `sessionStart`/`sessionEnd`.

### 2.2 Config shape

```json
{
  "version": 1,
  "hooks": {
    "eventName": [ { "command": "...", "timeout": 5, "matcher": "regex", "failClosed": false } ]
  }
}
```

Per-hook options:
- `command`: required; a shell string or path.
- `type`: `"command"` (default) or `"prompt"`.
- `timeout`: seconds; the default is a "platform default", **UNVERIFIED** value.
- `loop_limit`: for `stop`/`subagentStop`.
- `failClosed`: default false.
- `matcher`: a regex.

There is **no async/background option** and **no HTTP handler type**.

### 2.3 Events

Agent events:
- `sessionStart`, `sessionEnd`
- `preToolUse`, `postToolUse`, `postToolUseFailure`
- `subagentStart`, `subagentStop`
- `beforeShellExecution`, `afterShellExecution`
- `beforeMCPExecution`, `afterMCPExecution`
- `beforeReadFile`, `afterFileEdit`
- `beforeSubmitPrompt`
- `preCompact`
- `stop`
- `afterAgentResponse`, `afterAgentThought`

Tab events: `beforeTabFileRead`, `afterTabFileEdit`. App lifecycle: `workspaceOpen`.

Common input on every agent hook:

```json
{ "conversation_id": "string", "generation_id": "string", "model": "string", "model_id": "string",
  "model_params": [{"id":"string","value":"string"}], "hook_event_name": "string",
  "cursor_version": "string", "workspace_roots": ["<path>"], "user_email": "string | null",
  "transcript_path": "string | null" }
```

Environment:
- `CURSOR_PROJECT_DIR`
- `CURSOR_VERSION`
- `CURSOR_USER_EMAIL`
- `CURSOR_TRANSCRIPT_PATH`
- `CURSOR_CODE_REMOTE`
- `CURSOR_PLUGIN_ROOT`
- `CLAUDE_PROJECT_DIR` (compatibility alias)

Variables returned by a `sessionStart` hook's `env` output are passed to later hooks in that
session.

Event-specific inputs Breakpoint needs:

| Event | Extra input fields | Output and blocking |
|---|---|---|
| `sessionStart` | `session_id` (= `conversation_id`), `is_background_agent`, `composer_mode` (`agent`/`ask`/`edit`) | fire-and-forget; "the agent loop does not wait for or enforce a blocking response" |
| `beforeSubmitPrompt` | `prompt`, `attachments[]` | output `{continue, user_message}`; runs "right after user hits send but before backend request", so it **is in the critical path** |
| `stop` | `status`: `completed` \| `aborted` \| `error`, `loop_count` | optional `followup_message`; never return one |
| `afterAgentResponse` | `text` | observational |
| `postToolUse` | `tool_name`, `tool_input`, `tool_output`, `tool_use_id`, `cwd`, `duration` | observational |
| `subagentStop` | `subagent_type`, `status`, `task`, `description`, `summary`, `duration_ms`, `modified_files`, `agent_transcript_path`, ... | optional `followup_message`; never return one |
| `sessionEnd` | `session_id`, `reason` (`completed`, `aborted`, `error`, `window_close`, `user_close`), `duration_ms`, `is_background_agent`, `final_status`, `error_message` | fire-and-forget; output ignored |

**Permission hooks — avoid them:** `beforeShellExecution`, `beforeMCPExecution`, `beforeReadFile`,
`beforeTabFileRead`, `subagentStart` and `preToolUse`. For these, "invalid JSON or a response that
doesn't match the hook's schema blocks the action" even with `failClosed: false`. **UNVERIFIED:**
whether empty stdout counts as invalid. Returning `{"permission":"allow"}` to be safe could
**auto-approve** actions the user would otherwise be asked about. Breakpoint must not register on
any of them.

Exit codes: 0 means use the JSON output; 2 blocks (equivalent to `permission: "deny"`); others
fail open.

### 2.4 Needs-user signal

**None documented.** Cursor has no `Notification` or `PermissionRequest` event, and the
third-party mapping table lists Claude's `Notification` and `PermissionRequest` as unsupported.
Approval prompts happen inside the permission flow, which Breakpoint can't observe without
answering it. Treat Cursor sessions as two-state (working / finished), or infer "probably waiting"
from a long gap after `preToolUse`. That is a heuristic and **UNVERIFIED**.

### 2.5 Ready-to-use config (`~/.cursor/hooks.json`)

User hooks run with cwd `~/.cursor/`, so use absolute paths.

```json
{
  "version": 1,
  "hooks": {
    "sessionStart":       [ { "command": "[ -x \"$HOME/.breakpoint/bin/breakpoint\" ] && \"$HOME/.breakpoint/bin/breakpoint\" emit sessionStarted --source cursor --stdin-json >/dev/null 2>&1 || true", "timeout": 2 } ],
    "beforeSubmitPrompt": [ { "command": "[ -x \"$HOME/.breakpoint/bin/breakpoint\" ] && \"$HOME/.breakpoint/bin/breakpoint\" emit agentStarted --source cursor --stdin-json >/dev/null 2>&1 || true", "timeout": 2 } ],
    "stop":               [ { "command": "[ -x \"$HOME/.breakpoint/bin/breakpoint\" ] && \"$HOME/.breakpoint/bin/breakpoint\" emit agentFinished --source cursor --stdin-json >/dev/null 2>&1 || true", "timeout": 2 } ],
    "subagentStop":       [ { "command": "[ -x \"$HOME/.breakpoint/bin/breakpoint\" ] && \"$HOME/.breakpoint/bin/breakpoint\" emit subagentFinished --source cursor --stdin-json >/dev/null 2>&1 || true", "timeout": 2 } ],
    "sessionEnd":         [ { "command": "[ -x \"$HOME/.breakpoint/bin/breakpoint\" ] && \"$HOME/.breakpoint/bin/breakpoint\" emit sessionEnded --source cursor --stdin-json >/dev/null 2>&1 || true", "timeout": 2 } ]
  }
}
```

Optional heartbeat: `"postToolUse": [ { "command": "... emit agentActivity --source cursor --stdin-json ..." } ]`.

Notes:
- **UNVERIFIED:** whether Cursor runs `command` through a shell on macOS so that `$HOME`, `[ ]`,
  `&&` and redirects work. The docs say `command` "can be a shell string", and the examples include
  `bun run ...` and `python3 ...`, which suggests a shell. If not, write the absolute path and put
  the guard logic in a wrapper script at `~/.breakpoint/bin/cursor-hook`.
- **UNVERIFIED:** whether `beforeSubmitPrompt` treats empty stdout as "continue". It is not in the
  permission-hook list, and other failures fail open. If testing shows empty output blocks the
  prompt, have the CLI print exactly `{"continue":true}` for this event only, behind a flag.
- `stop.status` (`completed`/`aborted`/`error`) gives Cursor the interrupt signal that Claude Code
  lacks.
- `cwd`: Cursor's prompt and stop payloads don't include `cwd`. Use `workspace_roots[0]` (may hold
  several roots) or `$CURSOR_PROJECT_DIR`.
- **Non-blocking:** Cursor waits for the command. A sub-50 ms CLI is effectively free. If extra
  safety is needed, the CLI can read stdin, then fork and detach the socket write.

### 2.6 Install, merge and uninstall

- Location: `~/.cursor/hooks.json`. Create `{"version":1,"hooks":{}}` if missing. If it exists,
  require `version: 1`.
- Merge: append Breakpoint objects to each event array. Mark them by the command substring
  `--source cursor` plus the Breakpoint binary path. Same backup, atomic-write and idempotence rules
  as 1.9.
- Uninstall: remove the marked objects, then empty arrays. Leave `version` and every foreign entry.
- **Plugin alternative (cleaner removal):** put a Cursor plugin in
  `~/.cursor/plugins/local/breakpoint/` with `.cursor-plugin/plugin.json` (`{"name":"breakpoint",...}`)
  and `hooks/hooks.json` (`{"hooks":{...}}`).
  - Requires a restart or **Developer: Reload Window**.
  - Uninstall by deleting the folder.
  - Symlinks are only followed if they resolve inside that folder, so copy files rather than
    symlinking to the app bundle.
  - On Enterprise, "Allow Local Plugin Imports" is **off by default**.
  - Plugin hooks run command hooks only.
  - **UNVERIFIED:** whether a plugin `hooks/hooks.json` requires `"version": 1` (the reference
    example omits it).

### 2.7 Known pitfalls (Cursor)

- Claude Code user hooks also run in Cursor by default (see 0.4). If both integrations are
  installed, every Cursor event arrives twice: once as `--source cursor`, once mislabeled
  `claude-code`. The CLI must detect `cursor_version` in the payload.
- No needs-user event.
- `beforeSubmitPrompt` sits in the send path, so keep it fast.
- Hooks from all sources merge; Breakpoint's entries can't interfere with others as long as they
  return nothing.

---

## 3. OpenAI Codex CLI

Sources (fetched 2026-11-22):

- Hooks: https://developers.openai.com/codex/hooks (Markdown: `.../codex/hooks.md`)
- Advanced config (notify): https://developers.openai.com/codex/config-advanced
- Basic config: https://developers.openai.com/codex/config-basic
- Config reference: https://developers.openai.com/codex/config-reference
- Repo docs (point to the above): https://github.com/openai/codex/blob/main/docs/config.md
- `notify` implementation: https://github.com/openai/codex/blob/main/codex-rs/hooks/src/legacy_notify.rs
- Generated hook schemas: https://github.com/openai/codex/tree/main/codex-rs/hooks/schema/generated
- Plugin packaging: https://developers.openai.com/plugins/build/plugins

Codex has a full hooks system (enabled by default) modelled on Claude Code's, besides the older
`notify`. **Prefer hooks**; keep `notify` as a fallback for old versions.

### 3.1 Hooks: locations

| Scope | File |
|---|---|
| System | `/etc/codex/hooks.json` |
| User | `$CODEX_HOME/hooks.json`, default `~/.codex/hooks.json` |
| Trusted project | `.codex/hooks.json` (walked from project root to cwd; only for trusted projects) |
| Inline | `[hooks]` tables in `config.toml` in the same directories |
| Plugins | `hooks/hooks.json` in an enabled plugin, or the manifest `hooks` entry in `.codex-plugin/plugin.json` |
| Managed | `[hooks]` in `requirements.toml` |

If one layer has both `hooks.json` and inline `[hooks]`, both load with a startup warning. Hooks on
or off: `[features] hooks = false` (`codex_hooks` is a deprecated alias). `allow_managed_hooks_only`
in `requirements.toml` blocks user hooks.

**Trust requirement (major pitfall):** before a non-managed hook can run, the user must review and
trust the exact hook definition in `/hooks` (CLI) or **Settings > Hooks** (desktop app). Trust is
recorded against a hash, so **any change to the hook definition re-requires review**, and untrusted
hooks are skipped (Codex prints a startup warning). For plugin hooks, a changed bundled script
also requires re-review. `--dangerously-bypass-hook-trust` works per invocation only. So:

- After installing, the app must tell the user to open `/hooks` in Codex and trust the Breakpoint
  entries.
- Keep the command strings byte-for-byte stable across app versions; never rewrite them needlessly.

### 3.2 Config shape (Claude-compatible)

```json
{ "hooks": { "Event": [ { "matcher": "...", "hooks": [ { "type": "command", "command": "...",
  "timeout": 600, "async": false, "statusMessage": "..." } ] } ] } }
```

- Handler types: `command` and `mcp_tool` (`prompt`/`agent` are parsed but skipped). No HTTP.
- `timeout` is in seconds, default 600. **`SessionEnd` and `Interrupt` default to 1 s, maximum
  3 s.**
- `async: true` runs a command hook in the background. Async hooks:
  - can't block or decide;
  - have output delivered at the next safe point;
  - are capped at 8 concurrent per session;
  - are cancelled when the session ends;
  - **do not apply to `SessionEnd`, which is always synchronous.**
- Commands run with the session `cwd` as working directory. Matching command hooks for one event
  run concurrently.
- Matcher is a regex. `UserPromptSubmit`, `Stop` and `Interrupt` ignore matchers.

### 3.3 Events and payloads

Events:
- `SessionStart`, `SessionEnd`
- `UserPromptSubmit`
- `PreToolUse`, `PermissionRequest`, `PostToolUse`
- `PreCompact`, `PostCompact`
- `SubagentStart`, `SubagentStop`
- `Stop`
- `Interrupt`
- `PreModelRequest`, `PostModelRequest`

Common input fields:

| Field | Notes |
|---|---|
| `session_id` | subagent hooks get the parent's |
| `transcript_path` | not a stable interface |
| `cwd` | |
| `hook_event_name` | |
| `model` | |
| `turn_id` | on turn-scoped events |
| `permission_mode` | on most events |

| Event | Extra fields | Stdout rules |
|---|---|---|
| `SessionStart` | `source` (`startup`, `resume`, `clear`, `compact`, `fork`) | plain text becomes developer context. Print nothing |
| `UserPromptSubmit` | `turn_id`, `prompt` | plain text becomes developer context. Print nothing |
| `Stop` | `turn_id`, `stop_hook_active`, `last_assistant_message` | "expects JSON on stdout when it exits 0; plain text is invalid". Exit 0 with **no** output is success |
| `PermissionRequest` | `turn_id`, `tool_name`, `tool_input` (with optional `description`) | no decision keeps the normal approval prompt |
| `SubagentStop` | `turn_id`, `agent_id`, `agent_type`, `agent_transcript_path`, `stop_hook_active`, `last_assistant_message` | JSON only |
| `Interrupt` | `turn_id`, `permission_mode` | 1 s default timeout; JSON or nothing |
| `SessionEnd` | `reason` (always `other` today) | sync, 1 s default, 3 s max |

`SessionEnd` runs when the main thread is archived or deleted while open, when Codex closes
normally, or after 30 minutes idle with no connected client. It does not run for subagents.

Example (`SessionEnd`, from the docs):

```json
{"session_id":"thr_123","transcript_path":"/workspace/.codex/rollout.jsonl","cwd":"/workspace",
 "hook_event_name":"SessionEnd","reason":"other"}
```

### 3.4 Ready-to-use config (`~/.codex/hooks.json`)

```json
{
  "description": "Breakpoint break-reminder integration",
  "hooks": {
    "SessionStart":      [ { "hooks": [ { "type": "command", "async": true, "command": "[ -x \"$HOME/.breakpoint/bin/breakpoint\" ] && \"$HOME/.breakpoint/bin/breakpoint\" emit sessionStarted --source codex --stdin-json >/dev/null 2>&1 || true" } ] } ],
    "UserPromptSubmit":  [ { "hooks": [ { "type": "command", "async": true, "command": "[ -x \"$HOME/.breakpoint/bin/breakpoint\" ] && \"$HOME/.breakpoint/bin/breakpoint\" emit agentStarted --source codex --stdin-json >/dev/null 2>&1 || true" } ] } ],
    "PermissionRequest": [ { "hooks": [ { "type": "command", "async": true, "command": "[ -x \"$HOME/.breakpoint/bin/breakpoint\" ] && \"$HOME/.breakpoint/bin/breakpoint\" emit agentNeedsUser --source codex --stdin-json >/dev/null 2>&1 || true" } ] } ],
    "Stop":              [ { "hooks": [ { "type": "command", "async": true, "command": "[ -x \"$HOME/.breakpoint/bin/breakpoint\" ] && \"$HOME/.breakpoint/bin/breakpoint\" emit agentFinished --source codex --stdin-json >/dev/null 2>&1 || true" } ] } ],
    "Interrupt":         [ { "hooks": [ { "type": "command", "timeout": 1, "command": "[ -x \"$HOME/.breakpoint/bin/breakpoint\" ] && \"$HOME/.breakpoint/bin/breakpoint\" emit agentFinished --source codex --stdin-json >/dev/null 2>&1 || true" } ] } ],
    "SubagentStop":      [ { "hooks": [ { "type": "command", "async": true, "command": "[ -x \"$HOME/.breakpoint/bin/breakpoint\" ] && \"$HOME/.breakpoint/bin/breakpoint\" emit subagentFinished --source codex --stdin-json >/dev/null 2>&1 || true" } ] } ],
    "SessionEnd":        [ { "hooks": [ { "type": "command", "timeout": 2, "command": "[ -x \"$HOME/.breakpoint/bin/breakpoint\" ] && \"$HOME/.breakpoint/bin/breakpoint\" emit sessionEnded --source codex --stdin-json >/dev/null 2>&1 || true" } ] } ]
  }
}
```

Notes:
- **UNVERIFIED:** whether `async: true` on `PermissionRequest` is honoured or rejected. The docs
  say async hooks "can't ... approve", which suggests it is allowed but just can't decide. If Codex
  rejects it, use a synchronous hook with `"timeout": 2`.
- **UNVERIFIED:** whether `Stop` exiting 0 with no stdout counts as valid. The docs say both "exit
  0 with no output is treated as success" and "Stop expects JSON on stdout". If needed, the CLI can
  print `{}` for Codex `Stop`/`SubagentStop` only.
- Codex ships `CLAUDE_PLUGIN_ROOT` compatibility for plugins, but Codex does **not** read
  `~/.claude/settings.json` (nothing in its docs says so).

### 3.5 Install, merge and uninstall (hooks)

- `~/.codex/hooks.json` (respect `$CODEX_HOME` if the user has set it; the app can't see the shell
  environment, so offer a path override). Merge, mark (`--source codex`), back up, write atomically
  and uninstall exactly as in 1.9.
- If the user keeps hooks inline in `~/.codex/config.toml`, still use `hooks.json`. Codex loads both
  and only warns.
- After install, instruct the user to open `/hooks` and trust the entries; `breakpoint doctor` should
  report "installed but not yet trusted" if no Codex event arrives.
- Plugin alternative: Codex plugins (`.codex-plugin/plugin.json` + `hooks/hooks.json`) are installed
  through a marketplace (`codex plugin marketplace add ./local-marketplace-root`, then install from
  the Plugins Directory in the app). Plugin hooks also need trust review. This is more steps than
  `hooks.json` and is not recommended.

### 3.6 `notify` (legacy; turn-complete only)

- Setting: top-level `notify` in `~/.codex/config.toml`. It is ignored in project
  `.codex/config.toml`, with a startup warning.
- Shape: argv array. Codex appends **one JSON string as the last argument** (not stdin).
- Only event: `agent-turn-complete`.
- Payload keys: `type`, `thread-id`, `turn-id`, `cwd`, `client` (optional, for example
  `codex-tui`), `input-messages` (array of user messages), `last-assistant-message`.
- From source (`legacy_notify.rs`): the program is spawned with stdin/stdout/stderr set to null and
  **not awaited**, so it can't block Codex. A spawn failure is logged and ignored. The source carries
  a TODO to remove legacy `notify` support, so plan for its removal.

```toml
notify = ["/Users/<you>/.breakpoint/bin/breakpoint", "emit", "agentFinished", "--source", "codex", "--argv-json"]
```

The CLI's `--argv-json` mode takes the trailing argument as the payload. The label comes from `input-messages[0]`, the folder from `cwd`.

Merge and uninstall pitfalls for `notify`:
- `notify` is a **single** key. If the user already has one, Breakpoint can't add a second. Either
  skip and explain, or wrap it: `notify = [".../breakpoint", "codex-notify-chain", "--", <original argv...>]`.
  The CLI forwards the JSON to the original program; uninstall restores the original array.
- Edit TOML with a format-preserving approach that keeps comments and ordering. Swift has no
  standard library for this, so a minimal line-based edit of a top-level `notify = [...]` line
  (between markers) is likely safest. Record the original line in the backup.
- With hooks present, prefer hooks; do not install both, or `agentFinished` arrives twice.

---

## 4. Other agents (short survey)

**GitHub Copilot CLI** (and the Copilot app). Full hook system, documented at
https://docs.github.com/en/copilot/reference/hooks-reference (fetched 2026-11-22 via
`https://docs.github.com/api/article/body?pathname=/en/copilot/reference/hooks-reference`).
- Locations: user hook files are any `*.json` in **`~/.copilot/hooks/`** (or `$COPILOT_HOME/hooks/`).
  Breakpoint can own a single file, `~/.copilot/hooks/breakpoint.json`; install = write, uninstall
  = delete, no merging. Also read: `.github/hooks/*.json`, inline `hooks` in
  `~/.copilot/settings.json` and `.github/copilot/settings*.json`, repo `.claude/settings*.json`,
  plugins, and policy dirs.
- Format: `{"version":1,"hooks":{"agentStop":[{"type":"command","bash":"...","timeoutSec":5}]}}`.
  Command fields: `bash`/`powershell`/`command`, or `exec` + `args`; `cwd`; `env`; `timeoutSec`
  (default 30).
- Events: `sessionStart`, `sessionEnd`, `userPromptSubmitted`, `userPromptTransformed`,
  `preToolUse`, `postToolUse`, `postToolUseFailure`, `agentStop`, `subagentStart`, `subagentStop`,
  `errorOccurred`, `preCompact`, `permissionRequest`, `notification`.
- Payload casing: camelCase event names (`agentStop`) get camelCase fields (`sessionId`, `cwd`,
  `prompt`, `stopReason`); PascalCase names (`Stop`) get the VS Code/Claude-style snake_case
  payload.
- `notification` is **fire-and-forget**, with `notification_type` values `permission_prompt`,
  `elicitation_dialog`, `agent_idle`, `agent_completed`, `shell_completed`,
  `shell_detached_completed`. It is the cleanest needs-user signal of any tool.
- Failure: non-zero exits and timeouts fail open, **except `preToolUse` command hooks, which fail
  closed on crashes and non-zero exits**. Never register on `preToolUse`.
- HTTP hooks exist, but `http://127.*` is only allowed when `COPILOT_HOOK_ALLOW_LOCALHOST=1` is set
  in the CLI's environment, so use command hooks.
- Best mapping:

  | Breakpoint kind | Copilot event |
  |---|---|
  | `agentStarted` | `userPromptSubmitted` |
  | `agentFinished` | `agentStop` |
  | `agentNeedsUser` | `notification` with matcher `permission_prompt\|elicitation_dialog` |
  | `sessionStarted` / `sessionEnded` | `sessionStart` / `sessionEnd` |

**VS Code agent hooks (Copilot in VS Code, Preview).** Documented at
https://code.visualstudio.com/docs/agent-customization/hooks (fetched 2026-11-22). VS Code, the
GitHub Copilot app and Copilot CLI share one harness and hook format. VS Code reads user hook files
from `~/.copilot/hooks/`, so **the same `breakpoint.json` likely covers VS Code too**
(**UNVERIFIED** in practice). It also reads `.github/hooks/*.json`, `chat.hookFilesLocations`, and
agent/plugin hooks. Claude settings files are read only with `chat.useClaudeHooks` (off by
default). Third-party summaries say VS Code supports a subset of about eight events and an output
channel "GitHub Copilot Chat Hooks". The exact VS Code event subset is **UNVERIFIED**; check that
page before relying on `notification` there.

**Gemini CLI.** Documented at https://geminicli.com/docs/hooks/ and
https://geminicli.com/docs/hooks/reference/ (fetched 2026-11-22).
- Hooks live in a `hooks` object in `settings.json`: project `.gemini/settings.json`, user
  `~/.gemini/settings.json`, system `/etc/gemini-cli/settings.json`, plus extensions.
- Events: `SessionStart`, `SessionEnd`, `BeforeAgent`, `AfterAgent`, `BeforeModel`, `AfterModel`,
  `BeforeToolSelection`, `BeforeTool`, `AfterTool`, `PreCompress`, `Notification`.
- Hooks run **synchronously**. `timeout` is in **milliseconds** (default 60000).
- Stdout must be JSON only; any text is treated as a failure/`systemMessage`.
- Exit 2 blocks (on `AfterAgent` it forces a retry).
- `SessionEnd` is best-effort (the CLI doesn't wait).
- Best mapping:

  | Breakpoint kind | Gemini event |
  |---|---|
  | `agentStarted` | `BeforeAgent` (`prompt`) |
  | `agentFinished` | `AfterAgent` |
  | `agentNeedsUser` | `Notification` (`notification_type: "ToolPermission"`) |

- Handler config uses `{"matcher":"*","hooks":[{"name":"...","type":"command","command":"..."}]}`.
- **UNVERIFIED:** whether hooks are on by default in the user's installed version (a Google blog
  says on by default since v0.26.0; older guides say opt-in).

**Windsurf (Cascade).** Search results point to docs at https://docs.windsurf.com/windsurf/cascade/hooks.
That page now serves Devin Desktop documentation; Devin Desktop uses `.devin/hooks.v1.json` per
https://docs.devin.ai/desktop/devin-local/customizations, fetched 2026-11-22. Search snippets
(not fetched primary text) describe Windsurf hooks in `~/.codeium/windsurf/hooks.json` and
`.windsurf/hooks.json`, with events such as `pre_user_prompt` and `post_cascade_response` (async).
All Windsurf details are **UNVERIFIED**; the product appears to be merging into Devin Desktop.

**OpenCode.** Plugins load from `.opencode/plugins/` and `~/.config/opencode/plugins/` (JS/TS
modules), per https://opencode.ai/docs/plugins/ (fetched 2026-11-22). The event names a plugin can
subscribe to (for example `session.idle`) were **not found** on the fetched pages and are
**UNVERIFIED**. An integration would be a small JS plugin calling the CLI, not a JSON config.

**Aider.** No hooks. `--notifications` plus `--notifications-command "<cmd>"` runs a command when
the LLM finishes and aider waits for input (https://aider.chat/docs/usage/notifications.html,
fetched 2026-11-22). That covers `agentFinished` only, with no payload. The integration would be
`--notifications-command "$HOME/.breakpoint/bin/breakpoint emit agentFinished --source aider"` in
`~/.aider.conf.yml` (`notifications-command:` key; **UNVERIFIED** key spelling in YAML). There is
no start signal.

---

## 5. Shell integration (long-running commands)

Sources (fetched 2026-11-22):

- zsh special functions: https://zsh.sourceforge.io/Doc/Release/Functions.html
- zsh `add-zsh-hook`: https://zsh.sourceforge.io/Doc/Release/User-Contributions.html
- Bash manual (`PROMPT_COMMAND`, `trap ... DEBUG`): https://www.gnu.org/software/bash/manual/bash.html
- bash-preexec: https://github.com/rcaloras/bash-preexec (README)
- fish events and `CMD_DURATION`: https://fishshell.com/docs/current/language.html

Facts confirmed from those pages:
- zsh `preexec` runs "just after a command has been read and is about to be executed". `$1` is the
  typed string (when history is active), `$2` and `$3` are expanded forms.
- zsh `precmd` runs "before each prompt".
- `add-zsh-hook` adds functions to the `preexec_functions`/`precmd_functions` arrays.
- Bash: if `PROMPT_COMMAND` is an array (bash 5.1+), each element runs before the prompt. A
  `DEBUG` trap runs before every simple command.
- bash-preexec provides `preexec_functions`/`precmd_functions` for Bash 3.1+ and exposes
  `bash_preexec_imported` for detection.
- fish emits `fish_preexec` and `fish_postexec` (commandline as `$argv[1]`, not emitted for empty
  commands). `CMD_DURATION` is the runtime of the last command in milliseconds.
- macOS still ships `/bin/bash` 3.2.57 (checked on macOS 26, 2026-11-22). It has no
  `EPOCHREALTIME` (bash 5.0+) and no array `PROMPT_COMMAND` (5.1+).

Design (matches SPEC "`commandStarted` = a command that has run at least 20 s"):
- Emit `commandStarted` at preexec, in the background, and `commandFinished` with duration and exit
  code at the next prompt.
- The app decides that a command is "long" when no `commandFinished` arrives within 20 s. The shell
  can't know that at preexec.
- To cut traffic, the snippets skip `commandFinished` for commands under 2 s.
- **Privacy:** send only the command *name* (first word), not the full line. Command lines can
  contain tokens and passwords.
- Interactive TUI commands (`vim`, `nvim`, `less`, `man`, `ssh`, `top`, `htop`, `tmux`, `claude`,
  `codex`, ...) run long but are not "waiting for a build". Filter them in the app with a denylist,
  or with an allowlist of build/test tools.

Testing status (2026-11-22, with a fake `breakpoint` in a throwaway `$HOME`): the zsh and bash
snippets pass `zsh -n` and `/bin/bash -n` (3.2), and calling their preexec/precmd functions
directly sends the expected `commandStarted`/`commandFinished` lines with the right duration and
exit code. This did not exercise a real prompt cycle (DEBUG trap, `PROMPT_COMMAND` order). fish
was not available, so the fish snippet is untested.

All snippets:
- do nothing in non-interactive shells;
- do nothing if the binary is missing (`-x` test, no fork);
- background the CLI with output discarded and no job-control message;
- guard against double-loading.

### 5.1 zsh

Install as `~/.breakpoint/shell/breakpoint.zsh`. Add one line to `${ZDOTDIR:-$HOME}/.zshrc`
between markers.

```zsh
# >>> breakpoint >>>
[[ -r "$HOME/.breakpoint/shell/breakpoint.zsh" ]] && source "$HOME/.breakpoint/shell/breakpoint.zsh"
# <<< breakpoint <<<
```

`breakpoint.zsh`:

```zsh
[[ -o interactive ]] || return 0
(( ${+__bp_loaded} )) && return 0
typeset -g __bp_loaded=1
typeset -g __bp_bin="$HOME/.breakpoint/bin/breakpoint"
typeset -g __bp_t0="" __bp_name=""
zmodload zsh/datetime 2>/dev/null   # provides $EPOCHREALTIME
autoload -Uz add-zsh-hook

__bp_preexec() {
  __bp_t0=$EPOCHREALTIME
  __bp_name=${${(z)1}[1]}             # first word only
  [[ -x $__bp_bin ]] || return
  "$__bp_bin" emit commandStarted --source shell --cwd "$PWD" --title "$__bp_name" &>/dev/null &!
}

__bp_precmd() {
  local ec=$?                         # must be the first statement
  [[ -n $__bp_t0 ]] || return
  local -i ms; ms=$(( (EPOCHREALTIME - __bp_t0) * 1000 ))   # -i truncates the float
  __bp_t0=""
  (( ms >= 2000 )) || return
  [[ -x $__bp_bin ]] || return
  "$__bp_bin" emit commandFinished --source shell --cwd "$PWD" --title "$__bp_name" \
    --duration-ms $ms --exit-code $ec &>/dev/null &!
}

add-zsh-hook preexec __bp_preexec
add-zsh-hook precmd __bp_precmd
# Run first so $? is the user's command status even if other precmd hooks change it:
precmd_functions=(__bp_precmd ${precmd_functions:#__bp_precmd})
```

- `&!` backgrounds and disowns in one step (zsh), so there's no `[1] 12345` job line and no
  "done" message.
- Cost per command is one fork+exec in the background (a few ms, off the prompt's critical path).
- **UNVERIFIED:** whether zsh resets `$?` between `precmd_functions` entries. The snippet moves
  Breakpoint's function first so the question doesn't matter. Prompt frameworks such as
  powerlevel10k may also reorder `precmd_functions`; test with them.
- Uninstall: delete the marker block from `.zshrc` and the file. If only the file is deleted, the
  `-r` guard keeps the shell silent.

### 5.2 bash

Install as `~/.breakpoint/shell/breakpoint.bash`, sourced from **both** `~/.bashrc` and
`~/.bash_profile` with the same marker block. macOS Terminal and iTerm start login shells, which
read `~/.bash_profile` and not `~/.bashrc`. The double-load guard makes sourcing both safe.

```bash
[[ $- == *i* ]] || return 0
[[ -n ${__bp_loaded-} ]] && return 0
__bp_loaded=1
__bp_bin="$HOME/.breakpoint/bin/breakpoint"
__bp_t0=""; __bp_name=""; __bp_armed=0

__bp_now_ms() {                          # bash 5+: EPOCHREALTIME; bash 3.2: whole seconds
  if [[ -n ${EPOCHREALTIME-} ]]; then local t=${EPOCHREALTIME/[.,]/}; echo $(( t / 1000 ));
  else echo $(( SECONDS * 1000 )); fi
}

__bp_preexec() {                         # $1 = command line
  __bp_t0=$(__bp_now_ms); __bp_name=${1%% *}
  [[ -x $__bp_bin ]] || return
  ( "$__bp_bin" emit commandStarted --source shell --cwd "$PWD" --title "$__bp_name" >/dev/null 2>&1 & )
}

__bp_precmd() {
  local ec=$?
  [[ -n $__bp_t0 ]] || return
  local ms=$(( $(__bp_now_ms) - __bp_t0 )); __bp_t0=""
  (( ms >= 2000 )) || return
  [[ -x $__bp_bin ]] || return
  ( "$__bp_bin" emit commandFinished --source shell --cwd "$PWD" --title "$__bp_name" \
      --duration-ms "$ms" --exit-code "$ec" >/dev/null 2>&1 & )
}

if [[ -n ${bash_preexec_imported-} ]]; then
  # bash-preexec already loaded (iTerm2 shell integration and others ship it): use its arrays.
  preexec_functions+=(__bp_preexec)
  precmd_functions=(__bp_precmd "${precmd_functions[@]}")
elif [[ -z $(trap -p DEBUG) ]]; then
  # Minimal self-contained fallback. Only installs when no DEBUG trap exists.
  __bp_debug() {
    [[ $__bp_armed == 1 ]] || return
    [[ -n ${COMP_LINE-} ]] && return     # tab completion
    __bp_armed=0
    __bp_preexec "$BASH_COMMAND"         # first simple command only (bash-preexec uses history)
  }
  __bp_arm() { __bp_armed=1; }
  trap '__bp_debug' DEBUG
  # $? capture must run first; arming must run last, after any other PROMPT_COMMAND entries.
  PROMPT_COMMAND="__bp_precmd${PROMPT_COMMAND:+; $PROMPT_COMMAND}; __bp_arm"
fi
```

Notes:
- `( cmd & )` runs in a subshell, so interactive bash prints no job-control lines. It costs one
  extra fork; acceptable.
- `__bp_now_ms` with `$(...)` forks a subshell on every prompt. To avoid it on bash 5+, inline the
  arithmetic on `EPOCHREALTIME`; the function form is kept for 3.2 compatibility.
- **Pitfall: existing DEBUG trap.** VS Code/Cursor terminal shell integration and other tools may
  install their own `DEBUG` trap or bash-preexec. The snippet uses bash-preexec if present and
  otherwise refuses to overwrite a foreign DEBUG trap; the integration then silently does nothing.
  An alternative is to vendor bash-preexec (MIT licensed) and source it first.
- **Pitfall: `PROMPT_COMMAND` as an array** (bash 5.1+). If `declare -p PROMPT_COMMAND` shows an
  array, prepend and append elements instead of string-concatenating.
- **UNVERIFIED:** the fallback has not been tested against every prompt framework (starship,
  oh-my-bash). Test before shipping.

### 5.3 fish

Drop a file in `~/.config/fish/conf.d/breakpoint.fish`. No rc-file edit; uninstall by deleting it.

```fish
status is-interactive; or exit
set -q __bp_loaded; and exit
set -g __bp_loaded 1
set -g __bp_bin $HOME/.breakpoint/bin/breakpoint

function __bp_preexec --on-event fish_preexec
    set -g __bp_name (string split -m1 ' ' -- $argv[1])[1]
    test -x $__bp_bin; or return
    command $__bp_bin emit commandStarted --source shell --cwd $PWD --title $__bp_name >/dev/null 2>&1 &
    disown 2>/dev/null
end

function __bp_postexec --on-event fish_postexec
    set -l ec $status                   # first statement
    test "$CMD_DURATION" -ge 2000 2>/dev/null; or return
    test -x $__bp_bin; or return
    command $__bp_bin emit commandFinished --source shell --cwd $PWD --title $__bp_name \
        --duration-ms $CMD_DURATION --exit-code $ec >/dev/null 2>&1 &
    disown 2>/dev/null
end
```

- **UNVERIFIED:** that `$status` read as the first line of a `fish_postexec` handler is the user
  command's exit status. This is the common pattern, but the fetched docs don't state it.
  `$pipestatus` is the alternative.
- `disown` stops fish printing "Job 1, ... has ended" later.

### 5.4 Shell pitfalls

- Agents' own commands (Claude Code's Bash tool, Codex `exec`) run in non-interactive shells, so
  these hooks don't fire for them. That is the desired behaviour.
- The IDE terminals in VS Code, Cursor and Warp install their own shell integration. Test in each.
  Warp's handling of `preexec`/`precmd` is **UNVERIFIED**.
- Never `source` the integration file unguarded. If the app is deleted, the `-r`/`-x` guards keep
  every new shell silent.
- Only `.zshrc`/`.bashrc`/`.bash_profile` edits need marker blocks. Back them up before editing and
  remove exactly the block on uninstall.

---

## 6. UNVERIFIED items (consolidated)

1. Claude Code: whether a refused HTTP-hook connection on `UserPromptSubmit`/`Stop` shows a visible
   "hook error" notice.
2. Claude Code: whether fractional `timeout` values (for example `0.5`) are accepted.
3. Claude Code: whether an `async` `SessionEnd` hook completes after the process exits in an
   interactive session.
4. Claude Code: any event that fires when the user interrupts a turn (Esc). None found; `Stop`
   explicitly doesn't fire.
5. Claude Code: whether a skills-directory plugin with only `hooks/` (no `SKILL.md`) loads.
6. Cursor: the `hook_event_name` value seen when Cursor runs a mapped Claude Code hook.
7. Cursor: whether its third-party import also loads Claude Code plugins (including
   skills-directory plugins).
8. Cursor: the default hook `timeout` ("platform default").
9. Cursor: whether `command` runs through a shell on macOS (`$HOME`, `&&`, redirects).
10. Cursor: whether empty stdout from `beforeSubmitPrompt` is treated as "continue".
11. Cursor: whether empty stdout from permission hooks counts as invalid JSON (Breakpoint avoids
    these hooks anyway).
12. Cursor: any "waiting for user / approval" signal. None documented.
13. Cursor: whether a local plugin's `hooks/hooks.json` needs `"version": 1`.
14. Codex: whether `async: true` is accepted on `PermissionRequest`.
15. Codex: whether `Stop`/`SubagentStop` accept exit 0 with empty stdout (the docs are
    contradictory).
16. VS Code: the exact supported event subset, and whether `~/.copilot/hooks/breakpoint.json` is
    honoured there in practice.
17. Gemini CLI: whether hooks are enabled by default in the installed version.
18. Windsurf/Cascade: all details (file paths, event names). Product docs now redirect to Devin
    Desktop.
19. OpenCode: plugin event names (`session.idle` etc.).
20. Aider: YAML key spelling for `notifications-command` in `.aider.conf.yml`.
21. zsh: whether `$?` survives across multiple `precmd_functions` (mitigated by ordering).
22. bash: the fallback DEBUG-trap snippet's behaviour with prompt frameworks.
23. fish: `$status` at the top of a `fish_postexec` handler.
24. Warp terminal's shell-hook behaviour.

## 7. Source index (all fetched 2026-11-22)

| Topic | URL |
|---|---|
| Claude Code hooks reference | https://code.claude.com/docs/en/hooks (redirect from https://docs.claude.com/en/docs/claude-code/hooks) |
| Claude Code hooks guide | https://code.claude.com/docs/en/hooks-guide |
| Claude Code env vars | https://code.claude.com/docs/en/env-vars |
| Claude Code plugins overview | https://code.claude.com/docs/en/plugins/overview |
| Claude Code create plugin | https://code.claude.com/docs/en/plugins/create |
| Claude Code install plugins | https://code.claude.com/docs/en/plugins/install |
| Claude Code plugin CLI reference | https://code.claude.com/docs/en/plugins/cli-reference |
| Claude Code plugin manifest | https://code.claude.com/docs/en/plugins/manifest-reference |
| Claude Code create marketplace | https://code.claude.com/docs/en/plugins/create-marketplace |
| Claude Code marketplace reference | https://code.claude.com/docs/en/plugins/marketplace-reference |
| Claude Code plugin loading | https://code.claude.com/docs/en/plugins/loading |
| Cursor hooks | https://cursor.com/docs/hooks |
| Cursor third-party hooks | https://cursor.com/docs/reference/third-party-hooks |
| Cursor plugins | https://cursor.com/docs/plugins |
| Cursor plugins reference | https://cursor.com/docs/reference/plugins |
| Cursor CLI changelog | https://cursor.com/docs/cli/changelog |
| Codex hooks | https://developers.openai.com/codex/hooks |
| Codex advanced config (notify) | https://developers.openai.com/codex/config-advanced |
| Codex basic config | https://developers.openai.com/codex/config-basic |
| Codex config reference | https://developers.openai.com/codex/config-reference |
| Codex repo config doc | https://github.com/openai/codex/blob/main/docs/config.md |
| Codex notify source | https://github.com/openai/codex/blob/main/codex-rs/hooks/src/legacy_notify.rs |
| Codex plugins | https://developers.openai.com/plugins/build/plugins |
| GitHub Copilot hooks reference | https://docs.github.com/en/copilot/reference/hooks-reference |
| VS Code agent hooks | https://code.visualstudio.com/docs/agent-customization/hooks |
| Gemini CLI hooks | https://geminicli.com/docs/hooks/ |
| Gemini CLI hooks reference | https://geminicli.com/docs/hooks/reference/ |
| Windsurf Cascade hooks (now Devin Desktop docs) | https://docs.windsurf.com/windsurf/cascade/hooks, https://docs.devin.ai/desktop/devin-local/customizations |
| OpenCode plugins | https://opencode.ai/docs/plugins/ |
| Aider notifications | https://aider.chat/docs/usage/notifications.html |
| zsh hook functions | https://zsh.sourceforge.io/Doc/Release/Functions.html |
| zsh add-zsh-hook | https://zsh.sourceforge.io/Doc/Release/User-Contributions.html |
| Bash manual | https://www.gnu.org/software/bash/manual/bash.html |
| bash-preexec | https://github.com/rcaloras/bash-preexec |
| fish language (events, CMD_DURATION) | https://fishshell.com/docs/current/language.html |
