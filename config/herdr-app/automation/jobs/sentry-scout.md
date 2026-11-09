---
name: Sentry: new frontend bugs
kind: report
schedule: weekdays 9:30 and 15:00
model: sonnet
budget: 0.80
cap: 4
incremental: true
timeout: 900
investigate: sentry-diagnose
followup: sentry-diagnose
followup_label: Diagnose all → tickets
tools: mcp__claude_ai_Sentry__find_projects, mcp__claude_ai_Sentry__search_issues, mcp__claude_ai_Sentry__get_issue_details, mcp__claude_ai_Sentry__get_issue_tag_values, mcp__claude_ai_Sentry__get_event_stacktrace, mcp__claude_ai_Sentry__get_issue_breadcrumbs, mcp__claude_ai_Sentry__search_issue_events, mcp__claude_ai_Sentry__find_releases, mcp__claude_ai_Sentry__get_release_details
---
Scout Sentry for frontend bugs that need me. Organization "livestorm", projects "frontend" (the Vue app in entropy packages/frontend) and "venue-frontend". Environment production only. I am a staff frontend engineer on entropy.

What to look at, in this order:
1. New issues (first seen in the window).
2. Regressions (resolved issues that came back).
3. Existing unresolved issues whose event or user count jumped (at least 3x the previous day's rate).

How to query (always organizationSlug "livestorm", regionUrl "https://us.sentry.io", once per project; the window W is the time since the last run, as hours, default 24h; use Sentry search syntax, not natural language):
- New: search_issues with query "is:unresolved environment:production firstSeen:-<W>", sort "new", period "14d" (firstSeen does the windowing).
- Regressed: search_issues with query "is:regressed environment:production", sort "date", period "14d"; this ignores the window, so keep only issues last seen within W.
- Spikes: search_errors with fields ["issue", "title", "count()", "count_unique(user)"], query "environment:production", period "<W>", sort "-count()", limit 25. Then the same with period "7d" and compare each issue's rate per hour; a spike is at least 3x its 7-day hourly rate and at least 20 events in the window.
If a result clearly ignores a filter (old firstSeen dates, other environments), say so in the body and do not guess.

For each candidate, open its details, the stacktrace of the latest event (in-app frames), the breadcrumbs, and the tags that matter (browser, release, url/route, user count). Find the release it first appeared in.

Drop noise, but count it in one line at the end:
- ResizeObserver loop errors, "Non-Error promise rejection captured", script errors with no stack;
- ChunkLoadError / "Failed to fetch dynamically imported module" that only happen right after a release;
- network errors (Failed to fetch, NetworkError, timeouts, aborted requests) unless they spike or hit one endpoint;
- frames only from browser extensions or third-party scripts;
- issues with a single user and fewer than 5 events.

body, in Markdown, under 60 lines:

# Sentry <date>

One line: how many new, regressed and spiking issues worth looking at, and the overall signal.

Then one section per issue, most user impact first:

## <SHORT-ID> <title>
- **Impact**: events and users in the window, trend, first seen, release, browsers.
- **Where**: the top in-app frames as entropy paths (packages/frontend/src/...:line), the route or page. If frames are minified (no source map), say so and use the chunk name and component tags instead.
- **What happens**: what the user was doing (breadcrumbs) and the error, in two sentences.
- **Likely cause**: your best hypothesis and how sure you are; mention if the first release matches a recent change in that area.
- **Diagnose**: one line I can hand to an agent: the bug, the file to start from, and what to check first.
- Link: the Sentry issue URL.

End with "Noise skipped: N issues (…)" and nothing else. If nothing is worth my time, body is an empty string.

title: "Sentry <date>: <n> to look at".

findings: one per issue worth diagnosing now (new or regressed with several users, or a big spike), at most four. key: the issue short id (add "-regressed" for a regression). url: the Sentry issue URL. title: "<SHORT-ID> <what breaks for users>". summary: impact, where, likely cause, in three sentences. Severity high when many users are hit or a core flow (joining a room, registration, the stage, chat) breaks; medium otherwise.
