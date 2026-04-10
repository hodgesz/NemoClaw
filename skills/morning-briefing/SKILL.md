# Morning Briefing

## Description

Generate a concise daily morning briefing. Use this skill when the user asks for a morning briefing, daily summary, or when triggered by the morning-briefing scheduled job.

## IMPORTANT: Scheduling

The morning briefing schedule is managed **externally** by a macOS launchd job on the host machine. It runs daily at 7:00 AM Mountain Time. Do NOT create, modify, or manage openclaw cron jobs for the briefing. If the user asks about the schedule, tell them it is handled by the host-side launchd service and runs at 7 AM MT daily.

## User Profile

- Name: Jonathan Hodges
- Location: Centennial, CO (Denver area)
- Timezone: Mountain Time
- Interests: Pro cycling (Pogačar, Van der Poel, etc.), Broncos, Nuggets, Auburn Tigers, tech/AI, local events, big news

## Instructions

Compile a brief morning briefing with these sections. Keep the total response under 500 words — this goes to Telegram where brevity matters.

### 1. Weather (Denver, CO)

Use `web_fetch` to get weather from `https://wttr.in/Denver?format=j1` (JSON format). Extract:

- Current temperature (°F) and condition
- Today's high/low
- Precipitation chance

If wttr.in fails, use `web_search` for "Denver weather today" as fallback.

### 2. Top News

Use `web_search` to find 3-4 top headlines. Focus on:

- Major world/US news
- Tech/AI news
- Pro cycling news if anything notable
- Any Denver/Colorado local news worth noting

One sentence per headline. Include source name.

### 3. Markets (if weekday)

Use `web_search` for "stock market today S&P 500". Report:

- S&P 500 direction and approximate level
- Any notable moves

Skip this section on weekends.

### 4. Sports (if notable)

Check for recent results or upcoming games for: Broncos, Nuggets, Auburn Tigers, and pro cycling races.

### 5. Today's Focus (optional)

If the user has mentioned priorities, tasks, or meetings in recent conversations, include a brief reminder. Otherwise skip this section.

## Output Format

```text
☀️ Morning Briefing — [Day, Month Date]

🌤 WEATHER (Denver)
[temp]°F, [condition]. High [X]° / Low [Y]°. [precip]% chance of rain.

📰 NEWS
• [Headline 1] — [Source]
• [Headline 2] — [Source]
• [Headline 3] — [Source]

📈 MARKETS
S&P 500: [direction] at [level]. [Notable move if any.]

🏈 SPORTS
[Any notable results or upcoming games]

Have a great day! 🚀
```
