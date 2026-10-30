#!/usr/bin/env bash
# The built-in Slack client against a fake curl: credentials, rows, threads, bot authors, sends.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/slack-relay-api.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
printf 'xoxc-fake-token\n' >"$WORK/token"
printf 'fake-cookie' >"$WORK/cookie"

cat >"$WORK/bin/curl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in *fake-token*|*fake-cookie*) echo "credentials on the command line" >&2; exit 97 ;; esac
method=GET out= config= url= params=()
while (( $# )); do
  case "$1" in
    --config) config=$2; shift 2 ;;
    -o) out=$2; shift 2 ;;
    -X) method=$2; shift 2 ;;
    -w|--max-time|--connect-timeout) shift 2 ;;
    --data-urlencode) params+=("$2"); shift 2 ;;
    http*) url=$1; shift ;;
    *) shift ;;
  esac
done
grep -Fq 'header = "Authorization: Bearer xoxc-fake-token"' "$config"
if [[ "${FAKE_NO_COOKIE:-}" != 1 ]]; then grep -Fq 'cookie = "d=fake-cookie"' "$config"; fi
endpoint=${url##*/}
printf '%s %s %s\n' "$method" "$endpoint" "${params[*]}" >>"$FAKE_LOG"
case "$endpoint" in
  auth.test) response='{"ok":true,"user_id":"U0123456789"}' ;;
  conversations.history)
    response='{"ok":true,"messages":[
      {"ts":"300.000","user":"U0123456789","text":"@bot boss hi"},
      {"ts":"200.000","user":"U0123456789","text":"parent","thread_ts":"200.000","reply_count":2,"latest_reply":"250.000"},
      {"ts":"150.000","bot_id":"B1","username":"U0123456789","text":"@bot boss spoofed"},
      {"ts":"90.000","user":"U0123456789","text":"old parent","thread_ts":"90.000","reply_count":1,"latest_reply":"95.000"}]}'
    ;;
  conversations.replies)
    [[ " ${params[*]} " == *" ts=200.000 "* ]] || exit 93
    response='{"ok":true,"messages":[
      {"ts":"200.000","user":"U0123456789","text":"parent","thread_ts":"200.000"},
      {"ts":"250.000","user":"U0123456789","text":"@bot boss in thread","thread_ts":"200.000"}]}'
    ;;
  chat.postMessage) response='{"ok":true,"ts":"400.000"}' ;;
  *) exit 94 ;;
esac
printf '%s' "$response" >"$out"
printf '200'
FAKE
chmod +x "$WORK/bin/curl"

jq -n --arg t "$WORK/token" --arg c "$WORK/cookie" \
  '{channel: "C0000000001", user: "U0123456789", slack: {token_file: $t, cookie_file: $c}}' >"$WORK/config.json"
export SLACK_RELAY_CONFIG="$WORK/config.json" SLACK_RELAY_STATE="$WORK/state" SLACK_RELAY_CURL="$WORK/bin/curl" FAKE_LOG="$WORK/requests"
relay="$ROOT/bin/slack-relay"
tab=$'\t'
fail() { echo "FAIL: $*" >&2; exit 1; }

[[ "$("$relay" _slack whoami)" == U0123456789 ]] || fail "whoami"

rows=$("$relay" _slack history C0000000001 50 100.000)
[[ "$(grep -c . <<<"$rows")" -eq 5 ]] || fail "expected 4 channel rows and 1 reply: $rows"
grep -Fxq "250.000${tab}id:C0000000001${tab}U0123456789${tab}@bot boss in thread${tab}200.000" <<<"$rows" || fail "thread reply row: $rows"
grep -Fxq "150.000${tab}id:C0000000001${tab}bot:B1${tab}@bot boss spoofed${tab}" <<<"$rows" || fail "bot post must not look like the user: $rows"
[[ "$(grep -c 'conversations.replies' "$FAKE_LOG")" -eq 1 ]] || fail "replies fetched for inactive threads: $(cat "$FAKE_LOG")"
grep -q 'conversations.replies .*oldest=100.000' "$FAKE_LOG" || fail "replies not limited to new ones"

rows=$("$relay" _slack history C0000000001 1)
! grep -q 'conversations.replies' <(tail -n 1 "$FAKE_LOG") || fail "history without since fetched threads"

thread=$("$relay" _slack thread C0000000001 200.000 50)
[[ "$(cut -f1 <<<"$thread" | paste -sd, -)" == "200.000,250.000" ]] || fail "thread rows: $thread"

"$relay" _slack send C0000000001 "hello & <you>" -
grep -Fxq 'POST chat.postMessage channel=C0000000001 text=hello & <you>' "$FAKE_LOG" || fail "send: $(tail -n 1 "$FAKE_LOG")"
"$relay" _slack send C0000000001 "in thread" 200.000
grep -Fxq 'POST chat.postMessage channel=C0000000001 text=in thread thread_ts=200.000' "$FAKE_LOG" || fail "thread send: $(tail -n 1 "$FAKE_LOG")"

jq '.slack.cookie_file = ""' "$WORK/config.json" >"$WORK/c.json" && mv "$WORK/c.json" "$WORK/config.json"
set +e
out=$(FAKE_NO_COOKIE=1 "$relay" _slack whoami 2>&1)
code=$?
set -e
[[ $code -ne 0 && "$out" == *"needs its d cookie"* ]] || fail "xoxc token without cookie: $code $out"

echo "slack api tests passed"
