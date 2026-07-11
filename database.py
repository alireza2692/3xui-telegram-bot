from __future__ import annotations
import aiosqlite
import logging
from typing import Optional
from config import cfg

logger = logging.getLogger(__name__)
DB = cfg.db_path


async def init_db() -> None:
    async with aiosqlite.connect(DB) as db:
        await db.executescript("""
        PRAGMA journal_mode=WAL;
        PRAGMA cache_size=-8000;
        PRAGMA synchronous=NORMAL;
        PRAGMA temp_store=MEMORY;

        CREATE TABLE IF NOT EXISTS users (
            telegram_id INTEGER PRIMARY KEY,
            username    TEXT,
            full_name   TEXT,
            joined_at   TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );

        CREATE TABLE IF NOT EXISTS wallets (
            telegram_id INTEGER PRIMARY KEY,
            balance     INTEGER NOT NULL DEFAULT 0
        );

        CREATE TABLE IF NOT EXISTS transactions (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            telegram_id INTEGER NOT NULL,
            amount      INTEGER NOT NULL,
            description TEXT,
            created_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );

        CREATE TABLE IF NOT EXISTS pending_payments (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            telegram_id     INTEGER NOT NULL,
            amount          INTEGER NOT NULL,
            receipt_file_id TEXT,
            purpose         TEXT,
            meta            TEXT,
            status          TEXT NOT NULL DEFAULT 'pending',
            created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            reviewed_at     TIMESTAMP
        );

        CREATE TABLE IF NOT EXISTS free_trials (
            telegram_id  INTEGER PRIMARY KEY,
            client_email TEXT NOT NULL,
            created_at   TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );

        CREATE TABLE IF NOT EXISTS reminder_sent (
            telegram_id  INTEGER NOT NULL,
            client_email TEXT NOT NULL,
            reason       TEXT NOT NULL,  -- 'traffic' or 'expiry'
            sent_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (telegram_id, client_email, reason)
        );

        CREATE TABLE IF NOT EXISTS bot_settings (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS referrals (
            inviter_id  INTEGER NOT NULL,
            invitee_id  INTEGER NOT NULL PRIMARY KEY,
            created_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );

        CREATE TABLE IF NOT EXISTS discount_codes (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            code        TEXT NOT NULL UNIQUE,
            percent     INTEGER NOT NULL,
            max_uses    INTEGER NOT NULL DEFAULT 1,
            used_count  INTEGER NOT NULL DEFAULT 0,
            created_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );

        CREATE TABLE IF NOT EXISTS discount_uses (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            code        TEXT NOT NULL,
            telegram_id INTEGER NOT NULL,
            used_at     TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            UNIQUE(code, telegram_id)
        );

        CREATE TABLE IF NOT EXISTS broadcast_log (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            message     TEXT,
            sent_count  INTEGER DEFAULT 0,
            created_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );

        CREATE TABLE IF NOT EXISTS reminder_sent (
            telegram_id  INTEGER NOT NULL,
            client_email TEXT NOT NULL,
            reason       TEXT NOT NULL,  -- 'traffic' or 'expiry'
            sent_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (telegram_id, client_email, reason)
        );

        CREATE TABLE IF NOT EXISTS bot_settings (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS referrals (
            inviter_id  INTEGER NOT NULL,
            invitee_id  INTEGER NOT NULL PRIMARY KEY,
            created_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );

        CREATE TABLE IF NOT EXISTS discount_codes (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            code        TEXT NOT NULL UNIQUE,
            percent     INTEGER NOT NULL,
            max_uses    INTEGER NOT NULL DEFAULT 1,
            used_count  INTEGER NOT NULL DEFAULT 0,
            created_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );

        CREATE TABLE IF NOT EXISTS discount_uses (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            code        TEXT NOT NULL,
            telegram_id INTEGER NOT NULL,
            used_at     TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            UNIQUE(code, telegram_id)
        );

        CREATE TABLE IF NOT EXISTS orders (
            id           INTEGER PRIMARY KEY AUTOINCREMENT,
            telegram_id  INTEGER NOT NULL,
            client_email TEXT NOT NULL,
            gb           INTEGER NOT NULL,
            amount_paid  INTEGER NOT NULL,
            order_type   TEXT NOT NULL DEFAULT 'new',
            created_at   TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );
        """)
        await db.commit()
    logger.info("DB ready: %s", DB)


