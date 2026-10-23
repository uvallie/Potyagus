"""Мозок гуся: Claude Haiku для вільного тексту. Викликається лише тоді, коли людина пише своїми словами.

Без ANTHROPIC_API_KEY гусь відповідає сценарієм (content.FALLBACK_REPLIES), і бот працює далі.
"""
import json
import logging
import random
from dataclasses import dataclass, field
from datetime import datetime

from .content import FALLBACK_REPLIES

log = logging.getLogger(__name__)

SYSTEM = """Ти — Потягусь, нахабний, але добрий мультяшний гусь з українського застосунку, який нагадує людям рухатися і підтримує їх. Ти говориш у Telegram з однією людиною.

Як ти говориш:
- Українською, коротко: 1–3 речення. Жодних списків і заголовків.
- Гумор про ситуацію, ніколи про людину. Жодного сорому, докорів чи «ти знову не зробив».
- Звертайся на «ти». Не вживай жіночих форм дієслів і прикметників щодо людини (не «зробила», «втомлена»); обирай нейтральні конструкції: «вийшло?», «є сили?», «вже встав?».
- Пропонуй найменший можливий крок: 30 секунд руху, один вдих, один пункт зі справи. Можеш запропонувати команду /warmup — це коротка розминка просто зараз.
- Іноді можеш сказати «га-га», але не в кожній репліці.

Межі:
- Ти не терапевт і не лікар. Не став діагнозів, не радь ліків, не давай медичних порад.
- Якщо людині емоційно дуже важко, ти стаєш м'яким, нічого не вимагаєш, кажеш, що поруч має бути жива людина, і нагадуєш про команду /help, де є номери гарячих ліній.
- Не вигадуй фактів про людину. Пам'ятаєш тільки те, що є в розмові та в списку домовленостей нижче.

Домовленості:
- Якщо людина обіцяє зробити конкретну справу до певного часу («о 15:00 напишу бухгалтеру», «ввечері прогуляюсь»), виклич інструмент save_promise, щоб потім перепитати. Якщо час не названо, уточни його одним коротким питанням, а не вигадуй.
- Після збереження коротко підтверди: коли саме ти перепитаєш.
"""

TOOLS = [
    {
        "name": "save_promise",
        "description": "Зберегти домовленість людини, щоб гусь перепитав у потрібний час. "
        "Викликай, лише коли є і справа, і конкретний час.",
        "input_schema": {
            "type": "object",
            "properties": {
                "what": {"type": "string", "description": "Коротко, що людина пообіцяла зробити"},
                "due": {"type": "string", "description": "Коли перепитати, локальний час людини, формат YYYY-MM-DD HH:MM"},
            },
            "required": ["what", "due"],
            "additionalProperties": False,
        },
        "strict": True,
    }
]


@dataclass
class Reply:
    text: str
    promises: list[tuple[str, datetime]] = field(default_factory=list)


class Brain:
    def __init__(self, api_key: str, model: str, rng: random.Random | None = None, client=None):
        self.model = model
        self.rng = rng or random.Random()
        self.client = client
        if self.client is None and api_key:
            import anthropic

            self.client = anthropic.AsyncAnthropic(api_key=api_key)

    @property
    def online(self) -> bool:
        return self.client is not None

    def _context(self, now_local: datetime, promises: list[str], streak: int) -> str:
        open_list = "\n".join(f"- {p}" for p in promises) or "- немає"
        return (
            f"Зараз у людини: {now_local:%Y-%m-%d %H:%M} ({now_local:%A}). "
            f"Серія днів з розминками: {streak}.\nВідкриті домовленості:\n{open_list}"
        )

    async def reply(self, text: str, history: list[tuple[str, str]], now_local: datetime,
                    promises: list[str], streak: int) -> Reply:
        if not self.online:
            return Reply(self.rng.choice(FALLBACK_REPLIES))

        messages = [{"role": r, "content": t} for r, t in history]
        messages.append({"role": "user", "content": text})
        system = [
            {"type": "text", "text": SYSTEM, "cache_control": {"type": "ephemeral"}},
            {"type": "text", "text": self._context(now_local, promises, streak)},
        ]
        saved: list[tuple[str, datetime]] = []
        try:
            for _ in range(3):  # максимум два виклики інструмента, далі просто відповідь
                resp = await self.client.messages.create(
                    model=self.model,
                    max_tokens=1024,
                    system=system,
                    tools=TOOLS,
                    output_config={"effort": "low"},
                    messages=messages,
                )
                if resp.stop_reason != "tool_use":
                    out = "".join(b.text for b in resp.content if b.type == "text").strip()
                    return Reply(out or self.rng.choice(FALLBACK_REPLIES), saved)
                messages.append({"role": "assistant", "content": resp.content})
                results = []
                for block in resp.content:
                    if block.type != "tool_use":
                        continue
                    result, is_error = self._save(block.input, now_local, saved)
                    results.append({"type": "tool_result", "tool_use_id": block.id,
                                    "content": result, "is_error": is_error})
                messages.append({"role": "user", "content": results})
        except Exception:  # мережа, ліміти, ключ — гусь не мовчить, а відповідає сценарієм
            log.exception("LLM call failed")
            return Reply(self.rng.choice(FALLBACK_REPLIES), saved)
        return Reply("Записав. Перепитаю вчасно.", saved)

    @staticmethod
    def _save(args, now_local: datetime, saved: list) -> tuple[str, bool]:
        if isinstance(args, str):
            args = json.loads(args)
        try:
            due = datetime.strptime(args["due"], "%Y-%m-%d %H:%M").replace(tzinfo=now_local.tzinfo)
        except (KeyError, ValueError):
            return "Неправильний формат часу, потрібно YYYY-MM-DD HH:MM", True
        if due <= now_local:
            return "Цей час уже минув. Уточни в людини новий.", True
        saved.append((args["what"].strip(), due))
        return f"Збережено: перепитаю {due:%d.%m о %H:%M}", False
