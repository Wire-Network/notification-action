#!/usr/bin/env bash
#
# Build and send a workflow-status notification to Mattermost or Slack.
#
# Every input arrives through the environment rather than through `${{ }}`
# interpolation into this script body: workflow names, branch names and PR
# titles routinely contain quotes and other shell metacharacters.
#
# Status derivation fails closed. SUCCESS is reported only when at least one
# job result parsed and every one of them is exactly "success"; anything
# unrecognised surfaces as UNKNOWN, and input that parses to nothing is a hard
# error. A silent fallthrough to green is what let comma-separated `job-results`
# report success over failing builds for months.
#
# Set NOTIFY_DRY_RUN=1 to print the payload and skip the webhook call.

set -euo pipefail

readonly SLACK_TYPE=2

WEBHOOK_URL="${INPUT_WEBHOOK_URL:-}"
NOTIFICATION_TYPE="${INPUT_NOTIFICATION_TYPE:-1}"
CHANNEL="${INPUT_CHANNEL:-cicd-notifications}"
WORKFLOW_NAME="${INPUT_WORKFLOW_NAME:-}"
JOB_RESULTS="${INPUT_JOB_RESULTS:-}"
GITHUB_CONTEXT="${GITHUB_CONTEXT:-}"
DRY_RUN="${NOTIFY_DRY_RUN:-}"

# Informational output goes to stderr; stdout carries only the payload, which
# is what NOTIFY_DRY_RUN prints and what the tests assert on.
log() {
   printf '%s\n' "$*" >&2
}

# `::error::` stays on stdout: that is where the runner reads workflow commands.
die() {
   echo "::error::$*"
   exit 1
}

[[ -n "$WORKFLOW_NAME" ]] || die "workflow-name is empty"
[[ -n "$GITHUB_CONTEXT" ]] || die "github-context is empty"
[[ -n "$WEBHOOK_URL" || -n "$DRY_RUN" ]] || die "webhook-url is empty"
jq -e . <<<"$GITHUB_CONTEXT" >/dev/null 2>&1 || die "github-context is not valid JSON"

# Parse `job-results` into a {job: status} object, left in RESULTS_JSON.
#
# Accepts a JSON object, or `job:status` pairs separated by any mix of commas,
# spaces and newlines. Commas were never documented but both C++ build repos
# used them, so they are accepted rather than silently dropped.
#
# The result comes back through a global rather than a command substitution:
# `die` runs `exit`, which inside `$( )` would only end the subshell and would
# capture the `::error::` line into the caller's variable instead of logging it.
RESULTS_JSON=""
parse_job_results() {
   local raw="$1"

   if [[ "$raw" =~ ^[[:space:]]*\{ ]]; then
      jq -e 'type == "object" and length > 0 and all(.[]; type == "string" and length > 0)' \
         <<<"$raw" >/dev/null 2>&1 \
         || die "job-results looks like JSON but is not a non-empty object of non-empty strings: $raw"
      RESULTS_JSON="$(jq -c . <<<"$raw")"
      return
   fi

   local parsed
   parsed="$(
      jq -Rn --arg raw "$raw" '
         ($raw | gsub("[,[:space:]]+"; "\n") | split("\n") | map(select(length > 0))) as $tokens
         | {
              ok:  ($tokens | map(select(test("^[^:]+:[^:]+$")))
                            | map((index(":")) as $i | {key: .[0:$i], value: .[$i + 1:]})
                            | from_entries),
              bad: ($tokens | map(select(test("^[^:]+:[^:]+$") | not)))
           }
      '
   )"

   local bad
   bad="$(jq -r '.bad | join(", ")' <<<"$parsed")"
   [[ -z "$bad" ]] || die "job-results entries are not \`job:status\`: ${bad}"

   jq -e '.ok | length > 0' <<<"$parsed" >/dev/null \
      || die "job-results parsed to nothing: '${raw}'"

   RESULTS_JSON="$(jq -c '.ok' <<<"$parsed")"
}

# failure > cancelled > skipped > success, and anything else is UNKNOWN.
overall_status() {
   local json="$1"
   if jq -e 'any(.[]; . == "failure")' <<<"$json" >/dev/null; then
      echo failure
   elif jq -e 'any(.[]; . == "cancelled")' <<<"$json" >/dev/null; then
      echo cancelled
   elif jq -e 'any(.[]; . == "skipped")' <<<"$json" >/dev/null; then
      echo skipped
   elif jq -e 'length > 0 and all(.[]; . == "success")' <<<"$json" >/dev/null; then
      echo success
   else
      echo unknown
   fi
}

# emoji|text|mattermost colour|slack colour
status_info() {
   case "$1" in
      success)   echo "✅|SUCCESS|#00FF00|good" ;;
      failure)   echo "❌|FAILURE|#FF0000|danger" ;;
      cancelled) echo "⚫|CANCELLED|#808080|#808080" ;;
      skipped)   echo "⏭️|SKIPPED|#FFA500|warning" ;;
      *)         echo "❓|UNKNOWN|#808080|#808080" ;;
   esac
}

format_job_name() {
   echo "$1" | sed 's/-/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))}1'
}

log "Parsing job results..."
log "  Raw: $JOB_RESULTS"
parse_job_results "$JOB_RESULTS"
log "  Parsed: $RESULTS_JSON"

OVERALL_STATUS="$(overall_status "$RESULTS_JSON")"
log "  Overall: $OVERALL_STATUS"

