"""Налаштування з оточення. Секрети тільки з env, у репозиторії їх немає."""
import os
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def _times(raw: str) -> tuple[str, ...]:
    return tuple(t.strip() for t in raw.split(",") if t.strip())


@dataclass(frozen=True)
class Config:
    bot_token: str = field(default_factory=lambda: os.environ.get("BOT_TOKEN", ""))
    # Без ключа гусь працює за сценарієм: розминки, кнопки, серії. LLM лише для вільного тексту.
    anthropic_key: str = field(default_factory=lambda: os.environ.get("ANTHROPIC_API_KEY", ""))
    model: str = field(default_factory=lambda: os.environ.get("GOOSE_MODEL", "claude-haiku-5-5"))
    db_path: Path = field(default_factory=lambda: Path(os.environ.get("GOOSE_DB", ROOT / "bot" / "goose.db")))
    exercises_path: Path = ROOT / "data" / "exercises.json"
    timezone: str = field(default_factory=lambda: os.environ.get("GOOSE_TZ", "Europe/Kyiv"))
    warmup_times: tuple[str, ...] = field(default_factory=lambda: _times(os.environ.get("GOOSE_WARMUPS", "11:00,16:00")))
    quiet_start: int = 22  # з 22:00 до 08:00 гусь мовчить
    quiet_end: int = 8
    snooze_minutes: int = 15
    history_turns: int = 12  # скільки останніх реплік гусь пам'ятає в розмові
