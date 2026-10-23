"""SQLite: мінімум даних. Telegram chat id, ім'я, серія, обіцянки, останні репліки. /delete стирає все."""
import sqlite3
from dataclasses import dataclass
from datetime import date, datetime, timezone
from pathlib import Path

SCHEMA = """
CREATE TABLE IF NOT EXISTS users (
    chat_id INTEGER PRIMARY KEY,
    name TEXT NOT NULL DEFAULT '',
    tz TEXT NOT NULL,
    consent INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    paused_until TEXT,
    snooze_until TEXT,
    streak INTEGER NOT NULL DEFAULT 0,
    best_streak INTEGER NOT NULL DEFAULT 0,
    last_done TEXT,
    total_done INTEGER NOT NULL DEFAULT 0,
    ignored INTEGER NOT NULL DEFAULT 0,
    pending INTEGER NOT NULL DEFAULT 0,
    last_exercise TEXT
);
CREATE TABLE IF NOT EXISTS sent_slots (
    chat_id INTEGER NOT NULL,
    day TEXT NOT NULL,
    slot TEXT NOT NULL,
    PRIMARY KEY (chat_id, day, slot)
);
CREATE TABLE IF NOT EXISTS promises (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    chat_id INTEGER NOT NULL,
    text TEXT NOT NULL,
    due_at TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'open',
    created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    chat_id INTEGER NOT NULL,
    role TEXT NOT NULL,
    text TEXT NOT NULL,
    at TEXT NOT NULL
);
"""


@dataclass
class User:
    chat_id: int
    name: str
    tz: str
    consent: bool
    paused_until: datetime | None
    snooze_until: datetime | None
    streak: int
    best_streak: int
    last_done: date | None
    total_done: int
    ignored: int
    pending: bool
    last_exercise: str | None


@dataclass
class Promise:
    id: int
    chat_id: int
    text: str
    due_at: datetime
    status: str


def _dt(v):
    return datetime.fromisoformat(v) if v else None


def _iso(v):
    """Усі моменти часу в базі в UTC: рядки порівнюються в SQL, тож зсув має бути однаковий."""
    if isinstance(v, datetime):
        return (v.astimezone(timezone.utc) if v.tzinfo else v).isoformat()
    if isinstance(v, date):
        return v.isoformat()
    return v


class Store:
    def __init__(self, path: Path | str):
        self.db = sqlite3.connect(str(path))
        self.db.row_factory = sqlite3.Row
        self.db.executescript(SCHEMA)

    # --- users ---
    def upsert_user(self, chat_id: int, name: str, tz: str, now: datetime) -> User:
        self.db.execute(
            "INSERT INTO users (chat_id, name, tz, created_at) VALUES (?, ?, ?, ?) "
            "ON CONFLICT(chat_id) DO UPDATE SET name = excluded.name",
            (chat_id, name, tz, _iso(now)),
        )
        self.db.commit()
        return self.get_user(chat_id)

    def get_user(self, chat_id: int) -> User | None:
        r = self.db.execute("SELECT * FROM users WHERE chat_id = ?", (chat_id,)).fetchone()
        if not r:
            return None
        return User(
            r["chat_id"], r["name"], r["tz"], bool(r["consent"]), _dt(r["paused_until"]), _dt(r["snooze_until"]),
            r["streak"], r["best_streak"], date.fromisoformat(r["last_done"]) if r["last_done"] else None,
            r["total_done"], r["ignored"], bool(r["pending"]), r["last_exercise"],
        )

    def active_users(self) -> list[User]:
        rows = self.db.execute("SELECT chat_id FROM users WHERE consent = 1").fetchall()
        return [self.get_user(r["chat_id"]) for r in rows]

    def update_user(self, chat_id: int, **fields) -> None:
        cols = ", ".join(f"{k} = ?" for k in fields)
        vals = [_iso(v) for v in fields.values()]
        self.db.execute(f"UPDATE users SET {cols} WHERE chat_id = ?", (*vals, chat_id))
        self.db.commit()

    def delete_user(self, chat_id: int) -> None:
        for table in ("users", "sent_slots", "promises", "messages"):
            self.db.execute(f"DELETE FROM {table} WHERE chat_id = ?", (chat_id,))
        self.db.commit()

    # --- warm-up slots: щоб не надіслати ту саму розминку двічі ---
    def slot_sent(self, chat_id: int, day: date, slot: str) -> bool:
        return self.db.execute(
            "SELECT 1 FROM sent_slots WHERE chat_id = ? AND day = ? AND slot = ?", (chat_id, day.isoformat(), slot)
        ).fetchone() is not None

    def mark_slot(self, chat_id: int, day: date, slot: str) -> None:
        self.db.execute("INSERT OR IGNORE INTO sent_slots VALUES (?, ?, ?)", (chat_id, day.isoformat(), slot))
        self.db.commit()

    # --- promises ---
    def add_promise(self, chat_id: int, text: str, due_at: datetime, now: datetime) -> int:
        cur = self.db.execute(
            "INSERT INTO promises (chat_id, text, due_at, created_at) VALUES (?, ?, ?, ?)",
            (chat_id, text, _iso(due_at), _iso(now)),
        )
        self.db.commit()
        return cur.lastrowid

    def open_promises(self, chat_id: int) -> list[Promise]:
        rows = self.db.execute(
            "SELECT * FROM promises WHERE chat_id = ? AND status IN ('open', 'asked') ORDER BY due_at", (chat_id,)
        ).fetchall()
        return [Promise(r["id"], r["chat_id"], r["text"], _dt(r["due_at"]), r["status"]) for r in rows]

    def due_promises(self, now: datetime) -> list[Promise]:
        rows = self.db.execute(
            "SELECT * FROM promises WHERE status = 'open' AND due_at <= ? ORDER BY due_at", (_iso(now),)
        ).fetchall()
        return [Promise(r["id"], r["chat_id"], r["text"], _dt(r["due_at"]), r["status"]) for r in rows]

    def get_promise(self, pid: int) -> Promise | None:
        r = self.db.execute("SELECT * FROM promises WHERE id = ?", (pid,)).fetchone()
        return Promise(r["id"], r["chat_id"], r["text"], _dt(r["due_at"]), r["status"]) if r else None

    def set_promise(self, pid: int, status: str, due_at: datetime | None = None) -> None:
        if due_at:
            self.db.execute("UPDATE promises SET status = ?, due_at = ? WHERE id = ?", (status, _iso(due_at), pid))
        else:
            self.db.execute("UPDATE promises SET status = ? WHERE id = ?", (status, pid))
        self.db.commit()

    # --- conversation memory ---
    def add_message(self, chat_id: int, role: str, text: str, now: datetime) -> None:
        self.db.execute(
            "INSERT INTO messages (chat_id, role, text, at) VALUES (?, ?, ?, ?)", (chat_id, role, text, _iso(now))
        )
        self.db.commit()

    def history(self, chat_id: int, limit: int) -> list[tuple[str, str]]:
        rows = self.db.execute(
            "SELECT role, text FROM messages WHERE chat_id = ? ORDER BY id DESC LIMIT ?", (chat_id, limit)
        ).fetchall()
        return [(r["role"], r["text"]) for r in reversed(rows)]
