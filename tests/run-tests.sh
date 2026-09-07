#!/usr/bin/env bash
#
# Table-driven tests for scripts/notify.sh, run in dry-run mode so no webhook is
# contacted. Every case asserts on the payload the action would actually POST.

set -uo pipefail

readonly HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly NOTIFY="${HERE}/../scripts/notify.sh"

PASS=0
FAIL=0

readonly PR_CONTEXT='{
  "repository": "Wire-Network/wire-sysio",
  "ref_name": "599/merge",
  "head_ref": "feature/wire-367-producer-registration",
  "sha": "c53fce9b1162720060594c3ad3d063af125bbff4",
  "actor": "heifner",
  "run_id": "34144933071",
  "server_url": "https://github.com",
  "event_name": "pull_request",
  "event": { "pull_request": { "number": 599, "html_url": "https://github.com/Wire-Network/wire-sysio/pull/599" } }
}'

readonly PUSH_CONTEXT='{
  "repository": "Wire-Network/wire-cdt",
  "ref_name": "master",
  "head_ref": "",
  "sha": "532f3841b0000000000000000000000000000000",
  "actor": "heifner",
  "run_id": "1",
  "server_url": "https://github.com",
  "event_name": "push",
  "event": {}
}'

# run <job-results> [notification-type] [context] [workflow-name]
run() {
   NOTIFY_DRY_RUN=1 \
   INPUT_WEBHOOK_URL="" \
   INPUT_NOTIFICATION_TYPE="${2:-1}" \
   INPUT_CHANNEL="cicd-notifications" \
   INPUT_WORKFLOW_NAME="${4:-Build & Test Workflow}" \
   INPUT_JOB_RESULTS="$1" \
   GITHUB_CONTEXT="${3:-$PR_CONTEXT}" \
      bash "$NOTIFY" 2>/dev/null
}

ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL %s\n       %s\n' "$1" "$2"; }

# assert_status <name> <job-results> <expected title fragment>
assert_status() {
   local name="$1" input="$2" want="$3"
   local out title
   out="$(run "$input")" || { bad "$name" "script exited non-zero"; return; }
   title="$(jq -r '.attachments[0].title' <<<"$out" 2>/dev/null)"
   [[ "$title" == *"$want"* ]] && ok "$name" || bad "$name" "title was '${title}', wanted '*${want}*'"
}

# assert_rejects <name> <job-results>
#
# A rejection must both exit non-zero and say why: `die` called from a command
# substitution ends only the subshell and its `::error::` line is captured into
# the caller's variable instead of reaching the log.
assert_rejects() {
   local name="$1" input="$2"
   local out status
   out="$(
      NOTIFY_DRY_RUN=1 \
      INPUT_WEBHOOK_URL="" \
      INPUT_NOTIFICATION_TYPE=1 \
      INPUT_WORKFLOW_NAME="Build & Test Workflow" \
      INPUT_JOB_RESULTS="$input" \
      GITHUB_CONTEXT="$PR_CONTEXT" \
         bash "$NOTIFY" 2>&1
   )"
   status=$?
   if [[ "$status" -eq 0 ]]; then
      bad "$name" "expected a non-zero exit, got success"
   elif [[ "$out" != *"::error::"* ]]; then
      bad "$name" "exited non-zero but logged no ::error:: reason; output was: ${out}"
   else
      ok "$name"
   fi
}

echo "Separator handling"
# The regression: both C++ build repos passed commas, which parsed to {} and
# reported SUCCESS over failing builds.
assert_status "comma-separated, one failure  -> FAILURE" \
   "build-test-package:failure,root-node-tooling:success,verify-packages:skipped" "❌ FAILURE"
assert_status "comma-separated, all success  -> SUCCESS" \
   "discover:success,build-platforms:success,build:success" "✅ SUCCESS"
assert_status "space-separated, one failure  -> FAILURE" \
   "platform-cache:success build-test-package:failure verify-packages:skipped" "❌ FAILURE"
assert_status "newline-separated (README)    -> SKIPPED" \
   "$(printf 'tests:success\nnp-tests:skipped\n')" "⏭️ SKIPPED"
assert_status "mixed comma/space/newline     -> FAILURE" \
   "$(printf 'a:success, b:failure\n c:success')" "❌ FAILURE"
assert_status "single pair                   -> SUCCESS" \
   "build-and-test:success" "✅ SUCCESS"
assert_status "JSON object (README)          -> FAILURE" \
   '{"tests":"success","build":"failure","deploy":"skipped"}' "❌ FAILURE"

echo
echo "Status precedence"
assert_status "failure beats cancelled" "a:cancelled b:failure" "❌ FAILURE"
assert_status "cancelled beats skipped" "a:skipped b:cancelled"  "⚫ CANCELLED"
assert_status "skipped beats success"   "a:success b:skipped"    "⏭️ SKIPPED"

echo
echo "Fails closed"
assert_status "unrecognised status is not SUCCESS" "a:success b:borked" "❓ UNKNOWN"
assert_rejects "empty job-results"        ""
assert_rejects "no colon in entry"        "build-test-package"
assert_rejects "empty status (bad needs)" "build-test-package:"
assert_rejects "JSON that is not an object" '{"nope"}'
assert_rejects "empty JSON object"        '{}'

echo
echo "Payload contents"
out="$(run "build:failure verify:success deploy:skipped")"
text="$(jq -r '.attachments[0].text' <<<"$out")"
[[ "$text" == *"- **Build**: ❌ failure"* ]] \
   && ok "failing job is listed in the body" \
   || bad "failing job is listed in the body" "body was: ${text}"
[[ "$text" == *"- **Deploy**: ⏭️ skipped"* ]] \
   && ok "skipped job is listed in the body" \
   || bad "skipped job is listed in the body" "body was: ${text}"
