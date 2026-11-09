---
name: Linear: my stalled tickets
schedule: weekdays 09:30
model: haiku
budget: 0.30
cap: 5
tools: mcp__claude_ai_Linear__list_issues, mcp__claude_ai_Linear__get_issue, mcp__claude_ai_Linear__list_comments
---
List the Linear issues assigned to me ("me") that are in a started state (In Progress, In Review or similar).

Report an issue when one of these is true:
- no update for 5 days or more (severity medium, high if it has a due date in the past);
- someone else commented in the last 2 days and I have not answered (severity medium);
- it is blocked by another issue that is now done (severity low).

Use the issue identifier as key and its Linear URL as url.
