#!/usr/bin/env bash

BADGE="$(
  /usr/bin/osascript <<'APPLESCRIPT'
tell application "System Events"
  tell process "Dock"
    try
      set badgeValue to value of attribute "AXStatusLabel" of UI element "Slack" of list 1

      if badgeValue is missing value then
        return ""
      end if

      return badgeValue as text
    on error
      return ""
    end try
  end tell
end tell
APPLESCRIPT
)"

if [ -z "$BADGE" ]; then
  sketchybar --set "$NAME" drawing=off
else
  sketchybar --set "$NAME" drawing=on
fi
