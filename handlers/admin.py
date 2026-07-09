from __future__ import annotations
import json
import logging
from aiogram import Router, F
from aiogram.filters import Filter
from aiogram.types import CallbackQuery, BufferedInputFile
from config import cfg
import database as db
from keyboards import main_menu, admin_payment_kb
from utils.log_channel import log_purchase, log_renew, log_wallet_charge, log_payment_rejected, log_referral_bonus
from services.panel import panel
from utils.qr import make_qr

router = Router()
logger = logging.getLogger(__name__)


class IsAdmin(Filter):
    async def __call__(self, cb: CallbackQuery) -> bool:
        return cb.from_user.id in cfg.admin_ids


router.callback_query.filter(IsAdmin())


@router.callback_query(F.data.startswith("ap:"))
async def approve_payment(cb: CallbackQuery) -> None:
    pid = int(cb.data.split(":")[1])
    payment = await db.get_pending_payment(pid)

    if not payment:
        await cb.answer("پرداخت یافت نشد!", show_alert=True)
        return
    if payment["status"] != "pending":
        await cb.answer("قبلاً بررسی شده.", show_alert=True)
        return

    await db.update_payment_status(pid, "approved")
    tg_id = payment["telegram_id"]
    amount = payment["amount"]
    purpose = payment["purpose"]
    meta = json.loads(payment["meta"] or "{}")

    try:
        if purpose == "wallet":
            new_bal = await db.add_balance(tg_id, amount, "شارژ کیف پول")
            await cb.bot.send_message(
                tg_id,
                f"✅ پرداخت تایید شد!\n💰 {amount:,} تومان به کیف پول اضافه شد.\n💳 موجودی: {new_bal:,} تومان",
                reply_markup=main_menu(),
            )

        elif purpose == "purchase":
            gb = meta["gb"]
            service_name = meta.get("service_name", "")
            m_inbound_id = meta.get("inbound_id")
            m_inbound_flow = meta.get("inbound_flow")
            try:
                await _deliver_service(cb.bot, tg_id, gb, amount, "new", service_name, m_inbound_id, m_inbound_flow)
            except Exception as e:
                logger.exception("Deliver service failed: %s", e)
                await cb.bot.send_message(
                    tg_id,
                    f"❌ خطا در ایجاد سرویس!\n\n"
                    f"مبلغ {amount:,} تومان به کیف پول شما اضافه شد.\n"
                    f"لطفاً با نام دیگری امتحان کنید.",
                    reply_markup=main_menu(),
                )
                await db.add_balance(tg_id, amount, "بازگشت وجه - خطا در ایجاد سرویس")
                await cb.answer("❌ خطا در ایجاد سرویس", show_alert=True)
                return

        elif purpose == "renew":
            email = meta["client_email"]
            gb = meta["gb"]
            await panel.renew_client(email, gb)
            await db.create_order(tg_id, email, gb, amount, "renew")
            await db.clear_reminder(tg_id, email)
            await cb.bot.send_message(
                tg_id,
                f"✅ سرویس تمدید شد!\n📦 {gb} گیگابایت اضافه شد\n📅 ۳۰ روز به انقضا اضافه شد",
                reply_markup=main_menu(),
            )
            user = await cb.bot.get_chat(tg_id)
            await log_renew(cb.bot, tg_id, getattr(user, "username", "") or "", email, gb, amount)

        await cb.answer("✅ تایید شد")
        try:
            await cb.message.edit_caption(
                (cb.message.caption or "") + "\n\n✅ <b>تایید شد</b>", parse_mode="HTML"
            )
        except Exception:
            pass

    except Exception as e:
        logger.exception("Error after approval: %s", e)
        await cb.bot.send_message(tg_id, f"❌ خطا در ایجاد سرویس: {e}\nبا پشتیبانی تماس بگیرید.")
        await cb.answer("خطا!", show_alert=True)


@router.callback_query(F.data.startswith("rp:"))
async def reject_payment(cb: CallbackQuery) -> None:
    pid = int(cb.data.split(":")[1])
    payment = await db.get_pending_payment(pid)

    if not payment:
        await cb.answer("پرداخت یافت نشد!", show_alert=True)
        return
    if payment["status"] != "pending":
        await cb.answer("قبلاً بررسی شده.", show_alert=True)
        return

    await db.update_payment_status(pid, "rejected")
    await cb.bot.send_message(
        payment["telegram_id"],
        "❌ پرداخت شما تایید نشد.\nدر صورت نیاز با پشتیبانی تماس بگیرید.",
        reply_markup=main_menu(),
    )
    user = await cb.bot.get_chat(payment["telegram_id"])
    await log_payment_rejected(cb.bot, payment["telegram_id"], getattr(user, "username", "") or "", payment["amount"])
    await cb.answer("❌ رد شد")
    try:
        await cb.message.edit_caption(
            (cb.message.caption or "") + "\n\n❌ <b>رد شد</b>", parse_mode="HTML"
        )
    except Exception:
        pass


async def _deliver_service(bot, tg_id: int, gb: int, amount_paid: int, order_type: str,
                           service_name: str = "", inbound_id=None, flow=None) -> None:
    """Create panel client and send sub link + QR to user."""
    from config import cfg
    email, sub_id = await panel.create_client(
        gb=gb, days=30, email=service_name, inbound_id=inbound_id, flow=flow
    )
    url = panel.sub_url(sub_id)
    qr = make_qr(url)

    await db.create_order(tg_id, email, gb, amount_paid, order_type)

    await bot.send_message(
        tg_id,
        f"🎉 <b>سرویس شما آماده است!</b>\n\n"
        f"📦 حجم: {gb} گیگابایت\n"
        f"📅 مدت: ۳۰ روز\n\n"
        f"🔗 لینک اشتراک:\n<code>{url}</code>",
        parse_mode="HTML",
        reply_markup=main_menu(),
    )
    await bot.send_photo(
        tg_id,
        BufferedInputFile(qr, filename="qr.png"),
        caption="📱 QR Code لینک اشتراک",
    )
    user = await bot.get_chat(tg_id)
    await log_purchase(bot, tg_id, getattr(user, "username", "") or "", email, gb, amount_paid, url)