async def upsert_user(telegram_id: int, username: Optional[str], full_name: str) -> None:
    async with aiosqlite.connect(DB) as db:
        await db.execute(
            "INSERT INTO users(telegram_id,username,full_name) VALUES(?,?,?) "
            "ON CONFLICT(telegram_id) DO UPDATE SET username=excluded.username, full_name=excluded.full_name",
            (telegram_id, username, full_name),
        )
        await db.execute("INSERT OR IGNORE INTO wallets(telegram_id,balance) VALUES(?,0)", (telegram_id,))
        await db.commit()


async def get_balance(telegram_id: int) -> int:
    async with aiosqlite.connect(DB) as db:
        async with db.execute("SELECT balance FROM wallets WHERE telegram_id=?", (telegram_id,)) as cur:
            row = await cur.fetchone()
            return row[0] if row else 0


async def add_balance(telegram_id: int, amount: int, description: str = "") -> int:
    async with aiosqlite.connect(DB) as db:
        await db.execute("INSERT OR IGNORE INTO wallets(telegram_id, balance) VALUES(?,0)", (telegram_id,))
        await db.execute("UPDATE wallets SET balance=balance+? WHERE telegram_id=?", (amount, telegram_id))
        await db.execute(
            "INSERT INTO transactions(telegram_id,amount,description) VALUES(?,?,?)",
            (telegram_id, amount, description),
        )
        await db.commit()
        async with db.execute("SELECT balance FROM wallets WHERE telegram_id=?", (telegram_id,)) as cur:
            row = await cur.fetchone()
            return row[0] if row else 0


async def create_pending_payment(
    telegram_id: int, amount: int, receipt_file_id: str, purpose: str, meta: str = ""
) -> int:
    async with aiosqlite.connect(DB) as db:
        cur = await db.execute(
            "INSERT INTO pending_payments(telegram_id,amount,receipt_file_id,purpose,meta) VALUES(?,?,?,?,?)",
            (telegram_id, amount, receipt_file_id, purpose, meta),
        )
        await db.commit()
        return cur.lastrowid


async def get_pending_payment(payment_id: int):
    async with aiosqlite.connect(DB) as db:
        db.row_factory = aiosqlite.Row
        async with db.execute("SELECT * FROM pending_payments WHERE id=?", (payment_id,)) as cur:
            return await cur.fetchone()


async def update_payment_status(payment_id: int, status: str) -> None:
    async with aiosqlite.connect(DB) as db:
        await db.execute(
            "UPDATE pending_payments SET status=?,reviewed_at=CURRENT_TIMESTAMP WHERE id=?",
            (status, payment_id),
        )
        await db.commit()


async def has_free_trial(telegram_id: int) -> bool:
    async with aiosqlite.connect(DB) as db:
        async with db.execute("SELECT 1 FROM free_trials WHERE telegram_id=?", (telegram_id,)) as cur:
            return await cur.fetchone() is not None


async def record_free_trial(telegram_id: int, client_email: str) -> None:
    async with aiosqlite.connect(DB) as db:
        await db.execute(
            "INSERT OR IGNORE INTO free_trials(telegram_id,client_email) VALUES(?,?)",
            (telegram_id, client_email),
        )
        await db.commit()


