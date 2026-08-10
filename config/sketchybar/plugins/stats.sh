#!/usr/bin/env bash

export PATH="/run/current-system/sw/bin:$HOME/.nix-profile/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
# ─────────────────────────────────────────────
# Config
# ─────────────────────────────────────────────

GREEN=0xff2cc6a3
ORANGE=0xfffaaa57
PINK=0xfffc62b1
MUTED=0xff78858c

CACHE="/tmp/sketchybar-network-quality.json"

JQ="/usr/bin/jq"
NETWORK_QUALITY="/usr/bin/networkQuality"
SKETCHYBAR="$(command -v sketchybar)"

# ─────────────────────────────────────────────
# Speedtest mode
#
# ─────────────────────────────────────────────

if [ "$1" = "--speedtest" ]; then
  LOCK="/tmp/sketchybar-network-quality.lock"

  if ! mkdir "$LOCK" 2>/dev/null; then
    exit 0
  fi

  trap 'rm -rf "$LOCK"' EXIT

  TMP="${CACHE}.tmp.$$"

  if "$NETWORK_QUALITY" -s -c >"$TMP" 2>/dev/null &&
    [ -s "$TMP" ] &&
    "$JQ" -e . "$TMP" >/dev/null 2>&1; then
    mv "$TMP" "$CACHE"

    NAME=stats "$0"
  else
    rm -f "$TMP"
  fi

  exit 0
fi

# ─────────────────────────────────────────────
# CPU
# ─────────────────────────────────────────────

IDLE="$(
  /usr/bin/top -l 1 -n 0 |
    /usr/bin/awk '/CPU usage/ {
      gsub("%", "", $7)
      print $7
    }'
)"

CPU="$(
  /usr/bin/awk -v idle="$IDLE" \
    'BEGIN { printf "%.0f", 100 - idle }'
)"

# ─────────────────────────────────────────────
# RAM
# ─────────────────────────────────────────────

FREE="$(
  /usr/bin/memory_pressure |
    /usr/bin/awk '/System-wide memory free percentage:/ {
      gsub("%", "", $5)
      print $5
    }'
)"

RAM=$((100 - FREE))

# ─────────────────────────────────────────────
# Network
# ─────────────────────────────────────────────

DOWN="--"
UP="--"
COLOR="$MUTED"

if [ -f "$CACHE" ]; then
  DOWN="$(
    "$JQ" -r \
      '.dl_throughput / 1000000 | round' \
      "$CACHE"
  )"

  UP="$(
    "$JQ" -r \
      '.ul_throughput / 1000000 | round' \
      "$CACHE"
  )"

  DL_RPM="$(
    "$JQ" -r \
      '.dl_responsiveness // 0' \
      "$CACHE"
  )"

  UL_RPM="$(
    "$JQ" -r \
      '.ul_responsiveness // 0' \
      "$CACHE"
  )"

  # Worst responsiveness determines connection health.
  RPM="$(
    /usr/bin/awk \
      -v dl="$DL_RPM" \
      -v ul="$UL_RPM" \
      'BEGIN {
        print (dl < ul ? dl : ul)
      }'
  )"

  if /usr/bin/awk -v rpm="$RPM" \
    'BEGIN { exit !(rpm >= 400) }'; then
    COLOR="$GREEN"

  elif /usr/bin/awk -v rpm="$RPM" \
    'BEGIN { exit !(rpm >= 100) }'; then
    COLOR="$ORANGE"

  else
    COLOR="$PINK"
  fi
fi

# ─────────────────────────────────────────────
# SketchyBar
# ─────────────────────────────────────────────

"$SKETCHYBAR" --set "${NAME:-stats}" \
  icon.color="$COLOR" \
  label="C $CPU  R $RAM  ${DOWN}↓ ${UP}↑"
