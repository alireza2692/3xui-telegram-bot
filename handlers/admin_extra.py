from __future__ import annotations
import asyncio
import logging
import aiosqlite
from aiogram import Router, F
from aiogram.filters import Command
from aiogram.fsm.context import FSMContext
from aiogram.fsm.state import State, StatesGroup
from aiogram.types import Message
from aiogram.filters import Filter
import database as db
from config import cfg
from keyboards import main_menu, admin_payment_kb

router = Router()
logger = logging.getLogger(__name__)


class IsAdmin(Filter):
    async def __call__(self, message: Message) -> bool:
        return message.from_user.id in cfg.admin_ids


router.message.filter(IsAdmin())


class AdminSt(StatesGroup):
    broadcast = State()

@router.message(Command("broadcast"))
async def broadcast_start(message: Message, state: FSMContext) -> None:
    await state.set_state(AdminSt.broadcast)
    await message.answer("📢 متن پیام همگانی را بفرستید:\n(برای لغو /cancel بزنید)")


@router.message(Command("cancel"))
async def cancel_cmd(message: Message, state: FSMContext) -> None:
    await state.clear()
    await message.answer("لغو شد.")


@router.message(AdminSt.broadcast)
async def broadcast_send(message: Message, state: FSMContext) -> None:
    await state.clear()
    user_ids = await db.get_all_user_ids()
    sent = 0
    failed = 0
    status = await message.answer(f"⏳ در حال ارسال به {len(user_ids)} کاربر...")
    for uid in user_ids:
        try:
            await message.bot.send_message(uid, message.text)
            sent += 1
        except Exception:
            failed += 1
        await asyncio.sleep(0.05)
    await status.edit_text(f"✅ ارسال تمام شد\n📤 موفق: {sent}\n❌ ناموفق: {failed}")

@router.message(Command("addcode"))
async def add_code(message: Message) -> None:
    parts = (message.text or "").split()
    if len(parts) != 4:
        await message.answer("استفاده:\n/addcode CODE PERCENT MAX_USES\nمثال: /addcode SALE20 20 100")
        return
    _, code, percent, max_uses = parts
    if not percent.isdigit() or not max_uses.isdigit():
        await message.answer("❌ درصد و تعداد باید عدد باشند.")
        return
    await db.create_discount_code(code, int(percent), int(max_uses))
    await message.answer(f"✅ کد <code>{code.upper()}</code> با {percent}% تخفیف ساخته شد.", parse_mode="HTML")


@router.message(Command("delcode"))
async def del_code(message: Message) -> None:
    parts = (message.text or "").split()
    if len(parts) != 2:
        await message.answer("استفاده: /delcode CODE")
        return
    await db.delete_discount_code(parts[1])
    await message.answer(f"✅ کد <code>{parts[1].upper()}</code> حذف شد.", parse_mode="HTML")


@router.message(Command("codes"))
async def list_codes(message: Message) -> None:
    codes = await db.list_discount_codes()
    if not codes:
        await message.answer("هیچ کد تخفیفی وجود ندارد.")
        return
    text = "📋 <b>کدهای تخفیف:</b>\n\n"
    for c in codes:
        text += f"🏷 <code>{c['code']}</code> — {c['percent']}% — {c['used_count']}/{c['max_uses']}\n"
    await message.answer(text, parse_mode="HTML")

@router.message(Command("referral"))
async def toggle_referral(message: Message) -> None:
    current = await db.get_setting("referral_enabled", "1")
    new_val = "0" if current == "1" else "1"
    await db.set_setting("referral_enabled", new_val)
    status = "✅ فعال" if new_val == "1" else "❌ غیرفعال"
    await message.answer(f"🔗 سیستم دعوت: <b>{status}</b>", parse_mode="HTML")

@router.message(Command("trial"))
async def toggle_trial(message: Message) -> None:
    current = await db.get_setting("trial_enabled", "1")
    new_val = "0" if current == "1" else "1"
    await db.set_setting("trial_enabled", new_val)
    status = "✅ فعال" if new_val == "1" else "❌ غیرفعال"
    await message.answer(f"🎁 تست رایگان: <b>{status}</b>", parse_mode="HTML")