IFS='|' read -r STATUS_EMOJI STATUS_TEXT COLOR SLACK_COLOR <<<"$(status_info "$OVERALL_STATUS")"

REPOSITORY="$(jq -r '.repository' <<<"$GITHUB_CONTEXT")"
REF_NAME="$(jq -r '.ref_name' <<<"$GITHUB_CONTEXT")"
HEAD_REF="$(jq -r '.head_ref // ""' <<<"$GITHUB_CONTEXT")"
COMMIT_SHA="$(jq -r '.sha' <<<"$GITHUB_CONTEXT")"
ACTOR="$(jq -r '.actor' <<<"$GITHUB_CONTEXT")"
RUN_ID="$(jq -r '.run_id' <<<"$GITHUB_CONTEXT")"
SERVER_URL="$(jq -r '.server_url' <<<"$GITHUB_CONTEXT")"
EVENT_NAME="$(jq -r '.event_name' <<<"$GITHUB_CONTEXT")"
PR_NUMBER="$(jq -r '.event.pull_request.number // ""' <<<"$GITHUB_CONTEXT")"
PR_URL="$(jq -r '.event.pull_request.html_url // ""' <<<"$GITHUB_CONTEXT")"

if [[ "$EVENT_NAME" == "pull_request" && -n "$HEAD_REF" ]]; then
   BRANCH="$HEAD_REF"
else
   BRANCH="$REF_NAME"
fi

SHORT_SHA="${COMMIT_SHA:0:7}"
REPO_URL="${SERVER_URL}/${REPOSITORY}"
BRANCH_URL="${SERVER_URL}/${REPOSITORY}/tree/${BRANCH}"
COMMIT_URL="${SERVER_URL}/${REPOSITORY}/commit/${COMMIT_SHA}"
RUN_URL="${SERVER_URL}/${REPOSITORY}/actions/runs/${RUN_ID}"

# Process substitution, not a pipe: a `while read` on the right of a pipe runs
# in a subshell and every JOB_DETAILS append is discarded when it exits.
JOB_DETAILS=""
while IFS=$'\t' read -r job result; do
   if [[ "$result" != "success" ]]; then
      job_emoji="$(status_info "$result" | cut -d'|' -f1)"
      JOB_DETAILS+="
- **$(format_job_name "$job")**: ${job_emoji} ${result}"
   fi
done < <(jq -r 'to_entries[] | "\(.key)\t\(.value)"' <<<"$RESULTS_JSON")

TITLE="${STATUS_EMOJI} ${STATUS_TEXT}: ${WORKFLOW_NAME}"

if [[ "$NOTIFICATION_TYPE" == "$SLACK_TYPE" ]]; then
   PR_LINE=""
   [[ -n "$PR_NUMBER" ]] && PR_LINE="
*PR:* <${PR_URL}|#${PR_NUMBER}>"
   TEXT="*Repository:* <${REPO_URL}|${REPOSITORY}>
*Branch:* <${BRANCH_URL}|${BRANCH}>${PR_LINE}
*Commit:* <${COMMIT_URL}|\`${SHORT_SHA}\`>
*Triggered by:* ${ACTOR}
*Workflow Run:* <${RUN_URL}|View Details>${JOB_DETAILS}"

   PAYLOAD="$(
      jq -n --arg channel "$CHANNEL" --arg color "$SLACK_COLOR" --arg title "$TITLE" --arg text "$TEXT" \
         '{
             channel: $channel,
             username: "GitHub Actions",
             icon_url: "https://github.githubassets.com/images/modules/logos_page/GitHub-Mark.png",
             attachments: [{
                color: $color,
                title: $title,
                text: $text,
                footer: "GitHub Actions",
                footer_icon: "https://github.githubassets.com/images/modules/logos_page/GitHub-Mark.png"
             }]
          }'
   )"
else
   PR_LINE=""
   [[ -n "$PR_NUMBER" ]] && PR_LINE="
**PR**: [#${PR_NUMBER}](${PR_URL})"
   TEXT="**Repository**: [${REPOSITORY}](${REPO_URL})
**Branch**: [${BRANCH}](${BRANCH_URL})${PR_LINE}
**Commit**: [\`${SHORT_SHA}\`](${COMMIT_URL})
**Triggered by**: ${ACTOR}
**Workflow Run**: [View Details](${RUN_URL})${JOB_DETAILS}"

   PAYLOAD="$(
      jq -n --arg channel "$CHANNEL" --arg color "$COLOR" --arg title "$TITLE" --arg text "$TEXT" \
         '{
             channel: $channel,
             username: "GitHub Actions",
             icon_url: "https://github.githubassets.com/images/modules/logos_page/GitHub-Mark.png",
             attachments: [{ color: $color, title: $title, text: $text }]
          }'
   )"
fi

if [[ -n "$DRY_RUN" ]]; then
   printf '%s\n' "$PAYLOAD"
   exit 0
fi

log "Sending notification..."
HTTP_STATUS="$(
   curl -s -o /dev/null -w "%{http_code}" -X POST "$WEBHOOK_URL" \
      -H "Content-Type: application/json" \
      --data-binary @- <<<"$PAYLOAD"
)"
log "  HTTP Response: $HTTP_STATUS"

if [[ "$HTTP_STATUS" -ge 200 && "$HTTP_STATUS" -lt 300 ]]; then
   log "Notification sent successfully."
else
   printf 'Payload sent:\n%s\n' "$PAYLOAD" >&2
   die "notification failed with HTTP ${HTTP_STATUS}"
fi
