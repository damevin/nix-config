---
name: Slack: pings waiting on me
schedule: weekdays 9h-19h, every 30 min
model: haiku
budget: 0.20
cap: 3
incremental: true
tools: mcp__claude_ai_Slack__slack_search_public_and_private, mcp__claude_ai_Slack__slack_read_thread, mcp__claude_ai_Slack__slack_read_channel, mcp__claude_ai_Slack__slack_list_user_channels, mcp__claude_ai_Slack__slack_read_user_profile, mcp__claude_ai_Slack__slack_search_users
---
Find the Slack messages that are waiting on me (Raphaël Damevin, staff frontend engineer at Livestorm).

How:
1. Get my Slack user id (my own profile).
2. Search messages that mention me (<@my id>), and list my DMs and group DMs with recent activity and read the new messages there.
3. For each candidate, read its thread before deciding.

Report a message only if I still need to act:
- someone asks me a question, asks for a review, a decision or help, and I have not replied after it in the thread or DM;
- severity high: someone is blocked, production or a customer is impacted, or it is explicitly urgent;
- severity medium: a direct question or request to me;
- severity low: an FYI where my opinion would clearly be useful but is not asked.

Never report:
- anything I already answered or reacted to after the request, or that someone else resolved;
- bots, automated notifications, CI, Linear or GitHub bot messages;
- thanks, congratulations, "fyi" without a question, broad @here/@channel announcements;
- my own messages.

One finding per thread, never per message. key: the channel id and the thread ts (channel:ts). url: the message permalink. title: who wants what, in under 12 words, e.g. "Léa asks for a review of the survey export PR". summary: the ask in one sentence, then where it stands.
