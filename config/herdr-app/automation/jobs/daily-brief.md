---
name: Daily brief
kind: report
schedule: weekdays 10:00
model: sonnet
budget: 0.40
timeout: 600
output: ~/Documents/observatory/12. journal/briefs
context: sh jobs/daily-brief.sh
tools: mcp__claude_ai_Linear__list_issues, mcp__claude_ai_Linear__get_issue, mcp__claude_ai_Google_Calendar__list_events, mcp__claude_ai_Google_Calendar__get_event
---
Write my brief to plan today's work. I am Raphaël Damevin, staff frontend engineer at Livestorm, working mostly on the entropy repository.

Besides the data below, call Google Calendar list_events once for today (primary calendar, from 00:00 to 23:59 local time, ordered by start time), and Linear list_issues once for issues assigned to me ("me") that are started or in Todo, with their priority and due date.

Write it in Markdown (it lives in my Obsidian vault), short, in English:

# Brief <weekday> <date>

**Day shape** — meetings in one line with times ("12:00 postmortem INC-146, 14:30 Survey exports with Grace"), then my free focus blocks of an hour or more. Skip events I declined. Flag invitations I have not answered yet.

**Start with** — the three things to do first today and why, one line each. Fit them into the focus blocks. Prioritize: anything blocking someone else (a review someone waits on for days, a ping, a failing PR of mine close to merge), then due or urgent tickets, then my own work.

## Reviews waiting on me
The ones worth doing today, oldest and least draft first, with how long they have waited. Skip drafts and anything clearly stale (months old, no activity) but count them in one line ("plus 6 stale or draft requests").

## My PRs
Only the ones that need an action from me: failing checks, conflicts, approved and ready to merge, no reviewer after two days. One line each with the action. Then one line for the rest ("8 others waiting on review").

## Pings and inbox
What the Slack pings and my Automation inbox say I owe people. Skip the section if empty.

## Tickets
Started or due tickets, and the next one to pick up if I finish early. Skip done or blocked-by-others ones.

Rules: links as plain Markdown links with short labels like [#17954](url) or [LIV-18605](url). No filler, no motivation lines, no emoji. Under 30 lines. If there is truly nothing, write a two-line brief that says so.

title: "Brief <weekday> <date>".
