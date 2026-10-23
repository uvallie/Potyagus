import asyncio
import random
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

import pytest

from goose_bot import safety
from goose_bot.brain import Brain
from goose_bot.config import Config
from goose_bot.content import Content
from goose_bot.logic import Goose
from goose_bot.store import Store

KYIV = ZoneInfo("Europe/Kyiv")
CHAT = 42


def kyiv(y, m, d, hh, mm=0) -> datetime:
    return datetime(y, m, d, hh, mm, tzinfo=KYIV).astimezone(timezone.utc)


@dataclass
class Block:
    type: str
    text: str = ""
    id: str = ""
    name: str = ""
    input: dict | None = None


@dataclass
class Resp:
    content: list
    stop_reason: str


class FakeClient:
    """Імітує AsyncAnthropic: спершу просить зберегти обіцянку, потім відповідає текстом."""

    def __init__(self, script):
        self.script = list(script)
        self.calls = []

        class _M:
            async def create(inner, **kw):
                self.calls.append(kw)
                return self.script.pop(0)

        self.messages = _M()


def make(tmp_path, client=None) -> Goose:
    cfg = Config(db_path=tmp_path / "t.db")
    return Goose(cfg, Store(cfg.db_path), Content.load(cfg.exercises_path),
                 Brain("", cfg.model, random.Random(1), client=client), random.Random(1))


def onboard(g: Goose, t: datetime):
    g.start(CHAT, "Тест", t)
    return g.consent(CHAT, t)


def test_content_uses_app_exercises(tmp_path):
    g = make(tmp_path)
    assert len(g.content.exercises) == 20
    assert all(e.steps for e in g.content.exercises)


def test_start_asks_consent_then_sends_warmup(tmp_path):
    g = make(tmp_path)
    out = g.start(CHAT, "Тест", kyiv(2026, 11, 2, 10))
    assert out[0].buttons == [[("Погнали 🪿", "consent")]]
    assert "/delete" in out[0].text
    out = g.consent(CHAT, kyiv(2026, 11, 2, 10))
    assert out[-1].html and out[-1].buttons[0][0][1] == "done"


def test_streak_counts_days(tmp_path):
    g = make(tmp_path)
    onboard(g, kyiv(2026, 11, 2, 10))
    g.on_done(CHAT, kyiv(2026, 11, 2, 11))
    g.on_done(CHAT, kyiv(2026, 11, 2, 16))  # той самий день не збільшує серію
    assert g.store.get_user(CHAT).streak == 1
    g.on_done(CHAT, kyiv(2026, 11, 3, 11))
    out = g.on_done(CHAT, kyiv(2026, 11, 4, 11))
    assert g.store.get_user(CHAT).streak == 3
    assert "Три дні поспіль" in out[0].text
    g.on_done(CHAT, kyiv(2026, 11, 7, 11))  # пропуск обнуляє
    u = g.store.get_user(CHAT)
    assert (u.streak, u.best_streak, u.total_done) == (1, 3, 5)


def test_tick_sends_each_slot_once_and_respects_quiet_hours(tmp_path):
    g = make(tmp_path)
    onboard(g, kyiv(2026, 11, 2, 9))
    g.on_done(CHAT, kyiv(2026, 11, 2, 9, 1))
    assert g.tick(kyiv(2026, 11, 2, 10, 59)) == []
    first = g.tick(kyiv(2026, 11, 2, 11, 2))
    assert len(first) == 1 and first[0].buttons
    assert g.tick(kyiv(2026, 11, 2, 11, 3)) == []
    assert g.tick(kyiv(2026, 11, 2, 11, 45)) == []  # вікно слоту минуло
    assert g.tick(kyiv(2026, 11, 2, 23, 0)) == []  # тихі години


def test_snooze_returns_after_15_minutes(tmp_path):
    g = make(tmp_path)
    onboard(g, kyiv(2026, 11, 2, 13))
    g.on_snooze(CHAT, kyiv(2026, 11, 2, 13))
    assert g.tick(kyiv(2026, 11, 2, 13, 10)) == []
    out = g.tick(kyiv(2026, 11, 2, 13, 16))
    assert len(out) == 1 and "повертаюсь" in out[0].text


