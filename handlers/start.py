from aiogram import Router, F
from aiogram.filters import CommandStart
from aiogram.fsm.context import FSMContext
from aiogram.types import CallbackQuery, Message
import database as db
from keyboards import main_menu, channel_kb, tutorial_os_kb
from utils.log_channel import log_referral_bonus
from middlewares.membership import MembershipMiddleware
from config import cfg

router = Router()


@router.message(CommandStart())
async def cmd_start(message: Message, state: FSMContext) -> None:
    data = await state.get_data()
    discount_code = data.get("discount_code")
    if discount_code:
        import aiosqlite as _sq
        from config import cfg as _cfg
        async with _sq.connect(_cfg.db_path) as _db:
            await _db.execute(
                "DELETE FROM discount_uses WHERE code=? AND telegram_id=?",
                (discount_code.upper(), message.from_user.id)
            )
            await _db.execute(
                "UPDATE discount_codes SET used_count=MAX(0,used_count-1) WHERE code=?",
                (discount_code.upper(),)
            )
            await _db.commit()
    await state.clear()
    u = message.from_user
    is_new = await db.get_user(u.id) is None
    await db.upsert_user(u.id, u.username, u.full_name)
    args = message.text.split() if message.text else []
    if len(args) > 1 and is_new:
        try:
            inviter_id = int(args[1].replace("ref", ""))
            if inviter_id != u.id:
                await db.add_referral(inviter_id, u.id)
        except Exception:
            pass

    await message.answer(
        f"سلام <b>{u.first_name}</b> عزیز! 👋\n\nبه ربات فروش VPN خوش آمدید.\nاز منوی زیر انتخاب کنید:",
        reply_markup=main_menu(),
        parse_mode="HTML",
    )



@router.callback_query(F.data == "check_member")
async def check_member(cb: CallbackQuery) -> None:
    try:
        member = await cb.bot.get_chat_member(cfg.required_channel_id, cb.from_user.id)
        ok = member.status not in ("left", "kicked", "banned")
    except Exception:
        ok = False

    if ok:
        u = cb.from_user
        await db.upsert_user(u.id, u.username, u.full_name)
        await cb.message.delete()
        await cb.message.answer(
            "✅ عضویت تایید شد! خوش آمدید 🎉",
            reply_markup=main_menu(),
        )
    else:
        await cb.answer("⛔️ هنوز عضو نشده‌اید!", show_alert=True)


@router.callback_query(F.data == "back_main")
async def back_main(cb: CallbackQuery, state: FSMContext) -> None:
    data = await state.get_data()
    discount_code = data.get("discount_code")
    if discount_code:
        import aiosqlite as _sq
        from config import cfg as _cfg
        async with _sq.connect(_cfg.db_path) as _db:
            await _db.execute(
                "DELETE FROM discount_uses WHERE code=? AND telegram_id=?",
                (discount_code.upper(), cb.from_user.id)
            )
            await _db.execute(
                "UPDATE discount_codes SET used_count=MAX(0,used_count-1) WHERE code=?",
                (discount_code.upper(),)
            )
            await _db.commit()
    await state.clear()
    await cb.message.answer("منوی اصلی:", reply_markup=main_menu())
    await cb.answer()


@router.message(F.text == "💎 تعرفه ها")
async def tariff(message: Message) -> None:
    from utils.pricing import get_prices
    p = await get_prices()
    t1 = p["tier1_max"]
    t2 = p["tier2_max"]
    low = p["low"]
    mid = p["mid"]
    high = p["high"]
    await message.answer(
        f"💎 <b>تعرفه های VPN</b>\n\n"
        f"📦 کمتر از {t1} گیگابایت:\n"
        f"   └ هر گیگ: <b>{low:,} تومان</b>\n\n"
        f"📦 بین {t1} تا {t2} گیگابایت:\n"
        f"   └ هر گیگ: <b>{mid:,} تومان</b>\n\n"
        f"📦 بیشتر از {t2} گیگابایت:\n"
        f"   └ هر گیگ: <b>{high:,} تومان</b>\n\n"
        f"📅 مدت همه سرویس ها: <b>۳۰ روز</b>\n\n"
        f"💡 مثال:\n"
        f"   └ ۱۰ گیگ = {10 * low:,} تومان\n"
        f"   └ {t1+10} گیگ = {(t1+10) * mid:,} تومان\n"
        f"   └ {t2+40} گیگ = {(t2+40) * high:,} تومان",
        parse_mode="HTML",
        reply_markup=main_menu(),
    )


