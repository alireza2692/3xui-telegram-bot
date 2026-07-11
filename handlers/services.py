from __future__ import annotations
import json
import logging
from aiogram import Router, F
from aiogram.fsm.context import FSMContext
from aiogram.types import CallbackQuery, Message, PhotoSize, BufferedInputFile
import database as db
from config import cfg
from keyboards import back_kb, confirm_chlink_kb, confirm_renew_kb, main_menu, paid_kb, service_kb, admin_payment_kb
from services.panel import panel
from utils.log_channel import log_change_link
from utils.pricing import calc_price, price_breakdown
from utils.qr import make_qr
from utils.states import RenewSt, ServiceSt

router = Router()
logger = logging.getLogger(__name__)


@router.message(F.text == "📋 سرویس های من")
async def my_services_msg(message: Message, state: FSMContext) -> None:
    await state.clear()
    await _show_services(message.from_user.id, message)


@router.callback_query(F.data == "my_services")
async def my_services_cb(cb: CallbackQuery, state: FSMContext) -> None:
    await state.clear()
    await _show_services(cb.from_user.id, cb.message)
    await cb.answer()


async def _show_services(tg_id: int, message: Message) -> None:
    rows = await db.get_user_orders(tg_id)
    if not rows:
        await message.answer("📭 شما هیچ سرویسی ندارید.", reply_markup=main_menu())
        return
    found = False
    for row in rows:
        email = row["client_email"]
        try:
            c = await panel.get_client(email)
        except Exception:
            continue
        if not c:
            continue
        found = True
        await message.answer(_service_text(c), reply_markup=service_kb(email), parse_mode="HTML")
    if not found:
        await message.answer("📭 هیچ سرویس فعالی روی پنل یافت نشد.", reply_markup=main_menu())


@router.callback_query(F.data.startswith("view:"))
async def view_service(cb: CallbackQuery, state: FSMContext) -> None:
    await state.clear()
    email = cb.data.split(":", 1)[1]
    try:
        c = await panel.get_client(email)
    except Exception:
        c = None
    if not c:
        await cb.message.answer("❌ سرویس یافت نشد.", reply_markup=main_menu())
    else:
        await cb.message.answer(_service_text(c), reply_markup=service_kb(email), parse_mode="HTML")
    await cb.answer()


def _service_text(c: dict) -> str:
    email = c["email"]
    total_gb = panel.bytes_to_gb(c["totalGB"])
    used_gb = panel.bytes_to_gb(c["usedTraffic"])
    remaining_gb = max(0.0, round(total_gb - used_gb, 2))
    expire_ms = c["expiryTime"]
    sub_id = c["subId"]
    url = panel.sub_url(sub_id) if sub_id else "ندارد"
    return (
        f"📦 <b>سرویس: {email}</b>\n\n"
        f"📊 حجم کل: {total_gb} GB\n"
        f"✅ مصرف شده: {used_gb} GB\n"
        f"💾 باقی مانده: {remaining_gb} GB\n"
        f"⏳ روزهای باقی: {panel.remaining_days(expire_ms)} روز\n"
        f"📅 انقضا: {panel.expire_date(expire_ms)}\n\n"
        f"🔗 لینک اشتراک:\n<code>{url}</code>"
    )


@router.callback_query(F.data.startswith("chlink:"))
async def chlink_start(cb: CallbackQuery, state: FSMContext) -> None:
    email = cb.data.split(":", 1)[1]
    await state.set_state(ServiceSt.confirm_change)
    await state.update_data(email=email)
    await cb.message.answer("⚠️ با تغییر لینک، لینک قبلی غیرفعال میشود. مطمئنید؟", reply_markup=confirm_chlink_kb(email))
    await cb.answer()


@router.callback_query(F.data.startswith("chlink_ok:"), ServiceSt.confirm_change)
async def chlink_confirm(cb: CallbackQuery, state: FSMContext) -> None:
    email = cb.data.split(":", 1)[1]
    await state.clear()
    try:
        new_sub = await panel.change_link(email)
        url = panel.sub_url(new_sub)
        qr = make_qr(url)
        await cb.message.answer(f"✅ لینک تغییر کرد!\n\n🔗 لینک جدید:\n<code>{url}</code>", parse_mode="HTML", reply_markup=main_menu())
        await cb.message.answer_photo(BufferedInputFile(qr, filename="qr.png"), caption="📱 QR Code لینک جدید")
        u = cb.from_user
        await log_change_link(cb.bot, u.id, u.username or "", email, url)
    except Exception as e:
        logger.exception("Change link error: %s", e)
        await cb.message.answer("❌ خطا در تغییر لینک.", reply_markup=main_menu())
    await cb.answer()