async def create_order(
    telegram_id: int, client_email: str, gb: int, amount_paid: int, order_type: str = "new"
) -> int:
    async with aiosqlite.connect(DB) as db:
        cur = await db.execute(
            "INSERT INTO orders(telegram_id,client_email,gb,amount_paid,order_type) VALUES(?,?,?,?,?)",
            (telegram_id, client_email, gb, amount_paid, order_type),
        )
        await db.commit()
        return cur.lastrowid


async def get_user_orders(telegram_id: int):
    async with aiosqlite.connect(DB) as db:
        db.row_factory = aiosqlite.Row
        async with db.execute(
            "SELECT DISTINCT client_email FROM orders WHERE telegram_id=?", (telegram_id,)
        ) as cur:
            return await cur.fetchall()

async def create_discount_code(code: str, percent: int, max_uses: int) -> None:
    async with aiosqlite.connect(DB) as db:
        await db.execute(
            "INSERT INTO discount_codes(code,percent,max_uses) VALUES(?,?,?)",
            (code.upper(), percent, max_uses),
        )
        await db.commit()


async def get_discount_code(code: str):
    async with aiosqlite.connect(DB) as db:
        db.row_factory = aiosqlite.Row
        async with db.execute(
            "SELECT * FROM discount_codes WHERE code=? AND used_count < max_uses",
            (code.upper(),)
        ) as cur:
            return await cur.fetchone()


async def use_discount_code(code: str, telegram_id: int) -> bool:
    """Returns False if already used by this user."""
    async with aiosqlite.connect(DB) as db:
        try:
            await db.execute(
                "INSERT INTO discount_uses(code,telegram_id) VALUES(?,?)",
                (code.upper(), telegram_id)
            )
            await db.execute(
                "UPDATE discount_codes SET used_count=used_count+1 WHERE code=?",
                (code.upper(),)
            )
            await db.commit()
            return True
        except Exception:
            return False


async def delete_discount_code(code: str) -> None:
    async with aiosqlite.connect(DB) as db:
        await db.execute("DELETE FROM discount_codes WHERE code=?", (code.upper(),))
        await db.commit()


async def list_discount_codes():
    async with aiosqlite.connect(DB) as db:
        db.row_factory = aiosqlite.Row
        async with db.execute("SELECT * FROM discount_codes ORDER BY id DESC") as cur:
            return await cur.fetchall()

async def get_all_user_ids():
    async with aiosqlite.connect(DB) as db:
        async with db.execute(
            "SELECT telegram_id FROM wallets"
        ) as cur:
            rows = await cur.fetchall()
            return [r[0] for r in rows]

async def get_expiring_orders():
    """Get distinct (telegram_id, client_email) from orders for reminder checks."""
    async with aiosqlite.connect(DB) as db:
        db.row_factory = aiosqlite.Row
        async with db.execute(
            "SELECT DISTINCT telegram_id, client_email FROM orders"
        ) as cur:
            return await cur.fetchall()


async def create_discount_code(code: str, percent: int, max_uses: int) -> None:
    async with aiosqlite.connect(DB) as db:
        await db.execute(
            "INSERT INTO discount_codes(code,percent,max_uses) VALUES(?,?,?)",
            (code.upper(), percent, max_uses),
        )
        await db.commit()


async def get_discount_code(code: str):
    async with aiosqlite.connect(DB) as db:
        db.row_factory = aiosqlite.Row
        async with db.execute(
            "SELECT * FROM discount_codes WHERE code=? AND used_count < max_uses",
            (code.upper(),)
        ) as cur:
            return await cur.fetchone()


async def use_discount_code(code: str, telegram_id: int) -> bool:
    async with aiosqlite.connect(DB) as db:
        try:
            await db.execute(
                "INSERT INTO discount_uses(code,telegram_id) VALUES(?,?)",
                (code.upper(), telegram_id)
            )
            await db.execute(
                "UPDATE discount_codes SET used_count=used_count+1 WHERE code=?",
                (code.upper(),)
            )
            await db.commit()
            return True
        except Exception:
            return False