@router.message(F.text == "🆘 پشتیبانی")
async def support(message: Message) -> None:
    await message.answer(
        "🆘 <b>پشتیبانی</b>\n\n"
        "برای ارتباط با پشتیبانی از طریق لینک زیر اقدام کنید:\n\n"
        f"👤 {cfg.support}\n\n"
        "⏰ ساعات پاسخگویی: ۹ صبح تا ۱۲ شب",
        parse_mode="HTML",
        reply_markup=main_menu(),
    )


@router.message(F.text == "🔗 لینک دعوت")
async def referral_link(message: Message) -> None:
    if await db.get_setting("referral_enabled", "1") != "1":
        await message.answer("❌ سیستم دعوت در حال حاضر غیرفعال است.", reply_markup=main_menu())
        return
    tg_id = message.from_user.id
    bot_info = await message.bot.get_me()
    link = f"https://t.me/{bot_info.username}?start=ref{tg_id}"
    count = await db.get_referral_count(tg_id)
    await message.answer(
        f"🔗 <b>لینک دعوت شما</b>\n\n"
        f"<code>{link}</code>\n\n"
        f"👥 تعداد دعوت شدگان: {count} نفر\n\n"
        f"💡 به ازای هر نفری که با لینک شما وارد بشه و "
        f"اولین شارژ کیف پولش را انجام بده، "
        f"<b>۵٪</b> از مبلغ شارژ به کیف پول شما اضافه میشه!",
        parse_mode="HTML",
        reply_markup=main_menu(),
    )


