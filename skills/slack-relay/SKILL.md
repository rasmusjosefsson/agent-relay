---
name: slack-relay
description: Report to and take instructions from the user through their Slack relay channel while they are away from the Mac. Use when they say to post, ping, or report to Slack when done or blocked, to ask them something over Slack, or to run, configure, or debug slack-relay, its dispatcher, or its workers.
version: 0.1.0
---

# Slack relay

`slack-relay` lets agents talk to the user through one private Slack channel, posting as the user's own account. Settings are in `~/.config/slack-relay/config.json`; `slack-relay config show` prints them with defaults, and `config.schema.json` in the repo describes each key.

Find the channel once per session:

```bash
CHANNEL=$(slack-relay config get channel)
```

## Messages

- Every agent post is `<icon> [label] <text>`. The label is the agent's one-word name.
- The user replies with `!<label> <text>` (`@bot <label> <text>` also works), in the channel or in any thread. Only their own messages count; other people, bots, and agent posts are skipped.
- A reply goes where the `!` message was. A worker started from a thread posts its questions and result in that thread.

## Permission

When the user asks you to report to Slack, that request authorizes these posts, and nothing else:

- Posts go only to the configured channel, only about the task they named, and say what happened or what you need.
- Any other Slack message still needs their exact text and target.

## Report when done or blocked

Pick a one-word label for this task (repo or task name, such as `client`) and keep it for the whole session.

1. When the task finishes, post a short result: what changed, where, and anything left open.

   ```bash
   slack-relay post "id:$CHANNEL" client "done: fixed the flaky test in foo.spec.ts, not committed"
   ```

2. When you need a decision, post the question and block until they answer:

   ```bash
   slack-relay ask "id:$CHANNEL" client "Commit or open a PR? reply: !client pr" --timeout 540
   ```

   Keep `--timeout` below your shell tool's limit (Claude Code stops a command after 10 minutes). It prints their reply and exits 0. Exit 3 means no reply yet: run the `slack-relay wait …` command it printed on stderr, which keeps waiting from the same point. Give up, and post that you stopped, only when they have been silent longer than the task can wait.

3. Treat the reply as their next chat message and continue. Repeat 2 for each later decision.

Write links as Slack links with a short label (`<https://github.com/org/repo/pull/12|PR #12>`), and Jira keys plainly: posts link them automatically. Slack sends no push notification for these posts, because they come from the user's own account.

## Dispatcher and workers

`slack-relay serve` is the always-on loop. Start it only when the user asks for it.

- `!<msg>` goes to the dispatcher (`dispatcher.label`, default `boss`), unless its first word names a worker. The dispatcher starts a fresh session each time on `dispatcher.runner` with that runner's model from `dispatcher.models`, with only `MEMORY.md` in `dispatcher.workdir` as memory, plus the user's earlier messages when they write in a thread. It answers quick things and starts workers.
- `slack-relay spawn <repo> "<task>" [--runner opencode|claude|pi] [--model ID]` starts a worker in that repo's folder from `repos`, with its own session. The worker is named after the repo (`client`, then `client-2`), asks with `ask`, and its final reply is posted for it.
- `!<worker> <msg>` to a finished worker resumes its session. While a worker runs, replies reach it only through its own `ask`.
- `auto` maps to `opencode --auto` or `claude --dangerously-skip-permissions`. `pi -p` runs tools without asking either way.

## Configure and debug

- `slack-relay doctor`: checks tools, config, that the Slack token belongs to `user`, the channel, runners, and repos.
- `slack-relay config set <key> <value>`: validates before saving. Keys use dots (`worker.runner`), values may be JSON (`true`, `200`, `["ADE"]`).
- `slack-relay status [--json]`: the bridge and every worker. Logs are in `~/.local/state/slack-relay/` (`serve.log`, `workers/<name>.log`).