async def delete_discount_code(code: str) -> None:
    async with aiosqlite.connect(DB) as db:
        await db.execute("DELETE FROM discount_codes WHERE code=?", (code.upper(),))
        await db.commit()


async def list_discount_codes():
    async with aiosqlite.connect(DB) as db:
        db.row_factory = aiosqlite.Row
        async with db.execute("SELECT * FROM discount_codes ORDER BY id DESC") as cur:
            return await cur.fetchall()


async def get_all_user_ids():
    async with aiosqlite.connect(DB) as db:
        async with db.execute(
            "SELECT telegram_id FROM wallets"
        ) as cur:
            rows = await cur.fetchall()
            return [r[0] for r in rows]


async def get_expiring_orders():
    """Get latest order per client_email to avoid duplicate checks."""
    async with aiosqlite.connect(DB) as db:
        db.row_factory = aiosqlite.Row
        async with db.execute(
            """
            SELECT telegram_id, client_email
            FROM orders
            GROUP BY client_email
            HAVING MAX(id)
            """
        ) as cur:
            return await cur.fetchall()


async def add_referral(inviter_id: int, invitee_id: int) -> bool:
    """Returns False if invitee already referred by someone."""
    async with aiosqlite.connect(DB) as db:
        try:
            await db.execute(
                "INSERT OR IGNORE INTO referrals(inviter_id, invitee_id) VALUES(?,?)",
                (inviter_id, invitee_id),
            )
            await db.commit()
            return True
        except Exception:
            return False


async def get_inviter(invitee_id: int) -> Optional[int]:
    async with aiosqlite.connect(DB) as db:
        async with db.execute(
            "SELECT inviter_id FROM referrals WHERE invitee_id=?", (invitee_id,)
        ) as cur:
            row = await cur.fetchone()
            return row[0] if row else None


async def get_referral_count(inviter_id: int) -> int:
    async with aiosqlite.connect(DB) as db:
        async with db.execute(
            "SELECT COUNT(*) FROM referrals WHERE inviter_id=?", (inviter_id,)
        ) as cur:
            row = await cur.fetchone()
            return row[0] if row else 0


async def get_user(telegram_id: int):
    async with aiosqlite.connect(DB) as db:
        async with db.execute(
            "SELECT telegram_id FROM users WHERE telegram_id=?", (telegram_id,)
        ) as cur:
            return await cur.fetchone()


async def get_setting(key: str, default: str = "") -> str:
    async with aiosqlite.connect(DB) as db:
        async with db.execute("SELECT value FROM bot_settings WHERE key=?", (key,)) as cur:
            row = await cur.fetchone()
            return row[0] if row else default


async def set_setting(key: str, value: str) -> None:
    async with aiosqlite.connect(DB) as db:
        await db.execute(
            "INSERT INTO bot_settings(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            (key, value),
        )
        await db.commit()


async def has_reminder_sent(telegram_id: int, client_email: str, reason: str) -> bool:
    async with aiosqlite.connect(DB) as db:
        async with db.execute(
            "SELECT 1 FROM reminder_sent WHERE telegram_id=? AND client_email=? AND reason=?",
            (telegram_id, client_email, reason)
        ) as cur:
            return await cur.fetchone() is not None


async def mark_reminder_sent(telegram_id: int, client_email: str, reason: str) -> None:
    async with aiosqlite.connect(DB) as db:
        await db.execute(
            "INSERT OR IGNORE INTO reminder_sent(telegram_id,client_email,reason) VALUES(?,?,?)",
            (telegram_id, client_email, reason)
        )
        await db.commit()


async def clear_reminder(telegram_id: int, client_email: str) -> None:
    """Clear reminders when service is renewed so next expiry triggers again."""
    async with aiosqlite.connect(DB) as db:
        await db.execute(
            "DELETE FROM reminder_sent WHERE telegram_id=? AND client_email=?",
            (telegram_id, client_email)
        )
        await db.commit()
