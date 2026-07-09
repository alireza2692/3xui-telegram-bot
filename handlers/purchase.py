from __future__ import annotations
import json
import logging
from aiogram import Router, F
from aiogram.fsm.context import FSMContext
from aiogram.types import CallbackQuery, Message, PhotoSize
import database as db
from config import cfg
from handlers.admin import _deliver_service
from keyboards import back_kb, confirm_buy_kb, main_menu, paid_kb, admin_payment_kb, inbound_choice_kb
from utils.pricing import calc_price, price_breakdown, get_prices
from utils.states import PurchaseSt

router = Router()
logger = logging.getLogger(__name__)


@router.message(F.text == "🛒 خرید سرویس")
async def buy_start(message: Message, state: FSMContext) -> None:
    await state.clear()
    await state.set_state(PurchaseSt.gb)
    await message.answer(
        "📦 چند گیگابایت سرویس می‌خواهید؟\n\n"
        "💡 مدت همه سرویس‌ها <b>۳۰ روز</b> است.\n"
        "فقط عدد صحیح مثبت وارد کنید:",
        reply_markup=back_kb(), parse_mode="HTML",
    )


@router.message(PurchaseSt.gb)
async def buy_gb(message: Message, state: FSMContext) -> None:
    raw = (message.text or "").strip()
    if not raw.isdigit() or int(raw) <= 0:
        await message.answer("❌ فقط عدد صحیح مثبت وارد کنید (مثال: 30)", reply_markup=back_kb())
        return
    gb = int(raw)
    total = await calc_price(gb)
    await state.update_data(gb=gb, total=total, discount=0)

    from config import cfg
    if len(cfg.inbounds) > 1:
        await state.set_state(PurchaseSt.server)
        await message.answer(
            "🌍 لطفاً سرور مورد نظر را انتخاب کنید:",
            reply_markup=inbound_choice_kb(cfg.inbounds),
        )
        return

    if cfg.inbounds:
        ib_id, _remark, ib_flow = cfg.inbounds[0]
        await state.update_data(inbound_id=ib_id, inbound_flow=ib_flow)

    await state.set_state(PurchaseSt.service_name)
    await message.answer(
        "✏️ یک نام برای سرویس خود انتخاب کنید:\n\n"
        "✅ مجاز: حروف انگلیسی کوچک، اعداد و <code>. - _ + @</code>\n"
        "❌ غیرمجاز: حروف بزرگ، فاصله، کاراکتر خاص\n"
        "📏 طول: ۳ تا ۳۰ کاراکتر\n\n"
        "مثال: <code>ali.reza</code> یا <code>user-123</code>",
        reply_markup=back_kb(), parse_mode="HTML",
    )



@router.message(PurchaseSt.service_name)
async def buy_service_name(message: Message, state: FSMContext) -> None:
    import re
    name = (message.text or "").strip().lower()
    if not re.match(r"^[a-z0-9._%+\-@]{3,30}$", name):
        await message.answer(
            "❌ نام نامعتبر!\n\n"
            "✅ مجاز: حروف انگلیسی کوچک، اعداد و کاراکترهای <code>. - _ + @</code>\n"
            "❌ غیرمجاز: حروف بزرگ، فاصله، کاراکترهای خاص دیگر\n"
            "📏 طول: حداقل ۳ و حداکثر ۳۰ کاراکتر\n\n"
            "مثال: <code>ali.reza</code> یا <code>user-123</code> یا <code>ali@vpn</code>",
            reply_markup=back_kb(), parse_mode="HTML",
        )
        return
    from services.panel import panel
    try:
        existing = await panel.get_client(name)
        if existing:
            await message.answer(
                f"❌ نام <code>{name}</code> قبلاً استفاده شده است.\n"
                f"لطفاً نام دیگری انتخاب کنید:",
                reply_markup=back_kb(), parse_mode="HTML",
            )
            return
    except Exception:
        pass

    data = await state.get_data()
    gb = data["gb"]
    total = data["total"]
    breakdown = await price_breakdown(gb)
    await state.update_data(service_name=name)
    await state.set_state(PurchaseSt.confirm)

    from aiogram.utils.keyboard import InlineKeyboardBuilder
    from aiogram.types import InlineKeyboardButton
    b = InlineKeyboardBuilder()
    b.row(InlineKeyboardButton(text="🏷 دارم کد تخفیف", callback_data="enter_discount"))
    b.row(InlineKeyboardButton(text="✅ تایید و پرداخت", callback_data="buy_confirm"))
    b.row(InlineKeyboardButton(text="❌ انصراف", callback_data="back_main"))
    await message.answer(
        f"🛒 <b>جزئیات سفارش</b>\n\n"
        f"📝 نام سرویس: <code>{name}</code>\n\n"
        f"{breakdown}\n\nکد تخفیف دارید؟",
        reply_markup=b.as_markup(), parse_mode="HTML",
    )

