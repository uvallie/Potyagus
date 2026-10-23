"""Поведінка гуся без Telegram: що сказати, коли і з якими кнопками.

Telegram-шар (app.py) лише доставляє Out і передає натискання кнопок сюди. Тому все тут тестується офлайн.
"""
import random
from dataclasses import dataclass, field
from datetime import datetime, timedelta, time
from zoneinfo import ZoneInfo

from . import safety
from .brain import Brain
from .config import Config
from .content import GENTLE_LINES, SNOOZE_LINES, STREAK_LINES, Content, format_exercise
from .store import Store, User

SLOT_WINDOW = timedelta(minutes=30)  # якщо бот лежав, розминка ще може прийти пізніше, але не ввечері


@dataclass
class Out:
    chat_id: int
    text: str
    buttons: list[list[tuple[str, str]]] = field(default_factory=list)  # рядки кнопок: (підпис, callback_data)
    html: bool = False  # лише для вправ; текст людини й LLM ідуть як є, без розмітки


def warmup_buttons() -> list[list[tuple[str, str]]]:
    return [[("Зроблено 💪", "done")], [("Через 15 хв", "snooze"), ("Сьогодні ніяк", "skip")]]


class Goose:
    def __init__(self, cfg: Config, store: Store, content: Content, brain: Brain, rng: random.Random | None = None):
        self.cfg, self.store, self.content, self.brain = cfg, store, content, brain
        self.rng = rng or random.Random()

    def local(self, user: User, now: datetime) -> datetime:
        return now.astimezone(ZoneInfo(user.tz))

    # --- старт і згода ---
    def start(self, chat_id: int, name: str, now: datetime) -> list[Out]:
        user = self.store.upsert_user(chat_id, name, self.cfg.timezone, now)
        if user.consent:
            return [Out(chat_id, "Я вже тут. Розминка прийде за розкладом, а якщо не терпиться — /warmup.")]
        times = " і ".join(self.cfg.warmup_times)
        return [Out(
            chat_id,
            "Га-га. Я Потягусь.\n\n"
            f"Двічі на день ({times} за Києвом) я приходитиму з розминкою на 30–40 секунд. "
            "Можна просто написати мені, як справи, або що збираєшся зробити, — я перепитаю.\n\n"
            "Що я зберігаю: твоє ім'я в Telegram, серію розминок, домовленості й останні повідомлення. "
            "Більше нічого, без реклами. Стерти все: /delete.\n\n"
            "Я не лікар і не психолог. Якщо зовсім кепсько, у /help є номери, де допоможуть живі люди.",
            [[("Погнали 🪿", "consent")]],
        )]

    def consent(self, chat_id: int, now: datetime) -> list[Out]:
        if not self.store.get_user(chat_id):
            return self.start(chat_id, "", now)
        self.store.update_user(chat_id, consent=1)
        return [Out(chat_id, "Домовились. Почнемо з малого, просто зараз:")] + self.warmup(chat_id, now)

    # --- розминка ---
    def warmup(self, chat_id: int, now: datetime, intro: str = "") -> list[Out]:
        user = self.store.get_user(chat_id)
        if not user:
            return []
        ex = self.content.pick(self.rng, avoid=user.last_exercise)
        self.store.update_user(chat_id, last_exercise=ex.id, pending=1, snooze_until=None)
        return [Out(chat_id, format_exercise(ex, intro), warmup_buttons(), html=True)]

    def on_done(self, chat_id: int, now: datetime) -> list[Out]:
        user = self.store.get_user(chat_id)
        if not user:
            return []
        today = self.local(user, now).date()
        if user.last_done == today:
            streak = user.streak
        elif user.last_done == today - timedelta(days=1):
            streak = user.streak + 1
        else:
            streak = 1
        self.store.update_user(
            chat_id, streak=streak, best_streak=max(streak, user.best_streak), last_done=today,
            total_done=user.total_done + 1, ignored=0, pending=0, snooze_until=None,
        )
        line = self.rng.choice(self.content.done_lines) if self.content.done_lines else "Готово."
        if streak != user.streak and streak in STREAK_LINES:
            line += "\n\n" + STREAK_LINES[streak]
        return [Out(chat_id, f"{line}\n\nСерія: {streak} {_days(streak)}.")]

    def on_snooze(self, chat_id: int, now: datetime) -> list[Out]:
        if not self.store.get_user(chat_id):
            return []
        self.store.update_user(chat_id, snooze_until=now + timedelta(minutes=self.cfg.snooze_minutes), pending=0)
        return [Out(chat_id, self.rng.choice(SNOOZE_LINES))]

    def on_skip(self, chat_id: int, now: datetime) -> list[Out]:
        user = self.store.get_user(chat_id)
        if not user:
            return []
        # Відмова — це теж відповідь, вона не рахується як ігнор. Гусь просто м'якшає.
        self.store.update_user(chat_id, pending=0, snooze_until=None)
        return [Out(chat_id, self.rng.choice(GENTLE_LINES))]

    # --- розклад: викликається щохвилини ---
    def tick(self, now: datetime) -> list[Out]:
        out: list[Out] = []
        for user in self.store.active_users():
            out += self._tick_user(user, now)
        for p in self.store.due_promises(now):
            user = self.store.get_user(p.chat_id)
            if not user or not user.consent or self._quiet(user, now):
                continue
            self.store.set_promise(p.id, "asked")
            out.append(Out(p.chat_id, f"Була домовленість: «{p.text}». Як там?", [
                [("Зроблено ✅", f"pdone:{p.id}")],
                [("Ще годинку", f"plater:{p.id}"), ("Знімаю", f"pdrop:{p.id}")],
            ]))
        return out

    def _quiet(self, user: User, now: datetime) -> bool:
        h = self.local(user, now).hour
        return h >= self.cfg.quiet_start or h < self.cfg.quiet_end

    def _tick_user(self, user: User, now: datetime) -> list[Out]:
        if user.paused_until and now < user.paused_until:
            return []
        if self._quiet(user, now):
            return []
        if user.snooze_until and now >= user.snooze_until:
            return self.warmup(user.chat_id, now, "Обіцяв повернутись — повертаюсь.")
        local = self.local(user, now)
        for i, slot in enumerate(self.cfg.warmup_times):
            hh, mm = map(int, slot.split(":"))
            start = datetime.combine(local.date(), time(hh, mm), tzinfo=local.tzinfo)
            if not (start <= local < start + SLOT_WINDOW) or self.store.slot_sent(user.chat_id, local.date(), slot):
                continue
            self.store.mark_slot(user.chat_id, local.date(), slot)
            ignored = user.ignored + (1 if user.pending else 0)
            self.store.update_user(user.chat_id, ignored=ignored)
            # Два проігноровані поспіль — гусь приходить лише раз на день і без підколок.
            if ignored >= 2 and i > 0:
                return []
            intro = "Привіт. Без тиску: одна маленька вправа, якщо є хвилинка." if ignored >= 2 else (
                self.rng.choice(self.content.taunts) if self.content.taunts else "")
            return self.warmup(user.chat_id, now, intro)
        return []

    # --- домовленості з кнопок ---
    def on_promise(self, chat_id: int, action: str, pid: int, now: datetime) -> list[Out]:
        p = self.store.get_promise(pid)
        if not p or p.chat_id != chat_id:
            return []
        if action == "pdone":
            self.store.set_promise(pid, "done")
            return [Out(chat_id, f"«{p.text}» — є. Га-га, оце я розумію.")]
        if action == "plater":
            self.store.set_promise(pid, "open", now + timedelta(hours=1))
            return [Out(chat_id, "Добре, перепитаю через годину.")]
        self.store.set_promise(pid, "dropped")
        return [Out(chat_id, "Знято. Не все треба робити сьогодні.")]

    # --- вільний текст ---
    async def on_text(self, chat_id: int, text: str, now: datetime) -> list[Out]:
        user = self.store.get_user(chat_id)
        if not user or not user.consent:
            return self.start(chat_id, "", now)
        if safety.is_crisis(text):
            # Запобіжник іде до LLM. Розминки на добу на паузу, щоб гусь не прийшов із «встань» за годину.
            self.store.update_user(chat_id, paused_until=now + timedelta(hours=24), pending=0, snooze_until=None)
            reply = safety.crisis_reply()
            self.store.add_message(chat_id, "user", text, now)
            self.store.add_message(chat_id, "assistant", reply, now)
            return [Out(chat_id, reply)]
        local = self.local(user, now)
        history = self.store.history(chat_id, self.cfg.history_turns)
        open_p = [f"{p.text} (о {p.due_at.astimezone(local.tzinfo):%d.%m %H:%M})" for p in self.store.open_promises(chat_id)]
        r = await self.brain.reply(text, history, local, open_p, user.streak)
        for what, due in r.promises:
            self.store.add_promise(chat_id, what, due, now)
        self.store.add_message(chat_id, "user", text, now)
        self.store.add_message(chat_id, "assistant", r.text, now)
        return [Out(chat_id, r.text)]

    # --- службові команди ---
    def stats(self, chat_id: int) -> list[Out]:
        u = self.store.get_user(chat_id)
        if not u:
            return []
        return [Out(chat_id, f"Розминок усього: {u.total_done}\nСерія зараз: {u.streak} {_days(u.streak)}\n"
                             f"Найдовша серія: {u.best_streak} {_days(u.best_streak)}")]

    def promises(self, chat_id: int, now: datetime) -> list[Out]:
        u = self.store.get_user(chat_id)
        ps = self.store.open_promises(chat_id) if u else []
        if not ps:
            return [Out(chat_id, "Відкритих домовленостей немає. Напиши, що збираєшся зробити і коли, — я перепитаю.")]
        lines = [f"• {p.text} — {p.due_at.astimezone(ZoneInfo(u.tz)):%d.%m о %H:%M}" for p in ps]
        return [Out(chat_id, "Що ми домовились:\n" + "\n".join(lines))]

    def pause(self, chat_id: int, hours: int, now: datetime) -> list[Out]:
        if not self.store.get_user(chat_id):
            return []
        self.store.update_user(chat_id, paused_until=now + timedelta(hours=hours), pending=0, snooze_until=None)
        return [Out(chat_id, f"Мовчу {hours} год. Повернути раніше: /resume.")]

    def resume(self, chat_id: int) -> list[Out]:
        if not self.store.get_user(chat_id):
            return []
        self.store.update_user(chat_id, paused_until=None)
        return [Out(chat_id, "Я повернувся. Наступна розминка за розкладом, або /warmup просто зараз.")]

    def delete(self, chat_id: int) -> list[Out]:
        self.store.delete_user(chat_id)
        return [Out(chat_id, "Все стерто: серія, домовленості, розмова. Якщо захочеш повернутись — /start.")]

    def help(self, chat_id: int) -> list[Out]:
        return [Out(chat_id,
                    "/warmup — розминка просто зараз\n/stats — моя серія\n/promises — наші домовленості\n"
                    "/pause — помовчати 3 години\n/resume — повернутися раніше\n/delete — стерти всі мої дані\n\n"
                    "Якщо дуже важко, поговори з живою людиною:\n" + "\n".join(safety.HOTLINES))]


def _days(n: int) -> str:
    if n % 10 == 1 and n % 100 != 11:
        return "день"
    if 2 <= n % 10 <= 4 and not 12 <= n % 100 <= 14:
        return "дні"
    return "днів"
