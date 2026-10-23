# Potyagus in Telegram: the goose that writes first

Potyagus (English name: Goose Up) is a cheeky cartoon goose that helps Ukrainians who sit at a laptop all day to move a little and get through the day. The [desktop app](../README.md) brings a 30-second exercise to your screen every hour. This bot is the next step: a companion in Telegram, the messenger most Ukrainians already use, that **writes first**, remembers what you promised and checks in gently.

Status: working prototype (MVP), Ukrainian only.

## What it does

- **Warm-ups twice a day** (11:00 and 16:00 Kyiv time by default) with three buttons: *Done*, *In 15 min*, *Not today*. Exercises come from the same library as the desktop app (`../data/exercises.json`, 20 exercises, no equipment).
- **Streaks** without guilt: a missed day resets the streak quietly; milestones at 3, 7, 14 and 30 days.
- **Backs off when ignored**: after two unanswered warm-ups the goose comes once a day, with a softer message. Quiet hours 22:00–08:00.
- **Free conversation** in the goose's voice through Claude Haiku. When you say what you plan to do and when ("I'll email the accountant at 3 pm"), the model saves a promise and the goose asks about it at that time, with *Done* / *One more hour* / *Drop it* buttons.
- **Crisis safeguard** runs *before* the language model: messages about self-harm, suicide or violence get a calm reply with Ukrainian hotline numbers, and warm-ups pause for 24 hours.
- **Privacy by design**: stores only the Telegram chat id and first name, streak, promises and the last few messages. No ads, no data sales. `/delete` wipes everything.

About 80% of interactions are scripted and free. The language model is used only for free text, so the companion costs roughly **$0.20 per active user per month**. Without an API key the bot still runs: warm-ups, buttons and streaks work, and free text gets a scripted reply.

## Commands

| Command | |
|---|---|
| `/start` | consent screen and the first warm-up |
| `/warmup` | a warm-up right now |
| `/stats` | streak and total warm-ups |
| `/promises` | open promises |
| `/pause`, `/resume` | stay quiet for 3 hours / come back |
| `/delete` | delete all your data |
| `/help` | commands and hotlines |

## Run it

1. Create a bot with [@BotFather](https://t.me/BotFather) and copy its token.
2. Optional: get an Anthropic API key for free-text replies.
3. Install and run (Python 3.11+):

```bash
cd bot
python3 -m venv .venv
.venv/bin/pip install -e ".[dev]"
BOT_TOKEN=123:abc ANTHROPIC_API_KEY=sk-... .venv/bin/python -m goose_bot
```

Settings (environment variables): `GOOSE_TZ` (default `Europe/Kyiv`), `GOOSE_WARMUPS` (default `11:00,16:00`), `GOOSE_MODEL` (default `claude-haiku-5-5`), `GOOSE_DB` (default `bot/goose.db`).

Tests: `.venv/bin/python -m pytest` (offline, no Telegram or API calls).

## How it is built

```
goose_bot/
  logic.py    what the goose says, when, and with which buttons (no Telegram, fully tested)
  brain.py    Claude Haiku for free text, with one tool: save_promise
  safety.py   crisis detection and hotline reply, runs before the model
  store.py    SQLite: users, sent warm-up slots, promises, recent messages
  content.py  exercises (shared with the desktop app) and goose lines
  app.py      Telegram layer (python-telegram-bot): commands, buttons, a scheduler tick every minute
```

## Before launching to real people

- Verify hotline numbers in `safety.py` and have the crisis protocol reviewed by a psychologist.

## License

The code is open source under the [MIT License](../LICENSE). The Potyagus / Goose Up character (its name, look and voice), the goose artwork, logos, animations, video and sounds are © 2026 Alina Uvarova, all rights reserved, and are not covered by the MIT License.
