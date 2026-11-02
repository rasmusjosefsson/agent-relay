# slack-relay

Talk to coding agents on your Mac from Slack. Write `!boss …` in a private channel from your phone. A cheap dispatcher answers or starts a worker agent in one of your repos. Workers report back in the same channel or thread and ask you when they need a decision.

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
- At least one of `opencode`, `claude`, `pi`

## Set up

```bash
ln -s "$PWD/bin/slack-relay" ~/bin/slack-relay

slack-relay init --name Rasmus \
  --channel https://acme.slack.com/archives/C0123456789 \
  --token-file ~/.secrets/slack.token --cookie-file ~/.secrets/slack-cookie.token
# init reads your member ID from the token; pass --user U0123456789 to set it yourself
slack-relay config set dispatcher.models.opencode github-copilot/claude-haiku-5.5
slack-relay config set repos.client ~/code/client
slack-relay doctor
slack-relay serve 2>>~/.local/state/slack-relay/serve.log
```

With Claude Code under a managed sandbox, the agents' shell commands can't reach most hosts or your stored logins. Let a CLI through for every `claude` the relay starts:

```bash
slack-relay config set claude_settings '{"sandbox": {"excludedCommands": ["acli *"]}}'
```

`config set` validates before saving and accepts JSON values (`true`, `200`, `["ADE"]`). `config apply` takes several changes at once as `{"set": {"trigger": ":zap:"}, "unset": ["show_label"]}` on stdin and saves all of them or none. Every key, its meaning, and its default is in [`config.schema.json`](config.schema.json). [`config.example.json`](config.example.json) shows a filled-in file.

## Use it from Slack

| You write | What happens |
|---|---|
| `!boss what's the time?` | The dispatcher (`dispatcher.label`, `boss` by default) answers, in a fresh session. |
| `!boss fix the flaky test in client with claude` | The dispatcher starts worker `client` on Claude Code. |
| `!client use option 2` | Answers worker `client`'s question, or resumes it once it has finished. |
| `!boss stop` | Ends every answer the dispatcher is still working on, and its agent. Its thinking post says "Stopped." |
| `!client stop` | Ends worker `client` and its agent. `!client …` picks it up again in the same session. |
| `!boss …` in the channel | The answer goes to a thread under your message. Keep talking there; the dispatcher sees your earlier messages in it. |
| `!boss …` inside a thread | The answer goes to that thread. The dispatcher also sees your earlier messages there. |

Anything else, like `!hello` or `!oldname hi`, gets no answer: only the dispatcher's name and running or finished workers' names do. Replies show up as `<icon> [name] …`. Jira keys from `jira_projects` become links automatically.

Make it yours in the app's General pane (edit, then Save at the bottom) or with `config set`:

- `trigger`: what messages start with, `!` by default. An emoji works too, written as its shortcode (`:zap:`), since that's how Slack sends it.
- `channels`: more channels to read. Answers go to the channel you wrote in, and each extra channel adds one Slack read per poll.
- `dispatcher.icon` and `worker.icon`: a different emoji per role, falling back to `icon`.
- `show_label`: `false` drops the `[name]` tag.
- `reply_in_thread`: `false` answers channel messages in the channel instead of a thread under them.
- `thinking`: what the dispatcher posts the moment your message arrives, replaced by its answer when it's ready. Any text or emoji, like `:loading-2:`; empty posts nothing until the answer.

From an agent session on the Mac, use `slack-relay post`, `ask` and `wait` to report or ask a question. The skill in [`skills/slack-relay`](skills/slack-relay/SKILL.md) tells agents how; link that folder into `~/.agents/skills/` and `~/.claude/skills/`.

## For an app

Everything an app needs is a file or a JSON command:

