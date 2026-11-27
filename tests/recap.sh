#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/slack-relay-recap-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/roots" "$WORK/agent"
ME=U0123456789

fail() { echo "FAIL: $*" >&2; exit 1; }

# 1. Python unit tests: Monday lookback, org allowlist, CI/review summaries, Langfuse filtering
python3 - "$ROOT/bin/slack-relay-recap.py" <<'PY' || fail "python unit tests"
import datetime as dt
import importlib.util
import io
import json
import os
import sys
import unittest.mock as mock

spec = importlib.util.spec_from_file_location("recap", sys.argv[1])
recap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recap)

# Monday default lookback reaches back to Friday 00:00
monday = dt.datetime(2026, 11, 30, 10, 30, tzinfo=dt.timezone.utc)
assert monday.weekday() == 0
since_dt, label = recap.resolve_since("", now=monday)
assert since_dt == dt.datetime(2026, 11, 27, 0, 0, tzinfo=dt.timezone.utc), since_dt
assert "Friday" in label, label

# Tuesday default lookback reaches back to Monday 00:00
tuesday = dt.datetime(2026, 12, 1, 9, 0, tzinfo=dt.timezone.utc)
since_dt, label = recap.resolve_since("yesterday", now=tuesday)
assert since_dt == dt.datetime(2026, 11, 30, 0, 0, tzinfo=dt.timezone.utc), since_dt

# Duration & date specs
since_7d, _ = recap.resolve_since("7d", now=tuesday)
assert since_7d == tuesday - dt.timedelta(days=7)
since_24h, _ = recap.resolve_since("24h", now=tuesday)
assert since_24h == tuesday - dt.timedelta(hours=24)
since_date, _ = recap.resolve_since("2026-11-20", now=tuesday)
assert since_date == dt.datetime(2026, 11, 20, 0, 0, tzinfo=dt.timezone.utc)

# Org/repo extraction and allowlist
assert recap.extract_github_org_repo("git@github.com:Acme-Org/api.git") == ("Acme-Org", "api")
assert recap.extract_github_org_repo("https://github.com/acme-org/web") == ("acme-org", "web")
assert recap.extract_github_org_repo("ssh://git@github.com/rasmus/personal.git") == ("rasmus", "personal")
assert recap.is_allowed_org("Acme-Org", ["acme-org"])
assert not recap.is_allowed_org("rasmus", ["acme-org"])

# CI & review summarization
assert recap.summarize_ci([{"name": "unit", "status": "COMPLETED", "conclusion": "SUCCESS"}]) == "passing"
assert recap.summarize_ci([{"name": "lint", "status": "COMPLETED", "conclusion": "FAILURE"}]) == "failing (lint)"
assert recap.summarize_ci([{"name": "e2e", "status": "IN_PROGRESS", "conclusion": ""}]) == "pending (1)"
rev = recap.summarize_reviews(
    "CHANGES_REQUESTED",
    [{"author": {"login": "alice"}, "state": "CHANGES_REQUESTED", "body": "Please add retry backoff"}],
    [{"author": {"login": "bob"}, "body": "Looks good besides retry"}],
)
assert rev["state"] == "changes requested"
assert any("retry backoff" in n for n in rev["notes"])

# Langfuse allowlist filtering (mocked HTTP)
fake_obs = {
    "data": [
        {
            "sessionId": "sess-work",
            "environment": "opencode",
            "startTime": "2026-11-30T08:00:00Z",
            "metadata": {"repo": "acme-org/api"},
            "input": {"prompt": "Investigate ADE-99 timeout spike in worker pool"},
        },
        {
            "sessionId": "sess-local-match",
            "environment": "claude-code",
            "startTime": "2026-11-30T09:00:00Z",
            "metadata": {"cwd": "/tmp/work/web-app"},
            "input": "Trace flaky checkout test",
        },
        {
            "sessionId": "sess-personal",
            "environment": "opencode",
            "startTime": "2026-11-30T09:30:00Z",
            "metadata": {"repo": "rasmus/secret-side-project"},
            "input": "Personal project prompt",
        },
        {
            "sessionId": "sess-unknown",
            "environment": "pi",
            "startTime": "2026-11-30T09:45:00Z",
            "metadata": {},
            "input": "General chat",
        },
    ],
    "meta": {},
}

class FakeResp:
    def __init__(self, body):
        self._buf = io.BytesIO(json.dumps(body).encode())
    def read(self, *a):
        return self._buf.read(*a)
    def __enter__(self):
        return self
    def __exit__(self, *a):
        return False

