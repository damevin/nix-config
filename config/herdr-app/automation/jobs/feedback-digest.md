---
name: Slack: feature feedback digest
kind: report
schedule: weekdays 18:00
model: sonnet
budget: 0.60
cap: 2
incremental: true
timeout: 900
followup: feedback-triage
tools: mcp__claude_ai_Slack__slack_search_channels, mcp__claude_ai_Slack__slack_read_channel, mcp__claude_ai_Slack__slack_read_thread, mcp__claude_ai_Slack__slack_search_public_and_private, mcp__claude_ai_Slack__slack_read_user_profile
---
Digest the feedback posted in these Slack channels for me (Raphaël Damevin, staff frontend engineer at Livestorm, working on the room, chat v2, room layout, surveys, replay and the dashboard):

- #temp-room-layout-v2-feedback
- #temp-polls-and-surveys-feedbacks
- #temp-dashboard-feedbacks
- #temp-live-interpretation-feedback
- #tech-customer-insights-feedback
- #support-requests-and-improvements

Find each channel's id, read the new messages and open the threads that have replies. Skip bot messages and pure chatter.

body, in Slack mrkdwn, short:
- First line: *Feedback digest <date>* and one sentence on the main signal of the day.
- One block per feature, most important first, title in *bold*, then bullets with "•". One bullet per topic, not per message: merge people saying the same thing and say how many. Mark each bullet as bug, friction, request or praise. Quote a customer in _italics_ only when the exact words matter, at most one quote per feature. End each bullet with the thread link as a plain URL, never in <url|text> form (it does not render when pasted).
- Say when a topic was already raised before ("again").
- Skip features with nothing new. Under 25 lines total.
- If nothing worth my time was posted, body is an empty string.

title: "Feedback digest <date>".

findings: only problems that need action now, at most two, usually none: a bug reported by several people, a customer blocked, or a regression on my areas. key: the channel id and thread ts. url: the thread link. Severity high only when customers are impacted right now.
