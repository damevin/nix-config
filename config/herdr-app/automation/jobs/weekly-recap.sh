#!/bin/sh
set -e
R=livestorm/entropy
S=${SINCE:-$(/bin/date -v-mon +%F)}
E=${UNTIL:-$(/bin/date +%F)}
me=$(gh api user -q .login)
row='.[] | "- #\(.number) \(.title) \(.url)"'

echo "Week: $S to $E. Repository: $R. Me: @$me."
echo
echo "## Merged PRs I wrote"
gh search prs --author @me --repo $R --merged-at "$S..$E" --json number,title,url --limit 100 | jq -r "$row"
echo
echo "## PRs I opened that are still open"
gh search prs --author @me --repo $R --created "$S..$E" --state open --json number,title,url,isDraft --limit 100 | jq -r '.[] | "- #\(.number) \(.title)\(if .isDraft then " (draft)" else "" end) \(.url)"'
echo
echo "## Older PRs of mine still open"
gh search prs --author @me --repo $R --created "<$S" --state open --json number,title,url --limit 30 | jq -r "$row"
echo
echo "## PRs from others I reviewed"
gh search prs --reviewed-by @me --repo $R --updated "$S..$E" --json number,title,url,author --limit 100 | jq -r --arg me "$me" '.[] | select(.author.login != $me) | "- #\(.number) \(.title) by @\(.author.login) \(.url)"'
