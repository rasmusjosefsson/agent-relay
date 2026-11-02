# Changelog

## Unreleased

- `slack-relay speed` shows how long dispatcher answers take for each runner, model and agent: median, p90 and slowest, so a model or agent change can be compared. Each answer is kept in `speed.jsonl` in the state folder.

- `dispatcher.local_agent` names an OpenCode agent the dispatcher runs in when its model is an `ollama/` one. A slim agent (short prompt, few tools, no skills) keeps a local model from reading OpenCode's full prompt on every message; other models keep the default agent.

- The Mac app has an Activity pane: every dispatcher answer and worker as it runs, the step its agent is on now (`Bash git status`, `Read src/foo.ts`), a live feed of every step when you open one, and Stop for each. Each shows the channel and thread it came from, with Open in Slack, and the agent, model and folder it runs in. The feed has what the relay sent (command and whole prompt), the agent's session (model, tools, MCP servers), thinking, each tool call with its input and output, its text, and time and cost at the end; click a step to see all of it. Claude keeps its thinking text to itself, so the feed shows only that it is thinking. Two `!boss …` messages at once show as two cards. The menu bar menu lists what is running, with its step and Stop. Finished answers stay listed with their reply, the newest 20.
- The app no longer stops refreshing after a while: a finished `slack-relay` command could leave it waiting forever.
- Answers in one Slack thread show as one card in Activity, oldest first.
- Restarting the relay no longer answers `!` messages in threads a second time. It now reads from the moment it starts, not from the newest message in the channel, which is older than recent thread replies.
- New `slack-relay activity <worker|turn>` prints what an agent did so far, and `slack-relay cancel <worker|turn>` stops one worker or one dispatcher answer the way `!name stop` does. `status --json` lists the dispatcher's answers as `turns`, each with an ID for these two commands. Claude now runs with `--output-format stream-json` so its steps show while it works.

- The Mac app keeps a menu bar icon while it is open. Radio waves while the relay is listening, the same mark with a slash while it is stopped. Closing the window leaves the icon; Quit removes it. The menu opens the window and can start or stop the relay.
- `!boss stop` ends a dispatcher answer that is taking too long, agent included, and turns its thinking post into "Stopped." `!client stop` does the same for a worker, which keeps its session for `!client …`. The dispatcher now answers in the background, so `serve` keeps reading while it works and a second `!boss …` no longer waits for the first.

- The app's General pane no longer saves each setting as you type. Changed settings get a dot, a bar at the bottom says how many are unsaved, and Save (⌘S) or Revert applies them together. After saving, the same bar says whether the relay is using them or needs a restart, with the Restart button right there.
- The app shows each saved channel's Slack name under the Channels field, from the new `slack-relay channels --json`. It only asks Slack about channels in the config.
- The dispatcher posts `thinking` (`:hourglass_flowing_sand: thinking…` by default, or your own emoji like `:loading-2:`) as soon as your message arrives, then edits it into the answer, so a slow answer no longer looks like nothing happened.
- Replies in a thread are seen however long ago it started, still with one Slack request per channel per poll. The edited answer keeps its links, and the dispatcher no longer explains its formatting rules in the answer.
- The app's model fields have a menu of the models each agent CLI lists, from the new `slack-relay models --json`. You can still type any model.
- `slack-relay remove <worker>` stops a worker and its child processes and forgets it. The Workers pane has a Remove button for it, and asks first when the worker is still running.
- Just after Start, the app no longer says the relay runs with old settings while it is still reading the config.
- `config apply` saves a JSON patch (`{"set": {...}, "unset": [...]}` on stdin) at once, or not at all, so settings that depend on each other, like `trigger` and the icons, can change together.
- Answers to a message in the channel go to a thread under it, and a worker started there keeps posting in that thread. `reply_in_thread: false` answers in the channel as before.
- Only the dispatcher's name and worker names get an answer: `!dude hi` reaches dispatcher `dude`, while `!boss hi` or `!hello` is ignored. Before, any other first word went to the dispatcher.
- A running `serve` rereads the config on the next poll after a change, and `serve.json` says which trigger, dispatcher, and channels it uses and when it loaded them. The app shows whether your saved settings are in use and offers Restart when they aren't. `user` still needs a restart.
- `config set show_label false` (and any `false` or `null`) saved the text `"false"` and was rejected.
- The relay reads and posts only in the configured channels. Every Slack call checks this, so an agent can't post or read anywhere else.
- `channels` adds more channels to read; agents answer in the one you wrote in, and workers keep posting there.
- `trigger` sets what messages start with (`!` by default, or e.g. `:zap:`). `dispatcher.icon` and `worker.icon` give each role its own emoji, and `show_label: false` drops the `[name]` tag.
- `connectors` starts with a Slack row: whose token it is and whether every channel is readable.
- The Mac app has a General pane in place of Overview, Agents, and Settings: start/stop, the everyday settings, and the rest under Advanced.
- A Mac app in `app/` shows the relay, agents, workers, connectors, memory, settings, and `doctor`, and can start and stop the relay.
- New JSON commands for it: `agents`, `connectors` (sign-in checks for GitHub, Jira, Datadog, Grafana, and ClickHouse through their own CLIs; add your own under `connectors`), `memory`, and `config fields`. `start` and `stop` run `serve` in the background. `status --json` also shows the dispatcher, what `serve` is busy with, when it last polled, and each worker's log.
- Write `!…` instead of `@bot …` (`!client use option 2`), since Slack's `@` autocomplete mentions people. `@bot` still works.
- `claude_settings` passes extra Claude Code settings to every `claude` run, e.g. `{"sandbox": {"excludedCommands": ["acli *"]}}` so agents can use `acli` under a managed sandbox. Agents are told to run those commands on their own, since the sandbox lets nothing through that's piped or chained.
- A Claude dispatcher keeps its memory in `MEMORY.md` only, with Claude Code's own auto memory turned off.
- The dispatcher asks for workers with a `SPAWN {json}` line and `serve` starts them, so a sandboxed dispatcher (Claude Code under a managed sandbox) can start workers too.
- `dispatcher.models` holds a model per runner, like `worker.models`, so switching `dispatcher.runner` also switches the model. Claude defaults to `haiku`; opencode and pi to their own default. `dispatcher.model` is no longer read, and `doctor` says so when it is set.
- Other people posting in the channel can't hide your messages or slow `serve` down: each poll reads every message since the last one, not just the newest 50, and only fetches replies in threads you started or replied in.
- A failing `opencode` run reports its error message too.
- A failing `claude` run reports the reason from its JSON result instead of unrelated stderr.

## 0.1.0

First version as its own repo, moved out of the dotfiles.

- `serve`: a dispatcher answers `@bot` messages in a fresh session each time, with `MEMORY.md` as its only memory, and starts workers. `@bot` works in the channel and in threads; answers go where you wrote.
- `spawn`: workers run in a configured repo on `opencode`, `claude`, or `pi`, keep their session and thread, ask questions with `ask`, and resume when you reply after they finish.
- Only the configured user drives it: bot and webhook posts are never read as yours, thread context holds only your messages, and `serve` needs a valid `user`.
- Posts are rewritten for Slack: `**bold**`, `[text](url)`, headings, and Jira keys from `jira_projects` become links.
- Configuration for people and apps: `init`, `config get/set/unset/validate`, `doctor [--json]`, `status --json`, `config.schema.json` as the single source of defaults, and `serve.json` with pid and last poll. `serve` runs once at a time.
