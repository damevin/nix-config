---
name: Weekly recap (entropy)
kind: report
schedule: Fridays 17:00
model: sonnet
budget: 0.60
timeout: 900
context: sh jobs/weekly-recap.sh
tools: mcp__claude_ai_Linear__list_issues, mcp__claude_ai_Linear__list_projects
---
Write my end-of-week recap for my team's Slack channel, from my GitHub activity on the entropy repository in the data below.

To group the work, call Linear list_issues once with assignee "me" and updatedAt since Monday, and use each ticket's project (the liv-NNNNN in PR titles is the ticket id). Do not call get_issue per ticket.

Format, Slack mrkdwn, ready to paste:
- First line: *Recap S<week number>* and one sentence on the week's main thrust.
- Then one block per theme (a Linear project or an obvious topic like "Chat v2 GA cleanup", "Surveys", "Tooling"), ordered by impact. Block title in *bold*, then bullets with "•".
- One bullet per outcome, not per PR: merge PRs that did the same thing (a fix and its backports, a series of flag removals) into one line, and say what changed for users or for the team, in plain words. Put the PR links at the end of the bullet as plain URLs, at most three per bullet.
- A short *In review / next* block with what is still open and matters.
- A last line *Reviews:* with how many PRs of others I reviewed and for whom.
- No headers with #, no tables, no emoji, no filler, no "I'm excited". Keep it under 25 lines. Write in English, first person.

title: "Weekly recap S<week number>".
