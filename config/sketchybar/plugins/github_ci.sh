#!/usr/bin/env bash

export PATH="/run/current-system/sw/bin:$HOME/.nix-profile/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

GH="$(command -v gh)"
JQ="/usr/bin/jq"
SKETCHYBAR="$(command -v sketchybar)"

CYAN=0xff31c5ed
GREEN=0xff2cc6a3
PINK=0xfffc62b1

PREV_PENDING_FILE="/tmp/sketchybar-github-prev-pending"
SUCCESS_UNTIL_FILE="/tmp/sketchybar-github-success-until"
URL_FILE="/tmp/sketchybar-github-ci.url"

# No gh / not authenticated → hide
if [ -z "$GH" ]; then
  "$SKETCHYBAR" --set "$NAME" drawing=off
  exit 0
fi

PENDING_JSON="$(
  "$GH" search prs \
    --author @me \
    --state open \
    --checks pending \
    --limit 50 \
    --json url \
    2>/dev/null
)" || {
  "$SKETCHYBAR" --set "$NAME" drawing=off
  exit 0
}

FAILED_JSON="$(
  "$GH" search prs \
    --author @me \
    --state open \
    --checks failure \
    --limit 50 \
    --json url \
    2>/dev/null
)" || FAILED_JSON="[]"

PENDING="$(printf '%s' "$PENDING_JSON" | "$JQ" 'length')"
FAILED="$(printf '%s' "$FAILED_JSON" | "$JQ" 'length')"

PENDING_URL="$(printf '%s' "$PENDING_JSON" | "$JQ" -r '.[0].url // empty')"
FAILED_URL="$(printf '%s' "$FAILED_JSON" | "$JQ" -r '.[0].url // empty')"

PREV_PENDING=0

if [ -f "$PREV_PENDING_FILE" ]; then
  PREV_PENDING="$(cat "$PREV_PENDING_FILE")"
fi

NOW="$(date +%s)"

# Remember current PR
if [ "$FAILED" -gt 0 ] && [ -n "$FAILED_URL" ]; then
  printf '%s' "$FAILED_URL" >"$URL_FILE"

elif [ "$PENDING" -gt 0 ] && [ -n "$PENDING_URL" ]; then
  printf '%s' "$PENDING_URL" >"$URL_FILE"
fi

# A previously-running pipeline just finished successfully.
if [ "$PREV_PENDING" -gt 0 ] &&
  [ "$PENDING" -eq 0 ] &&
  [ "$FAILED" -eq 0 ]; then
  echo $((NOW + 300)) >"$SUCCESS_UNTIL_FILE"
fi

echo "$PENDING" >"$PREV_PENDING_FILE"

# ─────────────────────────────────────────────
# Render
# ─────────────────────────────────────────────

if [ "$FAILED" -gt 0 ]; then
  rm -f "$SUCCESS_UNTIL_FILE"

  "$SKETCHYBAR" --set "$NAME" \
    drawing=on \
    label="✕ $FAILED" \
    label.color="$PINK"

  exit 0
fi

if [ "$PENDING" -gt 0 ]; then
  "$SKETCHYBAR" --set "$NAME" \
    drawing=on \
    label="◌ $PENDING" \
    label.color="$CYAN"

  exit 0
fi

SUCCESS_UNTIL=0

if [ -f "$SUCCESS_UNTIL_FILE" ]; then
  SUCCESS_UNTIL="$(cat "$SUCCESS_UNTIL_FILE")"
fi

if [ "$SUCCESS_UNTIL" -gt "$NOW" ]; then
  "$SKETCHYBAR" --set "$NAME" \
    drawing=on \
    label="✓" \
    label.color="$GREEN"
else
  "$SKETCHYBAR" --set "$NAME" drawing=off
fi
