# slack-relay

Talk to coding agents on your Mac from Slack. Write `@bot …` in a private channel from your phone. A cheap dispatcher answers or starts a worker agent in one of your repos. Workers report back in the same channel or thread and ask you when they need a decision.

Works with [OpenCode](https://opencode.ai), [Claude Code](https://claude.com/claude-code), and [Pi](https://github.com/badlogic/pi-mono), picked per agent.

## Only you can drive it

Agents run commands on your Mac, so the bot listens to one person in one channel:

- It reads only the configured `channel`, and only messages whose Slack author is your `user` ID. Other people in the channel are ignored.
- `serve` starts only when the Slack token belongs to that same `user`, so posts and permissions are yours alone.
- Bot and webhook posts never count, even when their display name is your ID: their author is read as `bot:<id>`.
- Thread context passed to the dispatcher contains only your own messages.
- `serve` refuses to start without a valid `user`, and there is no built-in default.
- Agent posts are sent from your own account and prefixed with the icon, so they never trigger the bot.

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
slack-relay config set dispatcher.model github-copilot/claude-haiku-5.5
slack-relay config set repos.client ~/code/client
slack-relay doctor
slack-relay serve 2>>~/.local/state/slack-relay/serve.log
```

`config set` validates before saving and accepts JSON values (`true`, `200`, `["ADE"]`). Every key, its meaning, and its default is in [`config.schema.json`](config.schema.json). [`config.example.json`](config.example.json) shows a filled-in file.

## Use it from Slack

| You write | What happens |
|---|---|
| `@bot what's the time?` | The dispatcher answers, in a fresh session. |
| `@bot fix the flaky test in client with claude` | The dispatcher starts worker `client` on Claude Code. |
| `@bot client use option 2` | Answers worker `client`'s question, or resumes it once it has finished. |
| `@bot …` inside a thread | The answer goes to that thread. The dispatcher also sees your earlier messages there. |

Replies show up as `<icon> [name] …`. Jira keys from `jira_projects` become links automatically.

From an agent session on the Mac, use `slack-relay post`, `ask` and `wait` to report or ask a question. The skill in [`skills/slack-relay`](skills/slack-relay/SKILL.md) tells agents how; link that folder into `~/.agents/skills/` and `~/.claude/skills/`.

## For an app

Everything an app needs is a file or a JSON command:

| What | Where |
|---|---|
| Settings | `~/.config/slack-relay/config.json`, described by `config.schema.json` (titles, descriptions, defaults, enums) |
| Edit one setting with validation | `slack-relay config set <key> <value>`, exit 1 with the reason |
| Health checks | `slack-relay doctor --json` → `[{check, ok, detail}]` |
| Bridge and workers | `slack-relay status --json` → `{serve: {running, pid, started, last_poll, …}, workers: [{name, status, repo, runner, task, …}]}` |
| Logs | `~/.local/state/slack-relay/serve.log`, `workers/<name>.log` |
| Start and stop | Run `slack-relay serve`; stop it with `SIGTERM` to its `pid`. A second `serve` exits with "already running". |

Worker `status` is one of `running`, `waiting` (asked you a question), `done`, `failed`, or `died` (process gone without finishing).

## Develop

```bash
tests/slack-relay.sh   # routing, workers, config, security, with fake Slack and agent CLIs
tests/slack-api.sh     # the built-in Slack client against a fake curl
```

Neither test posts to Slack or calls a model.