[[ "$text" != *"Verify"* ]] \
   && ok "successful job is not listed" \
   || bad "successful job is not listed" "body was: ${text}"
[[ "$(jq -r '.attachments[0].color' <<<"$out")" == "#FF0000" ]] \
   && ok "failure colour is red" \
   || bad "failure colour is red" "got $(jq -r '.attachments[0].color' <<<"$out")"

echo
echo "Context handling"
out="$(run "a:success")"
[[ "$(jq -r '.attachments[0].text' <<<"$out")" == *"**PR**: [#599]"* ]] \
   && ok "PR event includes the PR line" || bad "PR event includes the PR line" "missing"
[[ "$(jq -r '.attachments[0].text' <<<"$out")" == *"feature/wire-367-producer-registration"* ]] \
   && ok "PR event uses head_ref as the branch" || bad "PR event uses head_ref as the branch" "missing"
out="$(run "a:success" 1 "$PUSH_CONTEXT")"
[[ "$(jq -r '.attachments[0].text' <<<"$out")" != *"**PR**"* ]] \
   && ok "push event omits the PR line" || bad "push event omits the PR line" "present"
[[ "$(jq -r '.attachments[0].text' <<<"$out")" == *"[master]"* ]] \
   && ok "push event uses ref_name as the branch" || bad "push event uses ref_name as the branch" "missing"

echo
echo "Payload is valid JSON under hostile input"
out="$(run 'a:failure' 1 "$PR_CONTEXT" 'Build "quoted" & $(whoami) `id` \ Workflow')"
if jq -e . <<<"$out" >/dev/null 2>&1; then
   title="$(jq -r '.attachments[0].title' <<<"$out")"
   [[ "$title" == *'Build "quoted" & $(whoami) `id` \ Workflow'* ]] \
      && ok "quotes and metacharacters survive verbatim" \
      || bad "quotes and metacharacters survive verbatim" "title was: ${title}"
else
   bad "quotes and metacharacters survive verbatim" "payload was not valid JSON: ${out}"
fi

echo
echo "Slack payload"
out="$(run "a:failure" 2)"
[[ "$(jq -r '.attachments[0].color' <<<"$out")" == "danger" ]] \
   && ok "slack uses named colours" || bad "slack uses named colours" "got $(jq -r '.attachments[0].color' <<<"$out")"
[[ "$(jq -r '.attachments[0].text' <<<"$out")" == *"<https://github.com/Wire-Network/wire-sysio|Wire-Network/wire-sysio>"* ]] \
   && ok "slack uses <url|label> links" || bad "slack uses <url|label> links" "missing"

echo
echo "Replay of wire-sysio run 34144933071 (gcc leg failed)"
assert_status "reports FAILURE, not SUCCESS" \
   "platform-cache:success discover-versions:success build-test-package:failure root-node-tooling:success verify-packages:skipped" \
   "❌ FAILURE"

echo
echo "Webhook delivery"
# The one path the dry run cannot cover: the real curl call, and whether what
# lands on the wire is the JSON the receiver will accept.
SINK_PORT=8099
SINK_LOG="$(mktemp)"
python3 "${HERE}/webhook-sink.py" "$SINK_PORT" "$SINK_LOG" &
SINK_PID=$!
trap 'kill "$SINK_PID" 2>/dev/null; rm -f "$SINK_LOG"' EXIT

for _ in $(seq 1 50); do
   curl -sf -X POST "http://127.0.0.1:${SINK_PORT}" \
      -H 'Content-Type: application/json' -d '{"attachments":[]}' >/dev/null 2>&1 && break
   sleep 0.2
done
: > "$SINK_LOG"

if NOTIFY_DRY_RUN= \
   INPUT_WEBHOOK_URL="http://127.0.0.1:${SINK_PORT}" \
   INPUT_NOTIFICATION_TYPE=1 \
   INPUT_CHANNEL="cicd-notifications" \
   INPUT_WORKFLOW_NAME='Build "quoted" & $(whoami) Workflow' \
   INPUT_JOB_RESULTS="build:failure verify:success" \
   GITHUB_CONTEXT="$PR_CONTEXT" \
   bash "$NOTIFY" >/dev/null 2>&1; then
   ok "posts to the webhook and accepts 2xx"
else
   bad "posts to the webhook and accepts 2xx" "script exited non-zero"
fi

delivered="$(cat "$SINK_LOG")"
if [[ -n "$delivered" ]] && jq -e . <<<"$delivered" >/dev/null 2>&1; then
   ok "the receiver got well-formed JSON"
   [[ "$(jq -r '.attachments[0].title' <<<"$delivered")" == *"❌ FAILURE"* ]] \
      && ok "the delivered payload carries the real status" \
      || bad "the delivered payload carries the real status" "title was $(jq -r '.attachments[0].title' <<<"$delivered")"
else
   bad "the receiver got well-formed JSON" "sink recorded: ${delivered:-<nothing>}"
   bad "the delivered payload carries the real status" "nothing delivered"
fi

# A webhook that does not answer 2xx must fail the step, not pass silently.
# Port 1 is closed, so curl reports 000.
if NOTIFY_DRY_RUN= \
   INPUT_WEBHOOK_URL="http://127.0.0.1:1/" \
   INPUT_NOTIFICATION_TYPE=1 \
   INPUT_WORKFLOW_NAME="W" \
   INPUT_JOB_RESULTS="a:success" \
   GITHUB_CONTEXT="$PUSH_CONTEXT" \
   bash "$NOTIFY" >/dev/null 2>&1; then
   bad "an unreachable webhook fails the step" "expected non-zero exit"
else
   ok "an unreachable webhook fails the step"
fi

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
