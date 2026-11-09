#!/usr/bin/env bash

FOCUSED_WORKSPACE="${AEROSPACE_FOCUSED_WORKSPACE:-$(aerospace list-workspaces --focused)}"
CYAN=0xff31c5ed
MUTED=0xff78858c
SURFACE=0xff101315

for WORKSPACE in 1 2 3 4 5 10; do
  if [ "$WORKSPACE" = "$FOCUSED_WORKSPACE" ]; then
    sketchybar --set "space.$WORKSPACE" \
      label.color=$CYAN \
      background.color=$SURFACE \
      background.drawing=on
  else
    sketchybar --set "space.$WORKSPACE" \
      label.color=$MUTED \
      background.drawing=off
  fi
done