TUTORIALS = {
    "android": {
        "title": "🤖 آموزش اتصال - اندروید",
        "apps": [
            ("V2rayNG", "https://play.google.com/store/apps/details?id=com.v2ray.ang"),
            ("Hiddify", "https://play.google.com/store/apps/details?id=app.hiddify.com"),
        ],
        "steps": (
            "1️⃣ اپلیکیشن <b>V2rayNG</b> یا <b>Hiddify</b> را نصب کنید\n\n"
            "2️⃣ لینک اشتراک خود را از بخش «📋 سرویس های من» کپی کنید\n\n"
            "3️⃣ در V2rayNG:\n"
            "   • روی آیکون <b>+</b> بزنید\n"
            "   • گزینه <b>Import config from clipboard</b> را انتخاب کنید\n\n"
            "   در Hiddify:\n"
            "   • روی <b>+</b> بزنید\n"
            "   • لینک را paste کنید\n\n"
            "4️⃣ روی دکمه اتصال بزنید ✅"
        ),
    },
    "ios": {
        "title": "🍎 آموزش اتصال - iOS",
        "apps": [
            ("Streisand", "https://apps.apple.com/us/app/streisand/id6450534064"),
            ("Hiddify", "https://apps.apple.com/us/app/hiddify-proxy-vpn/id6596777532"),
            ("V2Box", "https://apps.apple.com/us/app/v2box-v2ray-client/id6446814690"),
        ],
        "steps": (
            "1️⃣ اپلیکیشن <b>Streisand</b> یا <b>Hiddify</b> را از App Store نصب کنید\n\n"
            "2️⃣ لینک اشتراک خود را از بخش «📋 سرویس های من» کپی کنید\n\n"
            "3️⃣ در Streisand:\n"
            "   • روی <b>+</b> بزنید\n"
            "   • گزینه <b>Import from clipboard</b> را انتخاب کنید\n\n"
            "   در Hiddify:\n"
            "   • روی <b>+</b> بزنید\n"
            "   • لینک را paste کنید\n\n"
            "4️⃣ روی دکمه اتصال بزنید ✅"
        ),
    },
    "windows": {
        "title": "🪟 آموزش اتصال - ویندوز",
        "apps": [
            ("Hiddify", "https://github.com/hiddify/hiddify-app/releases/latest"),
            ("V2rayN", "https://github.com/2dust/v2rayN/releases/latest"),
            ("Nekoray", "https://github.com/MatsuriDayo/nekoray/releases/latest"),
        ],
        "steps": (
            "1️⃣ اپلیکیشن <b>Hiddify</b> یا <b>V2rayN</b> را دانلود و نصب کنید\n\n"
            "2️⃣ لینک اشتراک خود را از بخش «📋 سرویس های من» کپی کنید\n\n"
            "3️⃣ در Hiddify:\n"
            "   • روی <b>+</b> بزنید\n"
            "   • لینک را paste کنید\n\n"
            "   در V2rayN:\n"
            "   • از منو <b>Servers</b> گزینه <b>Add subscription</b> را بزنید\n"
            "   • لینک را وارد کنید و Update بزنید\n\n"
            "4️⃣ یک سرور انتخاب کرده و Connect بزنید ✅"
        ),
    },
    "mac": {
        "title": "🍏 آموزش اتصال - مک",
        "apps": [
            ("Hiddify", "https://github.com/hiddify/hiddify-app/releases/latest"),
            ("V2rayU", "https://github.com/yanue/V2rayU/releases/latest"),
        ],
        "steps": (
            "1️⃣ اپلیکیشن <b>Hiddify</b> یا <b>V2rayU</b> را دانلود و نصب کنید\n\n"
            "2️⃣ لینک اشتراک خود را از بخش «📋 سرویس های من» کپی کنید\n\n"
            "3️⃣ در Hiddify:\n"
            "   • روی <b>+</b> بزنید\n"
            "   • لینک را paste کنید\n\n"
            "   در V2rayU:\n"
            "   • از منو <b>Subscribe</b> گزینه <b>Subscribe setting</b> را بزنید\n"
            "   • لینک را وارد و Update بزنید\n\n"
            "4️⃣ اتصال را فعال کنید ✅"
        ),
    },
}


@router.message(F.text == "📚 آموزش اتصال")
async def tutorial_start(message: Message) -> None:
    await message.answer(
        "📚 <b>آموزش اتصال به VPN</b>\n\nسیستم عامل خود را انتخاب کنید:",
        reply_markup=tutorial_os_kb(),
        parse_mode="HTML",
    )


@router.callback_query(F.data.startswith("tutorial:"))
async def tutorial_os(cb: CallbackQuery) -> None:
    os_key = cb.data.split(":")[1]
    t = TUTORIALS.get(os_key)
    if not t:
        await cb.answer()
        return

    from aiogram.utils.keyboard import InlineKeyboardBuilder
    from aiogram.types import InlineKeyboardButton
    b = InlineKeyboardBuilder()
    for app_name, app_url in t["apps"]:
        b.row(InlineKeyboardButton(text=f"⬇️ دانلود {app_name}", url=app_url))
    b.row(InlineKeyboardButton(text="🔙 بازگشت", callback_data="tutorial_back"))

    await cb.message.answer(
        f"{t['title']}\n\n"
        f"📱 <b>اپلیکیشن های پیشنهادی:</b>\n"
        + "\n".join(f"• {a[0]}" for a in t["apps"]) +
        f"\n\n<b>مراحل اتصال:</b>\n\n{t['steps']}",
        reply_markup=b.as_markup(),
        parse_mode="HTML",
    )
    await cb.answer()


@router.callback_query(F.data == "tutorial_back")
async def tutorial_back(cb: CallbackQuery) -> None:
    await cb.message.answer(
        "📚 <b>آموزش اتصال به VPN</b>\n\nسیستم عامل خود را انتخاب کنید:",
        reply_markup=tutorial_os_kb(),
        parse_mode="HTML",
    )
    await cb.answer()

