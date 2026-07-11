from __future__ import annotations
import os
from dataclasses import dataclass, field
from typing import List, Tuple
from dotenv import load_dotenv

load_dotenv()


def _int_list(raw: str) -> List[int]:
    return [int(x.strip()) for x in raw.split(",") if x.strip().lstrip("-").isdigit()]


def _parse_inbounds(raw: str, fallback_id: str = ""):
    """
    INBOUNDS env format: "ID:REMARK:FLOW,ID:REMARK:FLOW,..."
    FLOW may be empty (non-Reality inbounds).
    Falls back to a single inbound built from INBOUND_ID if INBOUNDS is unset.
    """
    inbounds = []
    if raw:
        for entry in raw.split(","):
            entry = entry.strip()
            if not entry:
                continue
            parts = entry.split(":")
            ib_id = parts[0].strip()
            remark = parts[1].strip() if len(parts) > 1 else f"inbound-{ib_id}"
            flow = parts[2].strip() if len(parts) > 2 else ""
            if ib_id:
                inbounds.append((ib_id, remark, flow))
    if not inbounds and fallback_id:
        inbounds = [(fallback_id, "default", "xtls-rprx-vision")]
    return inbounds


def _parse_cards(raw: str) -> List[Tuple[str, str]]:
    """
    CARDS env format: "NUMBER:NAME,NUMBER:NAME,..."
    Example: "5054-1610-2117-7021:بردیا شاهی,5022-2915-8333-1655:تینا شیدارژنگ"
    """
    cards = []
    if not raw:
        return cards
    for entry in raw.split(","):
        entry = entry.strip()
        if not entry:
            continue
        if ":" in entry:
            number, name = entry.split(":", 1)
        else:
            number, name = entry, ""
        cards.append((number.strip(), name.strip()))
    return cards


@dataclass
class Config:
    bot_token: str = field(default_factory=lambda: os.environ["BOT_TOKEN"])
    admin_ids: List[int] = field(default_factory=lambda: _int_list(os.getenv("ADMIN_IDS", "")))

    required_channel_id: int = field(default_factory=lambda: int(os.getenv("REQUIRED_CHANNEL_ID", "0")))
    required_channel_invite: str = field(default_factory=lambda: os.getenv("REQUIRED_CHANNEL_INVITE", ""))

    panel_url: str = field(default_factory=lambda: os.environ["PANEL_URL"].rstrip("/"))
    panel_path: str = field(default_factory=lambda: os.getenv("PANEL_PATH", "").rstrip("/"))
    panel_api_token: str = field(default_factory=lambda: os.environ["PANEL_API_TOKEN"])
    inbound_id: int = field(default_factory=lambda: int(os.getenv("INBOUND_ID", "1")))
    inbounds: list = field(default_factory=lambda: _parse_inbounds(os.getenv("INBOUNDS", ""), os.getenv("INBOUND_ID", "")))

    sub_base_url: str = field(default_factory=lambda: os.getenv("SUB_BASE_URL", "").rstrip("/"))

    proxy_host: str = field(default_factory=lambda: os.getenv("PROXY_HOST", "").strip())
    proxy_port: str = field(default_factory=lambda: os.getenv("PROXY_PORT", "").strip())

    @property
    def proxy_enabled(self) -> bool:
        return bool(self.proxy_host and self.proxy_port)

    cards: List[Tuple[str, str]] = field(default_factory=lambda: _parse_cards(os.getenv("CARDS", "")))
    card_number: str = field(default_factory=lambda: os.getenv("CARD_NUMBER", ""))

    log_channel_id: int = field(default_factory=lambda: int(os.getenv("LOG_CHANNEL_ID", "0")))
    db_path: str = field(default_factory=lambda: os.getenv("DB_PATH", "vpn_bot.db"))

    price_low: int = 8000
    price_mid: int = 7500
    price_high: int = 7000
    price_tier1_max: int = 20
    price_tier2_max: int = 60

    trial_gb: float = 0.5
    trial_days: int = 1

    def cards_text(self) -> str:
        if self.cards:
            lines = []
            for number, name in self.cards:
                if name:
                    lines.append(f"<code>{number}</code>\n به نام: {name}")
                else:
                    lines.append(f"<code>{number}</code>")
            return "\n\n".join(lines)
        return f"<code>{self.card_number or 'XXXX-XXXX-XXXX-XXXX'}</code>"


cfg = Config()
