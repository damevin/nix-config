#!/bin/sh
# linear-issue.sh LIV-1 [LIV-2 ...]: prints the issues found as Linear's GraphQL JSON (data.issues.nodes).
# Unknown ids are just missing. The key comes from secretspec straight into curl's environment.
set -eu
[ $# -gt 0 ] || { echo "usage: linear-issue.sh LIV-123 [...]" >&2; exit 2; }
nums=''
for id in "$@"; do
  case "$id" in [Ll][Ii][Vv]-[0-9]*) ;; *) echo "bad id: $id" >&2; exit 2 ;; esac
  num=${id#*-}
  case "$num" in *[!0-9]*) echo "bad id: $id" >&2; exit 2 ;; esac
  nums="$nums$num,"
done
q="{ issues(first: 50, filter: { team: { key: { eq: \\\"LIV\\\" } }, number: { in: [${nums%,}] } }) { nodes { identifier title url description priorityLabel state { name type } assignee { name } } } }"
payload=$(printf '{"query":"%s"}' "$q")
exec secretspec run --file "$HOME/nix-config/config/secretspec/opencode/secretspec.toml" --reason "Tern Tasks panel reads Linear $*" -- \
  sh -c 'curl -sS --max-time 15 https://api.linear.app/graphql -H "Content-Type: application/json" -H "Authorization: $LINEAR_API_KEY" --data "$1"' sh "$payload"
