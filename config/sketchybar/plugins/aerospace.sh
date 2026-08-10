#!/usr/bin/env bash

WORKSPACE="$1"

CYAN=0xff31c5ed
MUTED=0xff78858c
SURFACE=0xff101315

if [ "$WORKSPACE" = "$FOCUSED_WORKSPACE" ]; then
  sketchybar --set "$NAME" \
    label.color=$CYAN \
    background.color=$SURFACE \
    background.drawing=on
else
  sketchybar --set "$NAME" \
    label.color=$MUTED \
    background.drawing=off
fi
