"""Telegram-шар: доставляє те, що вирішив logic.Goose, і передає йому натискання кнопок."""
import logging
from datetime import datetime, timezone

from telegram import InlineKeyboardButton, InlineKeyboardMarkup, Update
from telegram.constants import ParseMode
from telegram.error import Forbidden
from telegram.ext import (Application, CallbackQueryHandler, CommandHandler, ContextTypes, MessageHandler,
                          filters)

from .brain import Brain
from .config import Config
from .content import Content
from .logic import Goose, Out
from .store import Store

log = logging.getLogger(__name__)


def now() -> datetime:
    return datetime.now(timezone.utc)


async def deliver(app: Application, outs: list[Out]) -> None:
    goose: Goose = app.bot_data["goose"]
    for o in outs:
        markup = InlineKeyboardMarkup(
            [[InlineKeyboardButton(label, callback_data=data) for label, data in row] for row in o.buttons]
        ) if o.buttons else None
        try:
            await app.bot.send_message(o.chat_id, o.text, reply_markup=markup,
                                       parse_mode=ParseMode.HTML if o.html else None)
        except Forbidden:
            # Людина заблокувала бота: більше не пишемо їй першими.
            goose.store.update_user(o.chat_id, consent=0)
        except Exception:
            log.exception("send failed for %s", o.chat_id)


def build(cfg: Config) -> Application:
    store = Store(cfg.db_path)
    goose = Goose(cfg, store, Content.load(cfg.exercises_path), Brain(cfg.anthropic_key, cfg.model))
    app = Application.builder().token(cfg.bot_token).build()
    app.bot_data["goose"] = goose

    def cmd(fn):
        async def handler(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
            await deliver(ctx.application, fn(update.effective_chat.id, update))
        return handler

    app.add_handler(CommandHandler("start", cmd(lambda c, u: goose.start(c, u.effective_user.first_name or "", now()))))
    app.add_handler(CommandHandler("warmup", cmd(lambda c, u: goose.warmup(c, now()))))
    app.add_handler(CommandHandler("stats", cmd(lambda c, u: goose.stats(c))))
    app.add_handler(CommandHandler("promises", cmd(lambda c, u: goose.promises(c, now()))))
    app.add_handler(CommandHandler("pause", cmd(lambda c, u: goose.pause(c, 3, now()))))
    app.add_handler(CommandHandler("resume", cmd(lambda c, u: goose.resume(c))))
    app.add_handler(CommandHandler("delete", cmd(lambda c, u: goose.delete(c))))
    app.add_handler(CommandHandler("help", cmd(lambda c, u: goose.help(c))))

    async def on_button(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
        q = update.callback_query
        await q.answer()
        chat_id, data, t = q.message.chat_id, q.data or "", now()
        # Прибираємо кнопки з повідомлення, щоб не тиснути двічі.
        try:
            await q.edit_message_reply_markup(None)
        except Exception:
            pass
        if data == "consent":
            outs = goose.consent(chat_id, t)
        elif data == "done":
            outs = goose.on_done(chat_id, t)
        elif data == "snooze":
            outs = goose.on_snooze(chat_id, t)
        elif data == "skip":
            outs = goose.on_skip(chat_id, t)
        elif ":" in data:
            action, pid = data.split(":", 1)
            outs = goose.on_promise(chat_id, action, int(pid), t) if pid.isdigit() else []
        else:
            outs = []
        await deliver(ctx.application, outs)

    async def on_text(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
        chat_id = update.effective_chat.id
        await ctx.bot.send_chat_action(chat_id, "typing")
        await deliver(ctx.application, await goose.on_text(chat_id, update.message.text, now()))

    async def tick(ctx: ContextTypes.DEFAULT_TYPE):
        await deliver(ctx.application, goose.tick(now()))

    app.add_handler(CallbackQueryHandler(on_button))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, on_text))
    app.job_queue.run_repeating(tick, interval=60, first=5)
    return app