@router.callback_query(F.data == "enter_discount", PurchaseSt.confirm)
async def enter_discount_cb(cb: CallbackQuery, state: FSMContext) -> None:
    await cb.message.answer("🏷 کد تخفیف را وارد کنید:", reply_markup=back_kb())
    await cb.answer()


@router.callback_query(F.data == "back_main", PurchaseSt.confirm)
async def cancel_purchase_with_discount(cb: CallbackQuery, state: FSMContext) -> None:
    data = await state.get_data()
    code = data.get("discount_code")
    if code:
        import aiosqlite
        from config import cfg as _cfg
        async with aiosqlite.connect(_cfg.db_path) as _db:
            await _db.execute(
                "DELETE FROM discount_uses WHERE code=? AND telegram_id=?",
                (code.upper(), cb.from_user.id)
            )
            await _db.execute(
                "UPDATE discount_codes SET used_count=MAX(0,used_count-1) WHERE code=?",
                (code.upper(),)
            )
            await _db.commit()
    await state.clear()
    await cb.message.answer("منوی اصلی:", reply_markup=main_menu())
    await cb.answer()


@router.message(PurchaseSt.confirm)
async def apply_discount(message: Message, state: FSMContext) -> None:
    code = (message.text or "").strip().upper()
    tg_id = message.from_user.id
    disc = await db.get_discount_code(code)
    if not disc:
        await message.answer("❌ کد تخفیف نامعتبر یا تمام شده است.", reply_markup=back_kb())
        return
    ok = await db.use_discount_code(code, tg_id)
    if not ok:
        await message.answer("❌ شما قبلاً از این کد استفاده کرده‌اید.", reply_markup=back_kb())
        return
    data = await state.get_data()
    gb = data["gb"]
    original = await calc_price(gb)
    percent = disc["percent"]
    discounted = int(original * (100 - percent) / 100)
    await state.update_data(total=discounted, discount=percent)

    from aiogram.utils.keyboard import InlineKeyboardBuilder
    from aiogram.types import InlineKeyboardButton
    b = InlineKeyboardBuilder()
    b.row(InlineKeyboardButton(text="✅ تایید و پرداخت", callback_data="buy_confirm"))
    b.row(InlineKeyboardButton(text="❌ انصراف", callback_data="back_main"))
    await message.answer(
        f"🎉 کد تخفیف اعمال شد!\n\n"
        f"📦 {gb} گیگابایت\n"
        f"💰 قیمت اصلی: {original:,} تومان\n"
        f"🏷 تخفیف: {percent}%\n"
        f"🧾 مبلغ نهایی: <b>{discounted:,} تومان</b>",
        reply_markup=b.as_markup(), parse_mode="HTML",
    )


