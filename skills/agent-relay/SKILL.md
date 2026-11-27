---
name: agent-relay
description: Report to and take instructions from the user through their Slack relay channel while they are away from the Mac. Use when they say to post, ping, or report to Slack when done or blocked, to ask them something over Slack, or to run, configure, or debug agent-relay (or slack-relay), its dispatcher, or its workers.
version: 0.1.0
---

# Agent relay

`agent-relay` lets agents talk to the user through one private Slack channel, posting as the user's own account. Settings are in `~/.config/agent-relay/config.json`; `agent-relay config show` prints them with defaults, and `config.schema.json` in the repo describes each key.

Find the channel once per session:

```bash
CHANNEL=$(agent-relay config get channel)
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
   agent-relay post "id:$CHANNEL" client "done: fixed the flaky test in foo.spec.ts, not committed"
   ```

2. When you need a decision, post the question and block until they answer:

   ```bash
   agent-relay ask "id:$CHANNEL" client "Commit or open a PR? reply: !client pr" --timeout 540
   ```

   Keep `--timeout` below your shell tool's limit (Claude Code stops a command after 10 minutes). It prints their reply and exits 0. Exit 3 means no reply yet: run the `agent-relay wait …` command it printed on stderr, which keeps waiting from the same point. Give up, and post that you stopped, only when they have been silent longer than the task can wait.

3. Treat the reply as their next chat message and continue. Repeat 2 for each later decision.

Write links as Slack links with a short label (`<https://github.com/org/repo/pull/12|PR #12>`), and Jira keys plainly: posts link them automatically. Slack sends no push notification for these posts, because they come from the user's own account.

## Dispatcher and workers

`agent-relay serve` is the always-on loop. Start it only when the user asks for it.

- The first word after `!` is always a name. `!<dispatcher> <msg>` goes to the dispatcher (`dispatcher.label`, default `bot`), `!<worker> <msg>` to that worker, and anything else is ignored, so `!fix the test` gets no answer. The dispatcher starts a fresh session each time on `dispatcher.runner` with that runner's model from `dispatcher.models`, with only `MEMORY.md` in `dispatcher.workdir` as memory, plus the user's earlier messages when they write in a thread. It answers quick things and starts workers.
- `agent-relay spawn <repo> "<task>" [--runner opencode|claude|pi] [--model ID]` starts a worker in that repo's folder from `repos`, with its own session. The worker is named after the repo (`client`, then `client-2`), asks with `ask`, and its final reply is posted for it.
- `!<worker> <msg>` to a finished worker resumes its session. While a worker runs, replies reach it only through its own `ask`.
- `auto` maps to `opencode --auto` or `claude --dangerously-skip-permissions`. `pi -p` runs tools without asking either way.

## Configure and debug

- `agent-relay doctor`: checks tools, config, that the Slack token belongs to `user`, the channel, runners, and repos.
- `agent-relay config set <key> <value>`: validates before saving. Keys use dots (`worker.runner`), values may be JSON (`true`, `200`, `["ADE"]`).
- `agent-relay status [--json]`: the bridge and every worker; `--json` also lists the dispatcher's answers as `turns`. Logs are in `~/.local/state/agent-relay/` (`serve.log`, `workers/<name>.log`).
- `agent-relay recap [--since 7d] [--mood brief|funny|detailed] [--raw]`: work recap scoped strictly to `recap.github_orgs` (GitHub PRs, local git repos, optional local Langfuse sessions); also available in Slack as `!bot recap [7d] [funny|brief|detailed] [raw]`.
- `agent-relay memory [--channel <id|name>] [show|path|--json|set]`: read or replace global `MEMORY.md` or a channel's `<workdir>/memory/<channel-id>.md`. Per-channel `memory_policy`, `skills`, `repo`, and `instructions` live under `channel_config.<channel-id>`.
- `agent-relay activity <worker|turn>`: the steps its agent took (tools, text, errors). `agent-relay cancel <worker|turn>` stops one, like `!name stop`.
