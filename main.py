from __future__ import annotations
import asyncio
import logging

from aiogram import Bot, Dispatcher
from aiogram.client.default import DefaultBotProperties
from aiogram.client.session.aiohttp import AiohttpSession
from aiogram.enums import ParseMode
from aiogram.fsm.storage.memory import MemoryStorage
try:
    from aiogram.fsm.storage.redis import RedisStorage
    _use_redis = False
except ImportError:
    _use_redis = False

from config import cfg
from database import init_db
from middlewares.membership import MembershipMiddleware
from handlers import admin, admin_extra, start, wallet, trial, purchase, services

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger(__name__)


async def main() -> None:
    await init_db()
    if cfg.proxy_enabled:
        session = AiohttpSession(proxy=f"socks5://{cfg.proxy_host}:{cfg.proxy_port}")
        logger.info("Using SOCKS5 proxy: %s:%s", cfg.proxy_host, cfg.proxy_port)
    else:
        session = AiohttpSession()
        logger.info("No proxy configured - connecting directly")

    bot = Bot(
        token=cfg.bot_token,
        session=session,
        default=DefaultBotProperties(parse_mode=ParseMode.HTML),
    )

    storage = MemoryStorage()
    dp = Dispatcher(storage=storage)
    dp.message.middleware(MembershipMiddleware())
    dp.callback_query.middleware(MembershipMiddleware())
    dp.include_router(admin.router)
    dp.include_router(admin_extra.router)
    dp.include_router(start.router)
    dp.include_router(wallet.router)
    dp.include_router(trial.router)
    dp.include_router(purchase.router)
    dp.include_router(services.router)
    @dp.startup()
    async def on_startup():
        logger.info("Bot started - FSM states cleared (MemoryStorage)")

    logger.info("Starting bot | proxy=%s:%s", cfg.proxy_host, cfg.proxy_port)
    try:
        from utils.reminder import reminder_loop
        from utils.payment_reminder import payment_reminder_loop
        import asyncio as _asyncio
        _asyncio.create_task(reminder_loop(bot))
        _asyncio.create_task(payment_reminder_loop(bot))
        await dp.start_polling(bot, allowed_updates=dp.resolve_used_update_types())
    finally:
        await bot.session.close()
        from services.panel import panel
        await panel.close()


if __name__ == "__main__":
    asyncio.run(main())