warnings = []
with mock.patch.dict(os.environ, {"LANGFUSE_PUBLIC_KEY": "pk", "LANGFUSE_SECRET_KEY": "sk"}):
    with mock.patch("urllib.request.urlopen", return_value=FakeResp(fake_obs)):
        sessions = recap.collect_langfuse(
            "http://localhost:3000",
            ["acme-org"],
            dt.datetime(2026, 11, 29, 0, 0, tzinfo=dt.timezone.utc),
            {"/tmp/work/web-app": "acme-org/web"},
            ["ADE"],
            warnings,
        )

ids = {s["session_id"] for s in sessions}
assert ids == {"sess-work", "sess-local-match"}, f"unexpected sessions: {sessions}"
assert "sess-personal" not in ids and "sess-unknown" not in ids
work_s = next(s for s in sessions if s["session_id"] == "sess-work")
assert work_s["tickets"] == ["ADE-99"]
PY

# 2. Build two real local git repos: one in acme-org (allowed), one in rasmus (personal, excluded)
init_repo() {
  local dir=$1 remote=$2 file=$3 msg=$4
  mkdir -p "$dir"
  git -C "$dir" init -q -b feat/ade-42
  git -C "$dir" config user.name "Rasmus"
  git -C "$dir" config user.email "rasmus@example.com"
  git -C "$dir" remote add origin "$remote"
  echo "hello" >"$dir/$file"
  git -C "$dir" add "$file"
  git -C "$dir" commit -q -m "$msg"
  echo "wip change" >>"$dir/$file"
}
init_repo "$WORK/roots/web" "git@github.com:acme-org/web.git" "app.ts" "ADE-42 fix pagination edge case"
init_repo "$WORK/roots/notes" "git@github.com:rasmus/notes.git" "diary.md" "personal diary entry"

# Fake gh CLI returning allowed acme-org PRs plus a sneaky personal PR (defense-in-depth check)
cat >"$WORK/bin/gh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == search && "$2" == prs ]]; then
  if [[ "$*" == *"--merged"* ]]; then
    cat <<'JSON'
[
  {"number": 101, "title": "ADE-42 fix pagination", "url": "https://github.com/acme-org/api/pull/101", "repository": {"nameWithOwner": "acme-org/api"}, "closedAt": "2026-11-30T08:00:00Z", "updatedAt": "2026-11-30T08:00:00Z"},
  {"number": 999, "title": "secret personal PR", "url": "https://github.com/rasmus/secret/pull/999", "repository": {"nameWithOwner": "rasmus/secret"}, "closedAt": "2026-11-30T08:00:00Z", "updatedAt": "2026-11-30T08:00:00Z"}
]
JSON
  else
    cat <<'JSON'
[
  {"number": 102, "title": "Add circuit breaker", "url": "https://github.com/acme-org/api/pull/102", "repository": {"nameWithOwner": "acme-org/api"}, "updatedAt": "2026-11-30T09:00:00Z", "isDraft": false}
]
JSON
  fi
  exit 0
fi
if [[ "$1" == pr && "$2" == view ]]; then
  num=$3
  if [[ "$num" == 101 ]]; then
    cat <<'JSON'
{
  "number": 101,
  "title": "ADE-42 fix pagination",
  "url": "https://github.com/acme-org/api/pull/101",
  "headRefName": "fix/ade-42-pagination",
  "body": "Cursor pagination skipped the last row when limit matched page size. Fixed boundary condition and added regression tests.",
  "isDraft": false,
  "mergedAt": "2026-11-30T08:00:00Z",
  "updatedAt": "2026-11-30T08:00:00Z",
  "additions": 48,
  "deletions": 12,
  "changedFiles": 2,
  "files": [{"path": "src/paginate.ts"}, {"path": "src/paginate.test.ts"}],
  "reviewDecision": "APPROVED",
  "statusCheckRollup": [{"name": "ci", "status": "COMPLETED", "conclusion": "SUCCESS"}],
  "reviews": [{"author": {"login": "alice"}, "state": "APPROVED", "body": "Clean fix"}],
  "comments": []
}
JSON
  else
    cat <<'JSON'
{
  "number": 102,
  "title": "Add circuit breaker",
  "url": "https://github.com/acme-org/api/pull/102",
  "headRefName": "feat/circuit-breaker",
  "body": "Wraps outbound webhook calls with a sliding-window breaker.",
  "isDraft": false,
  "mergedAt": null,
  "updatedAt": "2026-11-30T09:00:00Z",
  "additions": 120,
  "deletions": 5,
  "changedFiles": 3,
  "files": [{"path": "src/breaker.ts"}],
  "reviewDecision": "CHANGES_REQUESTED",
  "statusCheckRollup": [{"name": "lint", "status": "COMPLETED", "conclusion": "FAILURE"}],
  "reviews": [{"author": {"login": "bob"}, "state": "CHANGES_REQUESTED", "body": "Make threshold configurable"}],
  "comments": []
}
JSON
  fi
  exit 0
