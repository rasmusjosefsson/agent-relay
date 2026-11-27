# agent-relay

Talk to coding agents on your Mac from Slack. Write `!bot …` in a private channel from your phone. A cheap dispatcher answers or starts a worker agent in one of your repos. Workers report back in the same channel or thread and ask you when they need a decision.

Works with [OpenCode](https://opencode.ai), [Claude Code](https://claude.com/claude-code), and [Pi](https://github.com/badlogic/pi-mono), picked per agent.

## Only you can drive it

Agents run commands on your Mac, so the bot listens to one person in the channels you list:

- It reads and posts only in `channel` and `channels`. Every Slack read and post goes through one check, so `post`, `ask`, `wait`, and agents passing their own channel ID are refused for any other channel.
- It reads only messages whose Slack author is your `user` ID. Other people in the channel are ignored.
- `serve` starts only when the Slack token belongs to that same `user`, so posts and permissions are yours alone.
- Bot and webhook posts never count, even when their display name is your ID: their author is read as `bot:<id>`.
- Thread context passed to the dispatcher contains only your own messages.
- `serve` refuses to start without a valid `user`, and there is no built-in default.
- Agent posts are sent from your own account and prefixed with the icon, so they never trigger the bot. `config` refuses an icon that starts with the trigger.

Use a private channel with only you in it. Agents' answers can contain anything they read.

## Requirements

- macOS with `curl`, `jq` 1.6+, `perl`, and bash 4+ (`brew install bash`; the script switches to it when started by the system bash)
- Your own Slack token in a file: a user token (`xoxp-`), or a browser token (`xoxc-`) plus its `d` cookie in a second file
- `python3` for `agent-relay auth` (macOS includes it with the Xcode command line tools)
- At least one of `opencode`, `claude`, `pi`

## Set up

```bash
ln -s "$PWD/bin/agent-relay" ~/bin/agent-relay

agent-relay init --name Rasmus \
  --channel https://acme.slack.com/archives/C0123456789 \
  --token-file ~/.secrets/slack.token --cookie-file ~/.secrets/slack-cookie.token
# init reads your member ID from the token; pass --user U0123456789 to set it yourself
agent-relay config set dispatcher.models.opencode github-copilot/claude-haiku-5.5
agent-relay config set repos.client ~/code/client
agent-relay doctor
agent-relay serve 2>>~/.local/state/agent-relay/serve.log
```

### Sign in from Slack desktop

When Slack desktop is signed in, `agent-relay auth` reads its browser token and `d` cookie from the local session over CDP and writes them to the configured files, with no Keychain prompt:

```bash
agent-relay auth                  # the config's channel picks the workspace
agent-relay auth --workspace acme # when several workspaces are signed in
```

Slack quits and reopens once while the session is read, and both files are written mode 600. The Mac app's Connectors pane has the same action on the Slack row: **Sign in…**, with a workspace chooser when more than one is signed in.

With Claude Code under a managed sandbox, the agents' shell commands can't reach most hosts or your stored logins. Let a CLI through for every `claude` the relay starts:

```bash
agent-relay config set claude_settings '{"sandbox": {"excludedCommands": ["acli *"]}}'
```

`config set` validates before saving and accepts JSON values (`true`, `200`, `["ADE"]`). `config apply` takes several changes at once as `{"set": {"trigger": ":zap:"}, "unset": ["show_label"]}` on stdin and saves all of them or none. Every key, its meaning, and its default is in [`config.schema.json`](config.schema.json). [`config.example.json`](config.example.json) shows a filled-in file.

## Use it from Slack

| You write | What happens |
|---|---|
| `!bot what's the time?` | The dispatcher (`dispatcher.label`, `bot` by default) answers, in a fresh session. |
| `!bot fix the flaky test in client with claude` | The dispatcher starts worker `client` on Claude Code. |
| `!client use option 2` | Answers worker `client`'s question, or resumes it once it has finished. |
| `!bot stop` | Ends every answer the dispatcher is still working on, and its agent. Its thinking post says "Stopped." |
| `!bot recap [7d] [brief\|funny\|detailed] [raw]` | Summarizes your recent work (merged & open PRs, local git branches/dirty trees, optional local Langfuse sessions) scoped strictly to `recap.github_orgs`. On Mondays, the default lookback reaches back to Friday. |
| `!client stop` | Ends worker `client` and its agent. `!client …` picks it up again in the same session. |
| `!bot …` in the channel | The answer goes to a thread under your message. Keep talking there; the dispatcher sees your earlier messages in it. |
| `!bot …` inside a thread | The answer goes to that thread. The dispatcher also sees your earlier messages there. |

Anything else, like `!hello` or `!oldname hi`, gets no answer: only the dispatcher's name and running or finished workers' names do. Replies show up as `<icon> [name] …`. Jira keys from `jira_projects` become links automatically.

Make it yours in the app's General pane (edit, then Save at the bottom) or with `config set`:

- `trigger`: what messages start with, `!` by default. An emoji works too, written as its shortcode (`:zap:`), since that's how Slack sends it.
- `channels`: more channels to read. Answers go to the channel you wrote in, and each extra channel adds one Slack read per poll.
- `channel_config`: per-channel overrides keyed by Slack channel ID (`memory_policy`: `explicit`, `ask`, or `auto`; `skills`: list of skills to focus on; `repo`: default repo; `instructions`: extra standing notes). Each channel also gets its own memory file at `<workdir>/memory/<channel-id>.md` alongside global `MEMORY.md`.
- `dispatcher.icon` and `worker.icon`: a different emoji per role, falling back to `icon`.
- `show_label`: `false` drops the `[name]` tag.
- `reply_in_thread`: `false` answers channel messages in the channel instead of a thread under them.
- `thinking`: what the dispatcher posts the moment your message arrives, replaced by its answer when it's ready. Any text or emoji, like `:loading-2:`; empty posts nothing until the answer.
- `recap`: scoped work recaps (`!bot recap` or `agent-relay recap --since 7d --mood funny`, `--raw` for a 0-token deterministic dump). Set `recap.github_orgs` (allowlist only — personal repos are never included), default `recap.mood` (`brief`, `funny`, or `detailed`), optional `recap.repo_roots`, and optional `recap.langfuse_url`.

From an agent session on the Mac, use `agent-relay post`, `ask` and `wait` to report or ask a question. The skill in [`skills/agent-relay`](skills/agent-relay/SKILL.md) tells agents how; link that folder into `~/.agents/skills/` and `~/.claude/skills/`.

## For an app

Everything an app needs is a file or a JSON command:

| What | Where |
|---|---|
| Settings | `~/.config/agent-relay/config.json`, described by `config.schema.json` (titles, descriptions, defaults, enums) |
| Settings as a form | `agent-relay config fields --json` → `{groups, fields: [{key, group, title, description, type, enum, value}]}` in schema order |
| Edit one setting with validation | `agent-relay config set <key> <value>`, exit 1 with the reason |
| Health checks | `agent-relay doctor --json` → `[{check, ok, detail}]` |
| Bridge, answers and workers | `agent-relay status --json` → `{serve: {running, pid, started, last_poll, channel, channels, slack_url, …}, turns: [{id, label, status, text, channel, thread, ts, dir, since, finished, answer, last, …}], workers: [{name, status, repo, runner, task, last, …}]}`. `turns` are the dispatcher's answers, running ones and the newest 20 finished; `last` is the agent's newest step while it works |
| What an agent is doing | `agent-relay activity <worker\|turn> --json` → `[{kind, text, detail}]`, oldest first. `kind` is `relay` (the command, folder and whole prompt the relay ran), `start` (model, tools, MCP servers), `thinking`, `tool` (the tool and its input), `output` (its result), `text`, `error`, or `done` (time, turns, cost). `detail` has the full text where `text` is one short line. Claude and OpenCode report each step as it finishes; Pi only its answer |
| Stop one | `agent-relay cancel <worker\|turn>…` does what `!name stop` does for a worker, or for one dispatcher answer by its turn ID, and says "Stopped." in Slack |
| Logs | `~/.local/state/agent-relay/serve.log`, `workers/<name>.log`; each run's raw agent output in `workers/<name>.events` and `dispatch/<turn>.events` |
| Agent CLIs | `agent-relay agents --json` → `[{name, installed, version, path, dispatcher, default_worker, dispatcher_model, worker_model, active}]` |
| Connectors | `agent-relay connectors --json [name…]` → `[{name, title, check, ok, detail}]`; `ok` is null when off, and no token is shown. The first row is Slack itself (`builtin: true`): the token's owner and whether every channel is readable |
| Sign in to Slack | `agent-relay auth [--workspace W] [--json]` reads the signed-in Slack desktop session over CDP and writes the token and `d` cookie files; Slack restarts once |
| Channel names | `agent-relay channels --json` → `[{id, name}]` for the configured channels; `name` is null when Slack won't say |
| Models | `agent-relay models --json [runner…]` → `{runner: [model]}` from each agent CLI's own list; Claude has none, so it gets `haiku`, `sonnet`, `opus` |
| Speed | `agent-relay speed --json` → `[{runner, model, agent, answers, median, p90, slowest, last}]`, seconds per dispatcher answer from message to reply, newest first. Every answer adds a line to `speed.jsonl` in the state folder, and its turn in `status --json` gets `secs` |
| Remove a worker | `agent-relay remove <worker>…` stops it and its child processes if it runs, then deletes its record and log, so `!name` no longer resumes it |
| Memory | `agent-relay memory [--channel <id\|name>] --json` → `{path, exists, lines, limit, text, channel}`; `memory set [--channel <id\|name>]` replaces it from stdin |
| Start and stop | `agent-relay start` runs `serve` in the background, logging to `serve.log`; `agent-relay stop` ends it. A second `serve` exits with "already running". |

Worker `status` is one of `running`, `waiting` (asked you a question), `done`, `failed`, `stopped` (you wrote `!name stop`), or `died` (process gone without finishing).

## Mac app

[`app/`](app) is a native window over these commands. General starts and stops the relay and holds the everyday settings (channels, trigger, icons, agents and models, repos), with the rest of the schema under Advanced. Activity lists every dispatcher answer and worker as it runs, with the step its agent is on now, a live feed of every step when you open one, and a Stop button. Workers, Connectors (Slack included), Memory (global `MEMORY.md`, per-channel memory, and per-channel settings), and `doctor` each have a pane. While the app is open it keeps a menu bar icon: radio waves while the relay is listening, the same mark with a slash while it is stopped. Its menu lists what is running, each with its current step and Stop. Closing the window leaves the icon; Quit removes it. It needs macOS 14 and Xcode.

```bash
app/scripts/bundle.sh   # builds Agent Relay.app into /Applications, reopening it if it was running
```

It finds `agent-relay` on your login shell's PATH, then in `~/bin`. `app/.build/debug/AgentRelay --snapshot <dir>` renders every pane to PNG in light and dark mode.

## Develop

```bash
tests/agent-relay.sh   # routing, workers, config, memory, security, with fake Slack and agent CLIs
tests/slack-api.sh     # the built-in Slack client against a fake curl
tests/recap.sh         # allowlist-scoped work recap collector and CLI
```

None of the tests post to Slack or call a model.
