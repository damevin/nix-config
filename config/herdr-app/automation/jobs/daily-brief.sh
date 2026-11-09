#!/bin/sh
set -e
R=livestorm/entropy
TODAY=$(/bin/date +%F)
NOTE="$HOME/Documents/observatory/12. journal/daily/$TODAY.md"
STATE="$HOME/.local/state/acc-automation"

echo "Today: $TODAY ($(/bin/date +%A))."
echo
echo "## My daily note: open tasks"
if [ -f "$NOTE" ]; then grep -E '^[[:space:]]*- \[ \] .+' "$NOTE" || echo "(none)"; else echo "(no daily note yet)"; fi
echo
echo "## PRs waiting for my review (oldest first)"
gh search prs --review-requested @me --repo $R --state open --sort created --order asc --json number,title,url,author,createdAt,isDraft --limit 40 \
  | jq -r '.[] | "- #\(.number) \(.title) by @\(.author.login), opened \(.createdAt[:10])\(if .isDraft then " (draft)" else "" end) \(.url)"'
echo
echo "## My open PRs"
gh pr list -R $R --author @me --state open --limit 40 --json number,title,url,isDraft,reviewDecision,mergeable,updatedAt,statusCheckRollup \
  | jq -r '.[] | ([.statusCheckRollup[]? | (.conclusion // .state // "PENDING")] as $c
      | "- #\(.number) \(.title)\(if .isDraft then " (draft)" else "" end) · review: \(.reviewDecision // "" | if . == "" then "none" else . end) · checks: \(if ($c | map(select(. == "FAILURE" or . == "ERROR" or . == "TIMED_OUT")) | length) > 0 then "FAILING" elif ($c | map(select(. == "PENDING" or . == "IN_PROGRESS" or . == "QUEUED" or . == "EXPECTED")) | length) > 0 then "running" else "green" end) · \(.mergeable) · updated \(.updatedAt[:10]) \(.url)")'
echo
echo "## Slack pings waiting on me (from my Automation inbox)"
cat "$STATE"/findings/slack-pings--*.json 2>/dev/null | jq -r 'select(.status == "new") | "- [\(.severity)] \(.title): \(.summary) \(.url // "")"' || true
echo
echo "## Other open items in my Automation inbox"
cat "$STATE"/findings/*.json 2>/dev/null | jq -r 'select(.status == "new" and .kind != "report" and .job != "slack-pings") | "- [\(.severity)] (\(.job)) \(.title)"' || true
