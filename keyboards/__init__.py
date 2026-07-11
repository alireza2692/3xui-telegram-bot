from aiogram.types import (
    InlineKeyboardMarkup, InlineKeyboardButton,
    ReplyKeyboardMarkup, KeyboardButton,
)
from aiogram.utils.keyboard import InlineKeyboardBuilder


def main_menu() -> ReplyKeyboardMarkup:
    return ReplyKeyboardMarkup(
        keyboard=[
            [KeyboardButton(text="🛒 خرید سرویس"), KeyboardButton(text="🎁 تست رایگان")],
            [KeyboardButton(text="📋 سرویس های من"), KeyboardButton(text="💳 کیف پول")],
            [KeyboardButton(text="💎 تعرفه ها"), KeyboardButton(text="🆘 پشتیبانی")],
            [KeyboardButton(text="🔗 لینک دعوت"), KeyboardButton(text="📚 آموزش اتصال")],
        ],
        resize_keyboard=True,
    )


def channel_kb(invite: str) -> InlineKeyboardMarkup:
    b = InlineKeyboardBuilder()
    b.row(InlineKeyboardButton(text="📢 عضویت در کانال", url=invite))
    b.row(InlineKeyboardButton(text="✅ تایید عضویت", callback_data="check_member"))
    return b.as_markup()


def wallet_kb() -> InlineKeyboardMarkup:
    b = InlineKeyboardBuilder()
    b.row(InlineKeyboardButton(text="➕ افزایش موجودی", callback_data="wallet_topup"))
    b.row(InlineKeyboardButton(text="🔙 بازگشت", callback_data="back_main"))
    return b.as_markup()


def paid_kb() -> InlineKeyboardMarkup:
    b = InlineKeyboardBuilder()
    b.row(InlineKeyboardButton(text="✅ پرداخت کردم", callback_data="paid"))
    b.row(InlineKeyboardButton(text="🔙 بازگشت", callback_data="back_main"))
    return b.as_markup()


def back_kb() -> InlineKeyboardMarkup:
    b = InlineKeyboardBuilder()
    b.row(InlineKeyboardButton(text="🔙 بازگشت", callback_data="back_main"))
    return b.as_markup()


def confirm_buy_kb() -> InlineKeyboardMarkup:
    b = InlineKeyboardBuilder()
    b.row(
        InlineKeyboardButton(text="✅ تایید", callback_data="buy_confirm"),
        InlineKeyboardButton(text="❌ انصراف", callback_data="back_main"),
    )
    return b.as_markup()


def confirm_renew_kb() -> InlineKeyboardMarkup:
    b = InlineKeyboardBuilder()
    b.row(
        InlineKeyboardButton(text="✅ تایید تمدید", callback_data="renew_confirm"),
        InlineKeyboardButton(text="❌ انصراف", callback_data="back_main"),
    )
    return b.as_markup()


def admin_payment_kb(pid: int) -> InlineKeyboardMarkup:
    b = InlineKeyboardBuilder()
    b.row(
        InlineKeyboardButton(text="✅ تایید پرداخت", callback_data=f"ap:{pid}"),
        InlineKeyboardButton(text="❌ عدم تایید", callback_data=f"rp:{pid}"),
    )
    return b.as_markup()


def service_kb(email: str) -> InlineKeyboardMarkup:
    b = InlineKeyboardBuilder()
    b.row(InlineKeyboardButton(text="🔄 تغییر لینک اتصال", callback_data=f"chlink:{email}"))
    b.row(InlineKeyboardButton(text="🔁 تمدید سرویس", callback_data=f"renew:{email}"))
    b.row(InlineKeyboardButton(text="🔙 بازگشت به لیست", callback_data="my_services"))
    return b.as_markup()


def confirm_chlink_kb(email: str) -> InlineKeyboardMarkup:
    b = InlineKeyboardBuilder()
    b.row(
        InlineKeyboardButton(text="✅ تایید تغییر", callback_data=f"chlink_ok:{email}"),
        InlineKeyboardButton(text="❌ انصراف", callback_data=f"view:{email}"),
    )
    return b.as_markup()


def tutorial_os_kb() -> InlineKeyboardMarkup:
    b = InlineKeyboardBuilder()
    b.row(InlineKeyboardButton(text="🤖 اندروید", callback_data="tutorial:android"))
    b.row(InlineKeyboardButton(text="🍎 iOS / iPhone", callback_data="tutorial:ios"))
    b.row(InlineKeyboardButton(text="🪟 ویندوز", callback_data="tutorial:windows"))
    b.row(InlineKeyboardButton(text="🍏 مک", callback_data="tutorial:mac"))
    b.row(InlineKeyboardButton(text="🔙 بازگشت", callback_data="back_main"))
    return b.as_markup()


def inbound_choice_kb(inbounds, prefix="pick_inbound") -> InlineKeyboardMarkup:
    
    b = InlineKeyboardBuilder()
    for ib_id, remark, _flow in inbounds:
        b.row(InlineKeyboardButton(text=f"🌍 {remark}", callback_data=f"{prefix}:{ib_id}"))
    return b.as_markup()
