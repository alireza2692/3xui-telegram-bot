from __future__ import annotations
import logging
from aiogram import Router, F
from aiogram.fsm.context import FSMContext
from aiogram.types import Message, BufferedInputFile
import database as db
from config import cfg
from keyboards import main_menu
from utils.log_channel import log_trial
from services.panel import panel
from utils.qr import make_qr

router = Router()
logger = logging.getLogger(__name__)


@router.message(F.text == "🎁 تست رایگان")
async def free_trial(message: Message, state: FSMContext) -> None:
    await state.clear()
    tg_id = message.from_user.id

    trial_enabled = await db.get_setting("trial_enabled", "1")
    if trial_enabled != "1":
        await message.answer("❌ تست رایگان در حال حاضر غیرفعال است.", reply_markup=main_menu())
        return

    if await db.has_free_trial(tg_id):
        await message.answer(
            "⚠️ شما قبلاً از تست رایگان استفاده کرده‌اید.\nهر کاربر فقط یک بار می‌تواند تست رایگان دریافت کند.",
            reply_markup=main_menu(),
        )
        return

    await message.answer("⏳ در حال ساخت سرویس تست رایگان...")

    try:
        email, sub_id = await panel.create_client(gb=cfg.trial_gb, days=cfg.trial_days)
        await db.record_free_trial(tg_id, email)

        url = panel.sub_url(sub_id)
        qr = make_qr(url)

        await message.answer(
            f"🎁 <b>سرویس تست رایگان آماده است!</b>\n\n"
            f"📦 حجم: {cfg.trial_gb} گیگابایت\n"
            f"📅 مدت: {cfg.trial_days} روز\n"
            f"🔗 پروتکل: VLESS Reality\n\n"
            f"🔗 لینک اشتراک:\n<code>{url}</code>",
            parse_mode="HTML", reply_markup=main_menu(),
        )
        await message.answer_photo(
            BufferedInputFile(qr, filename="qr.png"),
            caption="📱 QR Code لینک اشتراک تست رایگان",
        )
        u = message.from_user
        await log_trial(message.bot, u.id, u.username or "", email, url)
    except Exception as e:
        logger.exception("Trial creation failed: %s", e)
        await message.answer("❌ خطا در ایجاد سرویس تست. لطفاً بعداً دوباره امتحان کنید.", reply_markup=main_menu())