@router.callback_query(F.data.startswith("renew:"))
async def renew_start(cb: CallbackQuery, state: FSMContext) -> None:
    email = cb.data.split(":", 1)[1]
    await state.clear()
    await state.set_state(RenewSt.gb)
    await state.update_data(email=email)
    await cb.message.answer(f"🔁 تمدید سرویس: <code>{email}</code>\n\nچند گیگابایت اضافه کنید؟", reply_markup=back_kb(), parse_mode="HTML")
    await cb.answer()


@router.message(RenewSt.gb)
async def renew_gb(message: Message, state: FSMContext) -> None:
    raw = (message.text or "").strip()
    if not raw.isdigit() or int(raw) <= 0:
        await message.answer("❌ فقط عدد صحیح مثبت وارد کنید.", reply_markup=back_kb())
        return
    gb = int(raw)
    total = await calc_price(gb)
    data = await state.get_data()
    await state.update_data(gb=gb, total=total)
    await state.set_state(RenewSt.confirm)
    breakdown = await price_breakdown(gb)
    await message.answer(
        f"🔁 <b>جزئیات تمدید</b>\n\n📧 سرویس: <code>{data["email"]}</code>\n{breakdown}\n\nتایید؟",
        reply_markup=confirm_renew_kb(), parse_mode="HTML",
    )


@router.callback_query(F.data == "renew_confirm", RenewSt.confirm)
async def renew_confirm(cb: CallbackQuery, state: FSMContext) -> None:
    data = await state.get_data()
    gb, total, email = data["gb"], data["total"], data["email"]
    tg_id = cb.from_user.id
    balance = await db.get_balance(tg_id)
    if balance >= total:
        await db.add_balance(tg_id, -total, f"تمدید {gb}GB {email}")
        await state.clear()
        await cb.message.answer("⏳ در حال تمدید...")
        await cb.answer()
        try:
            await panel.renew_client(email, gb)
            await db.create_order(tg_id, email, gb, total, "renew")
            await db.clear_reminder(tg_id, email)
            await cb.bot.send_message(tg_id, f"✅ تمدید شد!\n📦 {gb}GB اضافه شد\n📅 ۳۰ روز اضافه شد", reply_markup=main_menu())
            u = cb.from_user
            from utils.log_channel import log_renew
            await log_renew(cb.bot, tg_id, u.username or "", email, gb, total)
        except Exception as e:
            logger.exception("Renew error: %s", e)
            await cb.bot.send_message(tg_id, f"❌ خطا: {e}", reply_markup=main_menu())
    else:
        shortfall = total - balance
        await state.update_data(shortfall=shortfall)
        await state.set_state(RenewSt.receipt)
        await cb.message.answer(
            f"💳 موجودی کافی نیست!\nکمبود: <b>{shortfall:,} تومان</b>\n\nبه یکی از کارت های زیر واریز کنید:\n\n{cfg.cards_text()}",
            reply_markup=paid_kb(), parse_mode="HTML",
        )
        await cb.answer()


@router.callback_query(F.data == "paid", RenewSt.receipt)
async def renew_paid(cb: CallbackQuery) -> None:
    await cb.message.answer("📷 تصویر رسید را ارسال کنید:", reply_markup=back_kb())
    await cb.answer()


@router.message(RenewSt.receipt)
async def renew_receipt(message: Message, state: FSMContext) -> None:
    if not message.photo:
        await message.answer("❌ فقط تصویر رسید قابل قبول است.", reply_markup=back_kb())
        return
    data = await state.get_data()
    gb, total, email = data["gb"], data["total"], data["email"]
    shortfall = data.get("shortfall", total)
    photo: PhotoSize = message.photo[-1]
    tg_id = message.from_user.id
    pid = await db.create_pending_payment(tg_id, shortfall, photo.file_id, "renew", json.dumps({"gb": gb, "total": total, "client_email": email}))
    await state.clear()
    u = message.from_user
    caption = f"📥 <b>رسید تمدید</b>\n\n👤 {u.full_name} | 🆔 <code>{u.id}</code>\n💰 {shortfall:,} تومان | 📦 {gb}GB | 📧 {email} | 🔖 {pid}"
    for admin_id in cfg.admin_ids:
        try:
            await message.bot.send_photo(admin_id, photo.file_id, caption=caption, reply_markup=admin_payment_kb(pid), parse_mode="HTML")
        except Exception as e:
            logger.error("Notify admin %s: %s", admin_id, e)
    await message.answer("✅ رسید ارسال شد.", reply_markup=main_menu())