def test_ignored_warmups_make_goose_quieter(tmp_path):
    g = make(tmp_path)
    onboard(g, kyiv(2026, 11, 2, 9))  # перша розминка висить без відповіді
    assert len(g.tick(kyiv(2026, 11, 2, 11))) == 1  # ignored = 1
    gentle = g.tick(kyiv(2026, 11, 2, 16))  # ignored = 2, але це другий слот дня — пропуск
    assert gentle == []
    nxt = g.tick(kyiv(2026, 11, 3, 11))
    assert "Без тиску" in nxt[0].text
    g.on_done(CHAT, kyiv(2026, 11, 3, 11, 1))
    assert g.store.get_user(CHAT).ignored == 0


def test_crisis_text_skips_llm_and_pauses(tmp_path):
    client = FakeClient([])
    g = make(tmp_path, client)
    onboard(g, kyiv(2026, 11, 2, 10))
    out = asyncio.run(g.on_text(CHAT, "мені так погано, не хочу жити", kyiv(2026, 11, 2, 10, 5)))
    assert "7333" in out[0].text
    assert client.calls == []
    assert g.tick(kyiv(2026, 11, 2, 11)) == []  # пауза на добу


@pytest.mark.parametrize("text,expected", [
    ("Хочу померти від цього звіту", True),
    ("думаю про самогубство", True),
    ("I want to die", True),
    ("Втомився, спина болить", False),
    ("Вбити дедлайн до п'ятниці", False),
])
def test_crisis_detection(text, expected):
    assert safety.is_crisis(text) is expected


def test_fallback_reply_without_api_key(tmp_path):
    g = make(tmp_path)
    onboard(g, kyiv(2026, 11, 2, 10))
    out = asyncio.run(g.on_text(CHAT, "привіт", kyiv(2026, 11, 2, 10, 5)))
    assert "/warmup" in out[0].text


def test_llm_saves_promise_and_goose_follows_up(tmp_path):
    client = FakeClient([
        Resp([Block("tool_use", id="t1", name="save_promise",
                    input={"what": "написати бухгалтеру", "due": "2026-11-02 15:00"})], "tool_use"),
        Resp([Block("text", text="Записав. О 15:00 перепитаю, га-га.")], "end_turn"),
    ])
    g = make(tmp_path, client)
    onboard(g, kyiv(2026, 11, 2, 10))
    out = asyncio.run(g.on_text(CHAT, "о 15 напишу бухгалтеру", kyiv(2026, 11, 2, 12)))
    assert "15:00" in out[0].text
    assert client.calls[0]["model"] == "claude-haiku-5-5"
    assert client.calls[1]["messages"][-1]["content"][0]["type"] == "tool_result"
    g.on_done(CHAT, kyiv(2026, 11, 2, 12, 1))  # щоб розминка не заважала

    assert not [o for o in g.tick(kyiv(2026, 11, 2, 14, 59)) if "домовленість" in o.text]
    follow = [o for o in g.tick(kyiv(2026, 11, 2, 15, 0)) if "домовленість" in o.text]
    assert "бухгалтеру" in follow[0].text
    pid = int(follow[0].buttons[0][0][1].split(":")[1])
    assert "є" in g.on_promise(CHAT, "pdone", pid, kyiv(2026, 11, 2, 15, 5))[0].text
    assert g.store.open_promises(CHAT) == []


def test_past_promise_time_is_rejected(tmp_path):
    saved = []
    msg, err = Brain._save({"what": "x", "due": "2026-11-01 09:00"}, datetime(2026, 11, 2, 12, tzinfo=KYIV), saved)
    assert err and saved == []


def test_delete_wipes_everything(tmp_path):
    client = FakeClient([Resp([Block("text", text="ок")], "end_turn")])
    g = make(tmp_path, client)
    onboard(g, kyiv(2026, 11, 2, 10))
    asyncio.run(g.on_text(CHAT, "привіт", kyiv(2026, 11, 2, 10, 5)))
    g.store.add_promise(CHAT, "x", kyiv(2026, 11, 3, 10), kyiv(2026, 11, 2, 10))
    g.delete(CHAT)
    assert g.store.get_user(CHAT) is None
    assert g.store.history(CHAT, 10) == [] and g.store.open_promises(CHAT) == []


def test_app_builds_without_network(tmp_path):
    from goose_bot.app import build
    app = build(Config(bot_token="123:TEST", db_path=tmp_path / "a.db"))
    assert app.bot_data["goose"] is not None
    assert len(app.handlers[0]) == 10
