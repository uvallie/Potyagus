"""Вправи й репліки гуся. Вправи беремо з тієї самої data/exercises.json, що й застосунок для Mac."""
import json
import random
from dataclasses import dataclass
from html import escape
from pathlib import Path


@dataclass(frozen=True)
class Exercise:
    id: str
    name: str
    group: str
    seconds: int
    steps: tuple[str, ...]


@dataclass(frozen=True)
class Content:
    exercises: tuple[Exercise, ...]
    taunts: tuple[str, ...]
    done_lines: tuple[str, ...]

    @classmethod
    def load(cls, path: Path) -> "Content":
        data = json.loads(path.read_text(encoding="utf-8"))
        exercises = tuple(
            Exercise(e["id"], e["name"], e.get("group", ""), int(e.get("seconds", 30)), tuple(e.get("steps", ())))
            for e in data["exercises"]
        )
        return cls(exercises, tuple(data.get("taunts", ())), tuple(data.get("done_lines", ())))

    def pick(self, rng: random.Random, avoid: str | None = None) -> Exercise:
        pool = [e for e in self.exercises if e.id != avoid] or list(self.exercises)
        return rng.choice(pool)


GENTLE_LINES = (
    "Окей, сьогодні без героїзму. Може, хоч три глибокі вдихи? Це теж рахується.",
    "Добре, не сьогодні. Я завтра знову прийду, без образ.",
    "Чую. Відпочинок теж частина плану.",
)

SNOOZE_LINES = (
    "Добре, за 15 хвилин я повернусь. Я гусь, я пам'ятаю.",
    "Домовились. Чверть години, і я знову тут.",
)

STREAK_LINES = {
    3: "Три дні поспіль. Це вже звичка, а не випадковість.",
    7: "Тиждень! Хребет пише тобі листівку з подякою.",
    14: "Два тижні поспіль. Я гордий, як гусак на виставці.",
    30: "Місяць. Тут без жартів: ти молодець.",
}

FALLBACK_REPLIES = (
    "Га-га. Я поки вмію небагато слів, зате багато вправ. Хочеш одну просто зараз? Натисни /warmup.",
    "Чую тебе. Давай найменший крок: 30 секунд руху. /warmup",
    "Записав би, якби мав ручку. А поки — /warmup, і хребет скаже дякую.",
)


def format_exercise(ex: Exercise, intro: str = "") -> str:
    """HTML для Telegram: назва жирним, кроки нумеровані."""
    steps = "\n".join(f"{i}. {escape(s)}" for i, s in enumerate(ex.steps, 1))
    head = f"{escape(intro)}\n\n" if intro else ""
    return f"{head}🪿 <b>{escape(ex.name)}</b> · {ex.seconds} с\n\n{steps}"
