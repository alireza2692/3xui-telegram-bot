from __future__ import annotations
import logging
from aiogram import Bot
from config import cfg

logger = logging.getLogger(__name__)


async def send_log(bot: Bot, text: str) -> None:
    if not cfg.log_channel_id:
        return
    try:
        await bot.send_message(cfg.log_channel_id, text, parse_mode="HTML")
    except Exception as e:
        logger.error("Log channel send failed: %s", e)


async def log_new_user(bot: Bot, tg_id: int, username: str, full_name: str) -> None:
    await send_log(bot,
        f"👤 <b>کاربر جدید</b>\n\n"
        f"🆔 ID: <code>{tg_id}</code>\n"
        f"👤 نام: {full_name}\n"
        f"📱 یوزرنیم: @{username or '—'}"
    )


async def log_trial(bot: Bot, tg_id: int, username: str, email: str, sub_url: str) -> None:
    await send_log(bot,
        f"🎁 <b>تست رایگان</b>\n\n"
        f"🆔 ID: <code>{tg_id}</code>\n"
        f"📱 @{username or '—'}\n"
        f"📧 Email: <code>{email}</code>\n"
        f"🔗 لینک: <code>{sub_url}</code>"
    )


async def log_purchase(bot: Bot, tg_id: int, username: str, email: str,
                       gb: int, amount: int, sub_url: str, discount: int = 0) -> None:
    disc_text = f"\n🏷 تخفیف: {discount}%" if discount else ""
    await send_log(bot,
        f"🛒 <b>خرید سرویس جدید</b>\n\n"
        f"🆔 ID: <code>{tg_id}</code>\n"
        f"📱 @{username or '—'}\n"
        f"📧 Email: <code>{email}</code>\n"
        f"📦 حجم: {gb} گیگابایت\n"
        f"💰 مبلغ: {amount:,} تومان{disc_text}\n"
        f"🔗 لینک: <code>{sub_url}</code>"
    )


async def log_renew(bot: Bot, tg_id: int, username: str, email: str,
                    gb: int, amount: int) -> None:
    await send_log(bot,
        f"🔁 <b>تمدید سرویس</b>\n\n"
        f"🆔 ID: <code>{tg_id}</code>\n"
        f"📱 @{username or '—'}\n"
        f"📧 Email: <code>{email}</code>\n"
        f"📦 حجم اضافه: {gb} گیگابایت\n"
        f"💰 مبلغ: {amount:,} تومان"
    )


async def log_wallet_charge(bot: Bot, tg_id: int, username: str,
                            amount: int, new_balance: int) -> None:
    await send_log(bot,
        f"💳 <b>شارژ کیف پول</b>\n\n"
        f"🆔 ID: <code>{tg_id}</code>\n"
        f"📱 @{username or '—'}\n"
        f"💰 مبلغ: {amount:,} تومان\n"
        f"💳 موجودی جدید: {new_balance:,} تومان"
    )


async def log_change_link(bot: Bot, tg_id: int, username: str,
                          email: str, new_sub_url: str) -> None:
    await send_log(bot,
        f"🔄 <b>تغییر لینک اتصال</b>\n\n"
        f"🆔 ID: <code>{tg_id}</code>\n"
        f"📱 @{username or '—'}\n"
        f"📧 Email: <code>{email}</code>\n"
        f"🔗 لینک جدید: <code>{new_sub_url}</code>"
    )


async def log_payment_rejected(bot: Bot, tg_id: int, username: str, amount: int) -> None:
    await send_log(bot,
        f"❌ <b>پرداخت رد شد</b>\n\n"
        f"🆔 ID: <code>{tg_id}</code>\n"
        f"📱 @{username or '—'}\n"
        f"💰 مبلغ: {amount:,} تومان"
    )


async def log_referral_bonus(bot, inviter_id: int, inviter_username: str,
                              invitee_id: int, amount: int, bonus: int) -> None:
    await send_log(bot,
        f"🎁 <b>پاداش دعوت</b>\n\n"
        f"👤 دعوت‌کننده: <code>{inviter_id}</code> @{inviter_username or '—'}\n"
        f"👤 دعوت‌شده: <code>{invitee_id}</code>\n"
        f"💰 مبلغ شارژ: {amount:,} تومان\n"
        f"🎁 پاداش ۱۰٪: {bonus:,} تومان"
    )
