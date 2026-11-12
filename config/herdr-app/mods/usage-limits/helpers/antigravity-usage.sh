#!/bin/sh
# Read subscription quotas through Magpie; no prompts or credential file access.
# Exit 127 when Magpie is not installed, matching the other usage helpers.
MAGPIE=$(command -v magpie 2>/dev/null) || exit 127
exec "$MAGPIE" quota antigravity --json
