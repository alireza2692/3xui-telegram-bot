from __future__ import annotations
import database as db
from config import cfg


async def get_prices() -> dict:
    
    return {
        "low": int(await db.get_setting("price_low", str(cfg.price_low))),
        "mid": int(await db.get_setting("price_mid", str(cfg.price_mid))),
        "high": int(await db.get_setting("price_high", str(cfg.price_high))),
        "tier1_max": int(await db.get_setting("price_tier1_max", str(cfg.price_tier1_max))),
        "tier2_max": int(await db.get_setting("price_tier2_max", str(cfg.price_tier2_max))),
    }


async def calc_price(gb: int) -> int:
    p = await get_prices()
    if gb < p["tier1_max"]:
        return gb * p["low"]
    elif gb <= p["tier2_max"]:
        return gb * p["mid"]
    else:
        return gb * p["high"]


async def price_breakdown(gb: int) -> str:
    p = await get_prices()
    if gb < p["tier1_max"]:
        per_gb = p["low"]
    elif gb <= p["tier2_max"]:
        per_gb = p["mid"]
    else:
        per_gb = p["high"]
    total = await calc_price(gb)
    return (
        f"📦 حجم: <b>{gb} گیگابایت</b>\n"
        f"💰 قیمت هر گیگ: {per_gb:,} تومان\n"
        f"🧾 مبلغ کل: <b>{total:,} تومان</b>\n"
        f"📅 مدت: ۳۰ روز"
    )
