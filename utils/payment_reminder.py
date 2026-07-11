import asyncio
import logging
from aiogram import Bot
import aiosqlite
from config import cfg
from keyboards import admin_payment_kb

logger = logging.getLogger(__name__)


async def check_pending_payments(bot: Bot) -> None:
    async with aiosqlite.connect(cfg.db_path) as db:
        db.row_factory = aiosqlite.Row
        async with db.execute(
            """
            SELECT id, telegram_id, amount, purpose,
                   ROUND((JULIANDAY('now') - JULIANDAY(created_at)) * 24, 1) as hours_ago
            FROM pending_payments
            WHERE status = 'pending'
            AND created_at <= datetime('now', '-2 hours')
            """
        ) as cur:
            rows = await cur.fetchall()

    for row in rows:
        purpose_text = {
            "wallet": "شارژ کیف پول",
            "purchase": "خرید سرویس",
            "renew": "تمدید سرویس",
        }.get(row["purpose"], row["purpose"])

        text = (
            f"⏰ <b>یادآوری پرداخت معلق</b>\n\n"
            f"🔖 شناسه: {row['id']}\n"
            f"🆔 کاربر: <code>{row['telegram_id']}</code>\n"
            f"💰 مبلغ: {row['amount']:,} تومان\n"
            f"📋 نوع: {purpose_text}\n"
            f"⏳ {row['hours_ago']} ساعت پیش ثبت شده و هنوز بررسی نشده!"
        )

        for admin_id in cfg.admin_ids:
            try:
                await bot.send_message(
                    admin_id, text,
                    reply_markup=admin_payment_kb(row["id"]),
                    parse_mode="HTML",
                )
            except Exception as e:
                logger.error("Payment reminder to admin %s failed: %s", admin_id, e)


async def payment_reminder_loop(bot: Bot) -> None:
    while True:
        await asyncio.sleep(30 * 60)
        try:
            await check_pending_payments(bot)
        except Exception as e:
            logger.error("Payment reminder loop error: %s", e)
