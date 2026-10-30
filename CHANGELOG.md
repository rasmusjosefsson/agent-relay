# Changelog

## 0.1.0

First version as its own repo, moved out of the dotfiles.

- `serve`: a dispatcher answers `@bot` messages in a fresh session each time, with `MEMORY.md` as its only memory, and starts workers. `@bot` works in the channel and in threads; answers go where you wrote.
- `spawn`: workers run in a configured repo on `opencode`, `claude`, or `pi`, keep their session and thread, ask questions with `ask`, and resume when you reply after they finish.
- Only the configured user drives it: bot and webhook posts are never read as yours, thread context holds only your messages, and `serve` needs a valid `user`.
- Posts are rewritten for Slack: `**bold**`, `[text](url)`, headings, and Jira keys from `jira_projects` become links.
- Configuration for people and apps: `init`, `config get/set/unset/validate`, `doctor [--json]`, `status --json`, `config.schema.json` as the single source of defaults, and `serve.json` with pid and last poll. `serve` runs once at a time.
