#!/usr/bin/env bash

WHITE=0xffd8e1e6
GREEN=0xff2cc6a3
ORANGE=0xfffaaa57
PINK=0xfffc62b1

PERCENTAGE="$(pmset -g batt | grep -Eo '[0-9]+%' | head -1 | tr -d '%')"

COLOR=$WHITE

if pmset -g batt | grep -q "AC Power"; then
  COLOR=$GREEN
elif [ "$PERCENTAGE" -le 15 ]; then
  COLOR=$PINK
elif [ "$PERCENTAGE" -le 30 ]; then
  COLOR=$ORANGE
fi

sketchybar --set "$NAME" \
  label="${PERCENTAGE}%" \
  label.color="$COLOR"