fi
exit 1
FAKE

# Fake opencode recording prompts so we can inspect mood + payload
cat >"$WORK/bin/opencode" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
prompt="${@: -1}"
printf '%s\n' "$prompt" >"$SLACK_FAKE_DIR/last-prompt.txt"
mood=$(grep -m1 '^Mood: ' <<<"$prompt" | awk '{print $2}' || echo unknown)
jq -nc --arg t "summary($mood): shipped ADE-42 pagination fix; circuit breaker PR #102 needs lint + review" '{type: "text", part: {text: $t}}'
FAKE

# Fake slack for !bot recap tests
cat >"$WORK/bin/slack" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
case $1 in
  history) cat "$SLACK_FAKE_DIR/history.tsv" ;;
  thread) cat "$SLACK_FAKE_DIR/thread.tsv" ;;
  send)
    printf '%s\t%s\n' "id:$2" "$3" >>"$SLACK_FAKE_DIR/sent.tsv"
    echo "$(wc -l <"$SLACK_FAKE_DIR/sent.tsv" | tr -d ' ').1"
    ;;
  update)
    TS=$3 TEXT=$4 perl -i -ne 'BEGIN { @n = split /\./, $ENV{TS} } s/\t.*/\t$ENV{TEXT}\n/s if $. == $n[0]; print' "$SLACK_FAKE_DIR/sent.tsv"
    ;;
  whoami) echo "$FAKE_WHOAMI" ;;
  url) echo "https://acme.slack.com/" ;;
  info) echo relay-test ;;
  *) exit 9 ;;
esac
FAKE
chmod +x "$WORK/bin/gh" "$WORK/bin/opencode" "$WORK/bin/slack"

cat >"$WORK/config.json" <<EOF
{
  "channel": "C0000000001",
  "name": "Rasmus",
  "icon": ":hatched_chick:",
  "jira_url": "https://jira.example/",
  "jira_projects": ["ADE"],
  "user": "$ME",
  "dispatcher": { "label": "mac", "models": { "opencode": "cheap/model" }, "workdir": "$WORK/agent", "auto": false },
  "repos": {},
  "recap": {
    "github_orgs": [],
    "mood": "brief",
    "repo_roots": ["$WORK/roots"],
    "langfuse_url": ""
  }
}
EOF

export PATH="$WORK/bin:$PATH" SLACK_RELAY_SLACK_BIN="$WORK/bin/slack" FAKE_WHOAMI="$ME" \
  SLACK_FAKE_DIR="$WORK" SLACK_RELAY_INTERVAL=0 SLACK_RELAY_CONFIG="$WORK/config.json" SLACK_RELAY_STATE="$WORK/state"
relay="$ROOT/bin/slack-relay"
tab=$'\t'

# 3. Empty github_orgs must refuse instead of leaking personal repos
set +e
out=$("$relay" recap --raw 2>&1)
code=$?
set -e
[[ $code -ne 0 && "$out" == *"recap.github_orgs is empty"* ]] || fail "empty github_orgs should fail: $code $out"

# 4. Config validation for recap keys
"$relay" config set recap.github_orgs '["acme-org"]' >/dev/null || fail "valid recap.github_orgs rejected"
"$relay" config set recap.mood funny >/dev/null || fail "valid recap.mood rejected"
"$relay" config set recap.mood brief >/dev/null || fail "reset recap.mood failed"
"$relay" config set recap.mood sarcastic 2>/dev/null && fail "invalid recap.mood accepted"
"$relay" config set recap.langfuse_url ftp://bad 2>/dev/null && fail "invalid recap.langfuse_url accepted"

