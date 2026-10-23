import logging
import sys

from .app import build
from .config import Config


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    logging.getLogger("httpx").setLevel(logging.WARNING)
    cfg = Config()
    if not cfg.bot_token:
        sys.exit("BOT_TOKEN не задано. Створи бота в @BotFather і запусти: BOT_TOKEN=... python -m goose_bot")
    if not cfg.anthropic_key:
        logging.info("ANTHROPIC_API_KEY не задано: гусь відповідає на вільний текст сценарієм, без LLM.")
    build(cfg).run_polling()


if __name__ == "__main__":
    main()
