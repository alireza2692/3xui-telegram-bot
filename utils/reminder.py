import asyncio
import logging
from aiogram import Bot
import database as db
from services.panel import panel

logger = logging.getLogger(__name__)


async def check_expiry_reminders(bot: Bot) -> None:
    rows = await db.get_expiring_orders()
    for row in rows:
        tg_id = row["telegram_id"]
        email = row["client_email"]
        try:
            c = await panel.get_client(email)
            if not c:
                continue

            days_left = panel.remaining_days(c["expiryTime"])
            used_gb = panel.bytes_to_gb(c["usedTraffic"])
            total_gb = panel.bytes_to_gb(c["totalGB"])
            remaining_gb = max(0.0, round(total_gb - used_gb, 2))
            if total_gb > 0 and remaining_gb <= 3.0:
                already_sent = await db.has_reminder_sent(tg_id, email, "traffic")
                if not already_sent:
                    await bot.send_message(
                        tg_id,
                        f"⚠️ <b>حجم سرویس رو به اتمام است!</b>\n\n"
                        f"📧 سرویس: <code>{email}</code>\n"
                        f"💾 حجم باقی‌مانده: <b>{remaining_gb} GB</b>\n\n"
                        f"برای تمدید از منوی «📋 سرویس های من» اقدام کنید.",
                        parse_mode="HTML",
                    )
                    await db.mark_reminder_sent(tg_id, email, "traffic")
            if 0 < days_left <= 3:
                already_sent = await db.has_reminder_sent(tg_id, email, "expiry")
                if not already_sent:
                    await bot.send_message(
                        tg_id,
                        f"⚠️ <b>سرویس شما دارد منقضی می‌شود!</b>\n\n"
                        f"📧 سرویس: <code>{email}</code>\n"
                        f"⏳ روزهای باقی‌مانده: <b>{days_left} روز</b>\n\n"
                        f"برای تمدید از منوی «📋 سرویس های من» اقدام کنید.",
                        parse_mode="HTML",
                    )
                    await db.mark_reminder_sent(tg_id, email, "expiry")

        except Exception as e:
            logger.debug("Reminder check %s: %s", email, e)
        await asyncio.sleep(0.1)


async def reminder_loop(bot: Bot) -> None:
    while True:
        try:
            await check_expiry_reminders(bot)
            logger.info("Expiry reminder check done")
        except Exception as e:
            logger.error("Reminder loop error: %s", e)
        await asyncio.sleep(12 * 3600)