@router.message(Command("setprice"))
async def set_price(message: Message) -> None:
    """
    Usage:
    /setprice low 8000
    /setprice mid 7500
    /setprice high 7000
    /setprice tier1 20
    /setprice tier2 60
    """
    parts = (message.text or "").split()
    if len(parts) != 3:
        from utils.pricing import get_prices
        p = await get_prices()
        await message.answer(
            f"📊 <b>قیمت‌های فعلی:</b>\n\n"
            f"کمتر از {p['tier1_max']} گیگ: {p['low']:,} تومان/گیگ\n"
            f"بین {p['tier1_max']} تا {p['tier2_max']} گیگ: {p['mid']:,} تومان/گیگ\n"
            f"بیشتر از {p['tier2_max']} گیگ: {p['high']:,} تومان/گیگ\n\n"
            f"برای تغییر:\n"
            f"/setprice low 8000\n"
            f"/setprice mid 7500\n"
            f"/setprice high 7000\n"
            f"/setprice tier1 20  ← حد اول (گیگ)\n"
            f"/setprice tier2 60  ← حد دوم (گیگ)",
            parse_mode="HTML",
        )
        return

    _, key, val = parts
    if not val.isdigit():
        await message.answer("❌ مقدار باید عدد باشد.")
        return

    key_map = {
        "low": "price_low",
        "mid": "price_mid",
        "high": "price_high",
        "tier1": "price_tier1_max",
        "tier2": "price_tier2_max",
    }
    if key not in key_map:
        await message.answer("❌ کلید نامعتبر. از: low, mid, high, tier1, tier2 استفاده کنید.")
        return

    await db.set_setting(key_map[key], val)
    label = {
        "low": "قیمت رنج اول",
        "mid": "قیمت رنج دوم",
        "high": "قیمت رنج سوم",
        "tier1": "حد رنج اول (گیگ)",
        "tier2": "حد رنج دوم (گیگ)",
    }[key]
    await message.answer(f"✅ <b>{label}</b> به <b>{int(val):,}</b> تغییر کرد.", parse_mode="HTML")

@router.message(Command("stats"))
async def admin_stats(message: Message) -> None:
    user_ids = await db.get_all_user_ids()
    async with aiosqlite.connect(cfg.db_path) as dbconn:
        async with dbconn.execute("SELECT COUNT(*) FROM orders") as cur:
            total_orders = (await cur.fetchone())[0]
        async with dbconn.execute("SELECT COUNT(*) FROM orders WHERE order_type='new'") as cur:
            new_orders = (await cur.fetchone())[0]
        async with dbconn.execute("SELECT COUNT(*) FROM orders WHERE order_type='renew'") as cur:
            renew_orders = (await cur.fetchone())[0]
        async with dbconn.execute("SELECT COALESCE(SUM(amount_paid),0) FROM orders") as cur:
            total_revenue = (await cur.fetchone())[0]
        async with dbconn.execute(
            "SELECT COALESCE(SUM(amount_paid),0) FROM orders WHERE created_at >= date('now')"
        ) as cur:
            today_revenue = (await cur.fetchone())[0]
        async with dbconn.execute(
            "SELECT COUNT(*) FROM orders WHERE created_at >= date('now')"
        ) as cur:
            today_orders = (await cur.fetchone())[0]
        async with dbconn.execute("SELECT COUNT(*) FROM free_trials") as cur:
            trials = (await cur.fetchone())[0]
        async with dbconn.execute(
            "SELECT COUNT(*) FROM pending_payments WHERE status='pending'"
        ) as cur:
            pending = (await cur.fetchone())[0]
        async with dbconn.execute("SELECT COALESCE(SUM(balance),0) FROM wallets") as cur:
            total_wallet = (await cur.fetchone())[0]
        async with dbconn.execute("SELECT COUNT(*) FROM referrals") as cur:
            referrals = (await cur.fetchone())[0]
        async with dbconn.execute(
            "SELECT COUNT(*) FROM wallets"
        ) as cur:
            total_wallets = (await cur.fetchone())[0]
        new_users_today = 0

    referral_status = "✅" if await db.get_setting("referral_enabled", "1") == "1" else "❌"
    trial_status = "✅" if await db.get_setting("trial_enabled", "1") == "1" else "❌"

    from utils.pricing import get_prices
    p = await get_prices()

    await message.answer(
        f"📊 <b>آمار کامل ربات</b>\n\n"
        f"👥 <b>کاربران:</b>\n"
        f"   کل: {len(user_ids)} نفر\n"
        f"   امروز: {new_users_today} نفر جدید\n\n"
        f"🛒 <b>سفارشات:</b>\n"
        f"   کل: {total_orders} سفارش\n"
        f"   خرید جدید: {new_orders}\n"
        f"   تمدید: {renew_orders}\n"
        f"   امروز: {today_orders} سفارش\n\n"
        f"💰 <b>مالی:</b>\n"
        f"   درآمد کل: {total_revenue:,} تومان\n"
        f"   درآمد امروز: {today_revenue:,} تومان\n"
        f"   موجودی کل کیف پول‌ها: {total_wallet:,} تومان\n\n"
        f"📋 <b>سایر:</b>\n"
        f"   تست رایگان: {trials}\n"
        f"   پرداخت معلق: {pending}\n"
        f"   دعوت‌ها: {referrals}\n\n"
        f"⚙️ <b>وضعیت سیستم‌ها:</b>\n"
        f"   {referral_status} سیستم دعوت\n"
        f"   {trial_status} تست رایگان\n\n"
        f"💎 <b>قیمت‌های فعلی:</b>\n"
        f"   زیر {p['tier1_max']}گیگ: {p['low']:,} تومان/گیگ\n"
        f"   {p['tier1_max']}-{p['tier2_max']}گیگ: {p['mid']:,} تومان/گیگ\n"
        f"   بالای {p['tier2_max']}گیگ: {p['high']:,} تومان/گیگ",
        parse_mode="HTML",
    )