@router.callback_query(F.data == "buy_confirm", PurchaseSt.confirm)
async def buy_confirm(cb: CallbackQuery, state: FSMContext) -> None:
    data = await state.get_data()
    gb, total = data["gb"], data["total"]
    tg_id = cb.from_user.id
    balance = await db.get_balance(tg_id)

    if balance >= total:
        service_name = data.get("service_name", "")
        await db.add_balance(tg_id, -total, f"خرید {gb}GB سرویس VPN")
        await state.clear()
        await cb.message.answer("⏳ در حال ایجاد سرویس...")
        await cb.answer()
        ib_id = data.get("inbound_id")
        ib_flow = data.get("inbound_flow")
        try:
            await _deliver_service(cb.bot, tg_id, gb, total, "new", service_name, ib_id, ib_flow)
        except Exception as e:
            await db.add_balance(tg_id, total, "بازگشت وجه - خطا در ایجاد سرویس")
            await cb.bot.send_message(
                tg_id,
                f"❌ خطا در ایجاد سرویس!\n\n"
                f"مبلغ {total:,} تومان به کیف پول شما بازگشت داده شد.\n"
                f"لطفاً با نام دیگری امتحان کنید یا با پشتیبانی تماس بگیرید.",
                reply_markup=main_menu(),
            )
    else:
        shortfall = total - balance
        await state.update_data(shortfall=shortfall)
        await state.set_state(PurchaseSt.receipt)
        await cb.message.answer(
            f"💳 موجودی کافی نیست!\n\n"
            f"موجودی: {balance:,} تومان\n"
            f"نیاز: {total:,} تومان\n"
            f"کمبود: <b>{shortfall:,} تومان</b>\n\n"
            f"لطفاً <b>{shortfall:,} تومان</b> را به یکی از کارت های زیر واریز کنید:\n\n"
            f"{cfg.cards_text()}",
            reply_markup=paid_kb(), parse_mode="HTML",
        )
        await cb.answer()


@router.callback_query(F.data == "paid", PurchaseSt.receipt)
async def buy_paid(cb: CallbackQuery) -> None:
    await cb.message.answer("📷 تصویر رسید را ارسال کنید:", reply_markup=back_kb())
    await cb.answer()


@router.message(PurchaseSt.receipt)
async def buy_receipt(message: Message, state: FSMContext) -> None:
    if not message.photo:
        await message.answer("❌ فقط تصویر رسید قابل قبول است.", reply_markup=back_kb())
        return
    data = await state.get_data()
    gb, total, shortfall = data["gb"], data["total"], data.get("shortfall", data["total"])
    photo: PhotoSize = message.photo[-1]
    tg_id = message.from_user.id

    service_name = data.get("service_name", "")
    ib_id = data.get("inbound_id")
    ib_flow = data.get("inbound_flow")
    pid = await db.create_pending_payment(
        tg_id, shortfall, photo.file_id, "purchase",
        json.dumps({"gb": gb, "total": total, "service_name": service_name, "inbound_id": ib_id, "inbound_flow": ib_flow}),
    )
    await state.clear()

    u = message.from_user
    caption = (
        f"📥 <b>رسید خرید سرویس</b>\n\n"
        f"👤 {u.full_name} | 🆔 <code>{u.id}</code> | @{u.username or '—'}\n"
        f"💰 {shortfall:,} تومان | 📦 {gb}GB | 🔖 شناسه: {pid}"
    )
    for admin_id in cfg.admin_ids:
        try:
            await message.bot.send_photo(admin_id, photo.file_id, caption=caption,
                                         reply_markup=admin_payment_kb(pid), parse_mode="HTML")
        except Exception as e:
            logger.error("Notify admin %s: %s", admin_id, e)

    await message.answer(
        "✅ رسید ارسال شد. پس از تایید ادمین سرویس به صورت خودکار ایجاد می‌شود.",
        reply_markup=main_menu(),
    )


@router.callback_query(F.data.startswith("pick_inbound:"), PurchaseSt.server)
async def buy_pick_inbound(cb: CallbackQuery, state: FSMContext) -> None:
    from config import cfg
    ib_id = cb.data.split(":", 1)[1]
    ib_flow = ""
    for i_id, _remark, i_flow in cfg.inbounds:
        if str(i_id) == str(ib_id):
            ib_flow = i_flow
            break
    await state.update_data(inbound_id=ib_id, inbound_flow=ib_flow)
    await state.set_state(PurchaseSt.service_name)
    await cb.message.answer(
        "✏️ یک نام برای سرویس خود انتخاب کنید:\n\n"
        "✅ مجاز: حروف انگلیسی کوچک، اعداد و کاراکترهای <code>. - _ + @</code>\n"
        "❌ غیرمجاز: حروف بزرگ، فاصله، کاراکتر خاص\n"
        "📏 طول: ۳ تا ۳۰ کاراکتر\n\n"
        "مثال: <code>ali.reza</code> یا <code>user-123</code>",
        reply_markup=back_kb(), parse_mode="HTML",
    )
    await cb.answer()
