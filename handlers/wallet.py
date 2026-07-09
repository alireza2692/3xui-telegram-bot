from __future__ import annotations
import json
import logging
from aiogram import Router, F
from aiogram.fsm.context import FSMContext
from aiogram.types import CallbackQuery, Message, PhotoSize
import database as db
from config import cfg
from keyboards import wallet_kb, paid_kb, back_kb, admin_payment_kb, main_menu
from utils.states import WalletSt

router = Router()
logger = logging.getLogger(__name__)


@router.message(F.text == "💳 کیف پول")
async def wallet_menu(message: Message, state: FSMContext) -> None:
    await state.clear()
    bal = await db.get_balance(message.from_user.id)
    await message.answer(
        f"💳 <b>کیف پول شما</b>\n\nموجودی: <b>{bal:,} تومان</b>",
        reply_markup=wallet_kb(), parse_mode="HTML",
    )


@router.callback_query(F.data == "wallet_topup")
async def topup_start(cb: CallbackQuery, state: FSMContext) -> None:
    await state.set_state(WalletSt.amount)
    await cb.message.answer(
        "💰 مبلغ شارژ را به <b>تومان</b> وارد کنید:\n(فقط عدد صحیح مثبت)",
        reply_markup=back_kb(), parse_mode="HTML",
    )
    await cb.answer()


@router.message(WalletSt.amount)
async def topup_amount(message: Message, state: FSMContext) -> None:
    raw = (message.text or "").strip()
    if not raw.isdigit() or int(raw) <= 0:
        await message.answer("❌ فقط عدد صحیح مثبت وارد کنید (مثال: 100000)", reply_markup=back_kb())
        return
    amount = int(raw)
    await state.update_data(topup_amount=amount)
    await state.set_state(WalletSt.receipt)
    await message.answer(
        f"💳 لطفاً <b>{amount:,} تومان</b> را به یکی از کارت های زیر واریز کنید:\n\n"
        f"{cfg.cards_text()}\n\nپس از واریز دکمه زیر را بزنید.",
        reply_markup=paid_kb(), parse_mode="HTML",
    )


@router.callback_query(F.data == "paid", WalletSt.receipt)
async def topup_paid(cb: CallbackQuery) -> None:
    await cb.message.answer("📷 تصویر رسید پرداخت را ارسال کنید:", reply_markup=back_kb())
    await cb.answer()


@router.message(WalletSt.receipt)
async def topup_receipt(message: Message, state: FSMContext) -> None:
    if not message.photo:
        await message.answer("❌ فقط تصویر رسید قابل قبول است.", reply_markup=back_kb())
        return
    data = await state.get_data()
    amount = data["topup_amount"]
    photo: PhotoSize = message.photo[-1]
    pid = await db.create_pending_payment(
        message.from_user.id, amount, photo.file_id, "wallet", "{}"
    )
    await state.clear()
    u = message.from_user
    caption = (
        f"📥 <b>رسید شارژ کیف پول</b>\n\n"
        f"👤 {u.full_name} | 🆔 <code>{u.id}</code> | @{u.username or '—'}\n"
        f"💰 {amount:,} تومان | 🔖 شناسه: {pid}"
    )
    for admin_id in cfg.admin_ids:
        try:
            await message.bot.send_photo(admin_id, photo.file_id, caption=caption,
                                         reply_markup=admin_payment_kb(pid), parse_mode="HTML")
        except Exception as e:
            logger.error("Notify admin %s: %s", admin_id, e)
    await message.answer("✅ رسید دریافت شد. پس از تایید ادمین موجودی اضافه می‌شود.", reply_markup=main_menu())