# 5. CLI --raw: 0-token deterministic dump, strictly scoped to acme-org
rm -f "$WORK/last-prompt.txt"
raw=$("$relay" recap --raw --now 2026-11-30T10:00:00Z)
[[ ! -e "$WORK/last-prompt.txt" ]] || fail "--raw must not invoke the LLM agent"
[[ "$raw" == *"Friday 2026-11-27"* ]] || fail "Monday lookback missing Friday: $raw"
[[ "$raw" == *"acme-org/api #101"* ]] || fail "merged PR missing: $raw"
[[ "$raw" == *"acme-org/api #102"* && "$raw" == *"failing (lint)"* && "$raw" == *"changes requested"* ]] || fail "open PR CI/review missing: $raw"
[[ "$raw" == *"acme-org/web"* && "$raw" == *"app.ts"* ]] || fail "allowed local git repo missing: $raw"
[[ "$raw" != *"rasmus/secret"* && "$raw" != *"rasmus/notes"* && "$raw" != *"diary.md"* ]] || fail "personal repo leaked into recap: $raw"

# 6. CLI --since 7d --mood funny & detailed
out=$("$relay" recap --since 7d --mood funny --now 2026-11-30T10:00:00Z)
[[ "$out" == *"summary(funny)"* ]] || fail "funny mood output mismatch: $out"
grep -Fq "Mood: funny" "$WORK/last-prompt.txt" || fail "funny mood prompt missing"
grep -Fq "Cursor pagination skipped" "$WORK/last-prompt.txt" || fail "PR body not passed to LLM"
! grep -Fq "rasmus/notes" "$WORK/last-prompt.txt" || fail "personal repo leaked into LLM prompt"

out=$("$relay" recap --since 7d --mood detailed --now 2026-11-30T10:00:00Z)
[[ "$out" == *"summary(detailed)"* ]] || fail "detailed mood output mismatch: $out"
grep -Fq "Mood: detailed" "$WORK/last-prompt.txt" || fail "detailed mood prompt missing"
grep -Fq "Make threshold configurable" "$WORK/last-prompt.txt" || fail "review comment not passed to LLM"

# 7. Slack !mac recap raw (0-token) and !mac recap 7d funny
rm -f "$WORK/sent.tsv" "$WORK/last-prompt.txt"
printf '%s\n' "1700000101.000000${tab}id:C0000000001${tab}$ME${tab}!mac recap raw" >"$WORK/history.tsv"
SLACK_RELAY_ONCE=1 SLACK_RELAY_SINCE=1700000100.000000 "$relay" serve 2>/dev/null
[[ ! -e "$WORK/last-prompt.txt" ]] || fail "Slack recap raw invoked the LLM"
grep -Fq "acme-org/api #101" "$WORK/sent.tsv" || fail "Slack recap raw missing PR: $(cat "$WORK/sent.tsv")"
! grep -Fq "rasmus/notes" "$WORK/sent.tsv" || fail "Slack recap raw leaked personal repo"

rm -f "$WORK/sent.tsv" "$WORK/last-prompt.txt"
printf '%s\n' "1700000102.000000${tab}id:C0000000001${tab}$ME${tab}!mac recap 7d funny" >"$WORK/history.tsv"
SLACK_RELAY_ONCE=1 SLACK_RELAY_SINCE=1700000101.000000 "$relay" serve 2>/dev/null
grep -Fq "summary(funny)" "$WORK/sent.tsv" || fail "Slack recap 7d funny failed: $(cat "$WORK/sent.tsv")"
grep -Fq "https://jira.example/browse/ADE-42|ADE-42" "$WORK/sent.tsv" || fail "Jira auto-linking missing in Slack recap: $(cat "$WORK/sent.tsv")"

rm -f "$WORK/sent.tsv"
printf '%s\n' "1700000103.000000${tab}id:C0000000001${tab}$ME${tab}!mac recap 7d detailed" >"$WORK/history.tsv"
SLACK_RELAY_ONCE=1 SLACK_RELAY_SINCE=1700000102.000000 "$relay" serve 2>/dev/null
grep -Fq "summary(detailed)" "$WORK/sent.tsv" || fail "Slack recap 7d detailed failed: $(cat "$WORK/sent.tsv")"

rm -f "$WORK/sent.tsv"
printf '%s\n' "1700000104.000000${tab}id:C0000000001${tab}$ME${tab}!mac recap nonsense" >"$WORK/history.tsv"
SLACK_RELAY_ONCE=1 SLACK_RELAY_SINCE=1700000103.000000 "$relay" serve 2>/dev/null
grep -Fq "Recap usage:" "$WORK/sent.tsv" || fail "Slack invalid recap args did not show usage: $(cat "$WORK/sent.tsv")"

echo "recap tests passed"
