#!/usr/bin/env bash

URL_FILE="/tmp/sketchybar-github-ci.url"

if [ -f "$URL_FILE" ]; then
  URL="$(cat "$URL_FILE")"

  if [ -n "$URL" ]; then
    open "$URL"
  fi
fi