| What | Where |
|---|---|
| Settings | `~/.config/slack-relay/config.json`, described by `config.schema.json` (titles, descriptions, defaults, enums) |
| Settings as a form | `slack-relay config fields --json` → `{groups, fields: [{key, group, title, description, type, enum, value}]}` in schema order |
| Edit one setting with validation | `slack-relay config set <key> <value>`, exit 1 with the reason |
| Health checks | `slack-relay doctor --json` → `[{check, ok, detail}]` |
| Bridge, answers and workers | `slack-relay status --json` → `{serve: {running, pid, started, last_poll, channel, channels, slack_url, …}, turns: [{id, label, status, text, channel, thread, ts, dir, since, finished, answer, last, …}], workers: [{name, status, repo, runner, task, last, …}]}`. `turns` are the dispatcher's answers, running ones and the newest 20 finished; `last` is the agent's newest step while it works |
| What an agent is doing | `slack-relay activity <worker\|turn> --json` → `[{kind, text, detail}]`, oldest first. `kind` is `relay` (the command, folder and whole prompt the relay ran), `start` (model, tools, MCP servers), `thinking`, `tool` (the tool and its input), `output` (its result), `text`, `error`, or `done` (time, turns, cost). `detail` has the full text where `text` is one short line. Claude and OpenCode report each step as it finishes; Pi only its answer |
| Stop one | `slack-relay cancel <worker\|turn>…` does what `!name stop` does for a worker, or for one dispatcher answer by its turn ID, and says "Stopped." in Slack |
| Logs | `~/.local/state/slack-relay/serve.log`, `workers/<name>.log`; each run's raw agent output in `workers/<name>.events` and `dispatch/<turn>.events` |
| Agent CLIs | `slack-relay agents --json` → `[{name, installed, version, path, dispatcher, default_worker, dispatcher_model, worker_model, active}]` |
| Connectors | `slack-relay connectors --json [name…]` → `[{name, title, check, ok, detail}]`; `ok` is null when off, and no token is shown. The first row is Slack itself (`builtin: true`): the token's owner and whether every channel is readable |
| Channel names | `slack-relay channels --json` → `[{id, name}]` for the configured channels; `name` is null when Slack won't say |
| Models | `slack-relay models --json [runner…]` → `{runner: [model]}` from each agent CLI's own list; Claude has none, so it gets `haiku`, `sonnet`, `opus` |
| Speed | `slack-relay speed --json` → `[{runner, model, agent, answers, median, p90, slowest, last}]`, seconds per dispatcher answer from message to reply, newest first. Every answer adds a line to `speed.jsonl` in the state folder, and its turn in `status --json` gets `secs` |
| Remove a worker | `slack-relay remove <worker>…` stops it and its child processes if it runs, then deletes its record and log, so `!name` no longer resumes it |
| Memory | `slack-relay memory --json` → `{path, exists, lines, limit, text}`; `memory set` replaces it from stdin |
| Start and stop | `slack-relay start` runs `serve` in the background, logging to `serve.log`; `slack-relay stop` ends it. A second `serve` exits with "already running". |

Worker `status` is one of `running`, `waiting` (asked you a question), `done`, `failed`, `stopped` (you wrote `!name stop`), or `died` (process gone without finishing).

## Mac app

[`app/`](app) is a native window over these commands. General starts and stops the relay and holds the everyday settings (channels, trigger, icons, agents and models, repos), with the rest of the schema under Advanced. Activity lists every dispatcher answer and worker as it runs, with the step its agent is on now, a live feed of every step when you open one, and a Stop button. Workers, Connectors (Slack included), `MEMORY.md`, and `doctor` each have a pane. While the app is open it keeps a menu bar icon: radio waves while the relay is listening, the same mark with a slash while it is stopped. Its menu lists what is running, each with its current step and Stop. Closing the window leaves the icon; Quit removes it. It needs macOS 14 and Xcode.

```bash
app/scripts/bundle.sh   # builds Slack Relay.app into /Applications, reopening it if it was running
```

It finds `slack-relay` on your login shell's PATH, then in `~/bin`. `app/.build/debug/SlackRelay --snapshot <dir>` renders every pane to PNG in light and dark mode.

## Develop

```bash
tests/slack-relay.sh   # routing, workers, config, security, with fake Slack and agent CLIs
tests/slack-api.sh     # the built-in Slack client against a fake curl
```

Neither test posts to Slack or calls a model.
